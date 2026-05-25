import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../api.dart';
import '../config.dart';
import '../state.dart';
import '../storage/cache.dart';

/// Глобальный per-user WebSocket (`/v1/ws`).
/// Живёт всё время, пока есть auth, переподключается с backoff.
/// События пишутся напрямую в кэши — UI обновляется через стримы.
class UserWs {
  final String token;
  final String userId;
  final Ref ref;

  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  bool _disposed = false;
  int _attempt = 0;
  Timer? _reconnect;

  // Соединено ли (после `hello`).
  final StreamController<bool> _connectedCtrl = StreamController.broadcast();
  Stream<bool> get connected => _connectedCtrl.stream;

  UserWs({required this.token, required this.userId, required this.ref}) {
    _connect();
  }

  void dispose() {
    _disposed = true;
    _reconnect?.cancel();
    _sub?.cancel();
    try { _ws?.sink.close(ws_status.normalClosure); } catch (_) { /* */ }
    _connectedCtrl.close();
  }

  void _connect() {
    if (_disposed) return;
    final uri = Uri.parse('${Config.wsBase}/v1/ws?token=$token');
    final ws = WebSocketChannel.connect(uri);
    _ws = ws;
    _sub = ws.stream.listen(
      _onMessage,
      onDone: _onDisconnect,
      onError: (_) => _onDisconnect(),
      cancelOnError: true,
    );
  }

  void _onDisconnect() {
    if (_disposed) return;
    final code = _ws?.closeCode;
    _sub?.cancel();
    _sub = null;
    try { _ws?.sink.close(); } catch (_) { /* */ }
    _ws = null;
    _connectedCtrl.add(false);

    if (code == 1008) {
      // токен мёртв → глобальный force-logout
      ref.read(authProvider.notifier).forceLogout();
      return;
    }
    const delays = [1, 2, 4, 8, 16, 30];
    final secs = delays[min(_attempt, delays.length - 1)];
    _attempt++;
    _reconnect?.cancel();
    _reconnect = Timer(Duration(seconds: secs), _connect);
  }

