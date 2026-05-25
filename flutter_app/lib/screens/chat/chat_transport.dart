import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../crypto/room_cipher.dart';

/// Reconnect backoff in seconds, picked by attempt index.
const List<int> _kReconnectDelaysSec = [1, 2, 4, 8, 16, 30];

/// Server close code that means "your token isn't valid anymore" — we treat
/// it as a forced logout instead of looping reconnects.
const int _kUnauthorizedCloseCode = 1008;

/// Idle window after the last "typing" frame before we send "stopped typing".
const Duration _kTypingStopDelay = Duration(seconds: 3);

/// How often we're willing to re-send "still typing" while the user types.
const Duration _kTypingResendDelay = Duration(seconds: 2);

/// Owns the per-room WebSocket: connection, reconnect with exponential
/// backoff, send pipeline (plain + E2E via [RoomCipher]), and typing
/// throttling.
///
/// Stays unaware of optimistic UI / outbox / cache — those live in the chat
/// state, which subscribes via the callbacks. Tests can substitute their
/// own callbacks to drive the transport in isolation.
class ChatTransport {
  final String roomId;
  final String token;
  final String wsBase;

  /// When non-null, sends go through E2E encryption. When null, the
  /// transport sends plaintext frames.
  final RoomCipher? cipher;

  // ---- callbacks -----------------------------------------------------------
  final void Function(Map<String, dynamic> frame) onMessage;
  final void Function(Map<String, dynamic> frame) onEdit;
  final void Function(Map<String, dynamic> frame) onDelete;
  final void Function(Map<String, dynamic> frame) onTyping;
  final void Function(bool connected) onConnectedChanged;

  /// Server told us the token is dead (close code 1008). State should drop
  /// the screen / invoke its auth-provider logout.
  final void Function() onUnauthorized;
  final void Function() onRateLimited;

  /// E2E send couldn't find a room key. State surfaces this to the user.
  final void Function() onMissingRoomKey;

  ChatTransport({
    required this.roomId,
    required this.token,
    required this.wsBase,
    required this.cipher,
    required this.onMessage,
    required this.onEdit,
    required this.onDelete,
    required this.onTyping,
    required this.onConnectedChanged,
    required this.onUnauthorized,
    required this.onRateLimited,
    required this.onMissingRoomKey,
  });

  // ---- internal state ------------------------------------------------------
  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _sub;
  bool _connected = false;
  int _attempt = 0;
  Timer? _reconnectTimer;
  bool _disposed = false;

  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _typingStopTimer;

  bool get isConnected => _connected;

  /// Open the socket. Idempotent — safe to call repeatedly; will no-op
  /// during reconnect backoff or after [dispose].
  void start() {
    if (_disposed) return;
    if (_ws != null) return;

    final uri = Uri.parse('$wsBase/rooms/$roomId/ws?token=$token');
    final ws = WebSocketChannel.connect(uri);
    _ws = ws;
    _sub = ws.stream.listen(
      _onFrame,
      onDone: _onDisconnect,
      onError: (_) => _onDisconnect(),
      cancelOnError: true,
    );
  }

  /// Cancel reconnect, close the socket. After this the transport is
  /// inert — discard it.
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _typingStopTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    try {
      _ws?.sink.close(ws_status.normalClosure);
    } catch (_) {}
    _ws = null;
  }

  // ---- send pipeline -------------------------------------------------------

  /// Send a message. Picks plain vs E2E based on whether a [cipher] was
  /// configured.  Both forms accept an optional [attachmentId].
  void send({
    required String clientId,
    required String text,
    String? attachmentId,
  }) {
    if (cipher == null) {
      _sendPlain(clientId: clientId, text: text, attachmentId: attachmentId);
    } else {
      unawaited(_sendEncrypted(
          clientId: clientId, text: text, attachmentId: attachmentId));
    }
  }

  void _sendPlain({
    required String clientId,
    required String text,
    String? attachmentId,
  }) {
    _writeFrame({
      'type': 'msg',
      'client_id': clientId,
      if (text.isNotEmpty) 'text': text,
      if (attachmentId != null) 'attachment_id': attachmentId,
    });
  }

  Future<void> _sendEncrypted({
    required String clientId,
    required String text,
    String? attachmentId,
  }) async {
    try {
      final enc = await cipher!.encryptMessage(text);
      _writeFrame({
        'type': 'msg',
        'client_id': clientId,
        'ciphertext': enc.cipher.ctB64,
        'iv': enc.cipher.ivB64,
        'key_version': enc.keyVersion,
        if (attachmentId != null) 'attachment_id': attachmentId,
      });
    } on RoomKeyUnavailable {
      onMissingRoomKey();
    } catch (_) {/* серверу отдадим из outbox позже */}
  }

  /// Throttled "user is typing" emitter. Call on every keystroke; the
  /// transport decides whether to push a frame (and schedules a follow-up
  /// "stopped" frame on idle).
  void notifyTyping() {
    final now = DateTime.now();
    if (now.difference(_lastTypingSent) > _kTypingResendDelay) {
      _lastTypingSent = now;
      _writeFrame({'type': 'typing', 'is_typing': true});
    }
    _typingStopTimer?.cancel();
    _typingStopTimer = Timer(_kTypingStopDelay, () {
      _writeFrame({'type': 'typing', 'is_typing': false});
    });
  }

  void _writeFrame(Map<String, Object?> payload) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.sink.add(jsonEncode(payload));
    } catch (_) {}
  }

  // ---- inbound -------------------------------------------------------------

  void _onFrame(dynamic raw) {
    _attempt = 0;
    _setConnected(true);
    try {
      final m = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (m['type']) {
        case 'msg':
          onMessage(m);
          break;
        case 'edit':
          onEdit(m);
          break;
        case 'delete':
          onDelete(m);
          break;
        case 'typing':
          onTyping(m);
          break;
        case 'error':
          if (m['code']?.toString() == 'rate_limited') onRateLimited();
          break;
      }
    } catch (_) {/* bad frame — ignore */}
  }

  void _onDisconnect() {
    if (_disposed) return;
    final code = _ws?.closeCode;
    _sub?.cancel();
    _sub = null;
    try {
      _ws?.sink.close();
    } catch (_) {}
    _ws = null;
    _setConnected(false);

    if (code == _kUnauthorizedCloseCode) {
      onUnauthorized();
      return;
    }
    final secs = _kReconnectDelaysSec[
        min(_attempt, _kReconnectDelaysSec.length - 1)];
    _attempt++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: secs), start);
  }

  void _setConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    onConnectedChanged(value);
  }
}