  void _onMessage(dynamic raw) {
    if (_disposed) return;
    _attempt = 0;
    if (raw is! String) return;
    Map<String, dynamic> m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['type']) {
      case 'hello':
        _connectedCtrl.add(true);
        // На каждый успешный коннект — мягкий рефреш списков, чтобы
        // нагнать события, пропущенные в офлайне.
        _refreshAll();
        break;
      case 'new_message':
        _onNewMessage(m);
        break;
      case 'message_edited':
        _onEdited(m);
        break;
      case 'message_deleted':
        _onDeleted(m);
        break;
      case 'read_self':
        _onReadSelf(m);
        break;
      case 'room_added':
        _onRoomAdded(m);
        break;
      case 'room_removed':
        _onRoomRemoved(m);
        break;
      case 'invite_received':
        _onInviteReceived(m);
        break;
      case 'invite_revoked':
        _onInviteRevoked(m);
        break;
      case 'friend_request_received':
        _onFriendRequestReceived(m);
        break;
      case 'friend_added':
        _onFriendAdded(m);
        break;
      case 'friend_removed':
        _onFriendRemoved(m);
        break;
    }
  }

  Future<void> _onFriendRequestReceived(Map<String, dynamic> m) async {
    final req = m['request'] as Map<String, dynamic>?;
    if (req == null) return;
    await FriendRequestsCache.upsert(req);
  }

  Future<void> _onFriendAdded(Map<String, dynamic> m) async {
    final uid = m['user_id']?.toString();
    final un = m['username']?.toString();
    if (uid == null || un == null || uid.isEmpty || un.isEmpty) return;
    await FriendsCache.upsert(userId: uid, username: un);
    // Server-confirmed friendship — drop any matching pending request locally.
    try {
      final cur = await FriendRequestsCache.snapshot();
      for (final r in cur) {
        if (r.fromUserId == uid) {
          await FriendRequestsCache.remove(r.id);
        }
      }
    } catch (_) {}
  }

  Future<void> _onFriendRemoved(Map<String, dynamic> m) async {
    final uid = m['user_id']?.toString();
    if (uid == null) return;
    await FriendsCache.remove(uid);
  }

  Future<void> _refreshAll() async {
    try {
      final rooms = await Api(token: token).rooms();
      await RoomsCache.replaceAll(rooms.cast<Map<String, dynamic>>());
    } catch (_) { /* */ }
    try {
      final inv = await Api(token: token).invites();
      await InvitesCache.replaceAll(inv.cast<Map<String, dynamic>>());
    } catch (_) { /* */ }
    try {
      final fs = await Api(token: token).friends();
      await FriendsCache.replaceAll(fs.cast<Map<String, dynamic>>());
    } catch (_) { /* */ }
    try {
      final rs = await Api(token: token).friendRequests();
      await FriendRequestsCache.replaceAll(rs.cast<Map<String, dynamic>>());
    } catch (_) { /* */ }
  }

  Future<void> _onNewMessage(Map<String, dynamic> m) async {
    final roomId = m['room_id']?.toString();
    if (roomId == null) return;
    final msg = (m['message'] as Map<String, dynamic>?) ?? const {};
    final senderId = msg['user_id']?.toString() ?? '';
    final preview = (msg['text'] as String?)?.trim() ?? '';
    final hasCiphertext = (msg['ciphertext'] as String?)?.isNotEmpty == true;
    final createdAt = (msg['created_at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;

    await MessagesCache.upsert(roomId, msg);

    // In E2E rooms we can't preview the text (server never saw it). Show a
    // lock icon as the room-list preview instead — actual plaintext renders
    // only after the user opens the chat and decrypts.
    final lastText = hasCiphertext
        ? '🔒 шифрованное сообщение'
        : preview.isNotEmpty
            ? preview
            : '📎 вложение';
    await RoomsCache.setLast(roomId, lastText, createdAt);
    final activeRoom = ref.read(currentRoomProvider);
    if (senderId != userId && activeRoom != roomId) {
      await RoomsCache.bumpUnread(roomId);
    }
  }

  Future<void> _onEdited(Map<String, dynamic> m) async {
    final roomId = m['room_id']?.toString();
    final id = m['id']?.toString();
    if (roomId == null || id == null) return;
    await MessagesCache.applyEdit(
      roomId,
      id,
      m['text']?.toString() ?? '',
      (m['edited_at'] as num?)?.toInt(),
    );
  }

  Future<void> _onDeleted(Map<String, dynamic> m) async {
    final roomId = m['room_id']?.toString();
    final id = m['id']?.toString();
    if (roomId == null || id == null) return;
    await MessagesCache.applyDelete(roomId, id, (m['deleted_at'] as num?)?.toInt());
  }

  Future<void> _onReadSelf(Map<String, dynamic> m) async {
    final roomId = m['room_id']?.toString();
    if (roomId == null) return;
    await RoomsCache.setUnread(roomId, 0);
  }

  Future<void> _onRoomAdded(Map<String, dynamic> m) async {
    final r = m['room'] as Map<String, dynamic>?;
    if (r == null) return;
    await RoomsCache.upsert(r);
  }

  Future<void> _onRoomRemoved(Map<String, dynamic> m) async {
    final id = m['room_id']?.toString();
    if (id == null) return;
    await RoomsCache.remove(id);
  }

  Future<void> _onInviteReceived(Map<String, dynamic> m) async {
    final inv = m['invite'] as Map<String, dynamic>?;
    if (inv == null) return;
    await InvitesCache.upsert(inv);
  }

  Future<void> _onInviteRevoked(Map<String, dynamic> m) async {
    final id = m['id']?.toString();
    if (id == null) return;
    await InvitesCache.remove(id);
  }
}

/// Eager-провайдер: подключается, как только auth не null; рвётся на logout.
/// Возвращает текущий контроллер, но обычно его не читают напрямую —
/// он работает «в фоне», обновляя кэши.
final userWsProvider = Provider<UserWs?>((ref) {
  final auth = ref.watch(authProvider);
  if (auth == null) return null;
  final ws = UserWs(token: auth.token, userId: auth.userId, ref: ref);
  ref.onDispose(ws.dispose);
  return ws;
});

/// Стрим online/offline для индикатора в UI.
final userWsConnectedProvider = StreamProvider<bool>((ref) {
  final ws = ref.watch(userWsProvider);
  if (ws == null) return const Stream.empty();
  return ws.connected;
});
