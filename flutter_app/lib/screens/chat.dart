import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../api.dart';
import '../config.dart';
import '../state.dart';

enum _Status { sending, sent }

class _Msg {
  String? serverId;
  final String? clientId;
  final String userId;
  final String username;
  final String text;
  int createdAt;
  _Status status;

  _Msg({
    this.serverId,
    this.clientId,
    required this.userId,
    required this.username,
    required this.text,
    required this.createdAt,
    required this.status,
  });
}

String _uuidV4() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int x) => x.toRadixString(16).padLeft(2, '0');
  final s = b.map(h).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

class ChatScreen extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;
  const ChatScreen({super.key, required this.roomId, required this.roomName});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final List<_Msg> _messages = [];
  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scroll = ScrollController();

  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  bool _connected = false;
  bool _disposed = false;

  // Очередь pending-сообщений (по client_id) — переотправляются при реконнекте.
  final Map<String, _Msg> _pending = {};

  // Метка последнего полученного сообщения для catchup-запроса при реконнекте.
  int _lastSeenAt = 0;

  // Backoff: 1с → 2с → 4с → 8с → 16с → 30с, дальше держится 30с.
  int _attempt = 0;
  Timer? _reconnectTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final auth = ref.read(authProvider)!;
    try {
      final h = await Api(token: auth.token).history(widget.roomId);
      if (_disposed) return;
      for (final m in h.cast<Map<String, dynamic>>()) {
        _ingestServerMessage(m, scroll: false);
      }
      _scrollToEnd();
    } catch (_) {}
    _connect();
  }

  void _connect() {
    if (_disposed) return;
    final auth = ref.read(authProvider);
    if (auth == null) return;

    final uri = Uri.parse('${Config.wsBase}/rooms/${widget.roomId}/ws?token=${auth.token}');
    final ws = WebSocketChannel.connect(uri);
    _ws = ws;

    _sub = ws.stream.listen(
      (raw) {
        _attempt = 0;
        if (!_connected && mounted) setState(() => _connected = true);
        try {
          final m = jsonDecode(raw as String) as Map<String, dynamic>;
          if (m['type'] == 'msg') _ingestServerMessage(m);
        } catch (_) {}
      },
      onDone: _onDisconnect,
      onError: (_) => _onDisconnect(),
      cancelOnError: true,
    );

    // Догружаем пропущенное за оффлайн, потом переотправляем pending.
    // Сервер сам дедупит по (room_id, client_id), поэтому повторная отправка безопасна.
    Future<void>.microtask(() async {
      if (_lastSeenAt > 0) {
        try {
          final h = await Api(token: auth.token)
              .history(widget.roomId, after: _lastSeenAt, limit: 200);
          for (final m in h.cast<Map<String, dynamic>>()) {
            _ingestServerMessage(m, scroll: false);
          }
          _scrollToEnd();
        } catch (_) {}
      }
      _resendPending();
      if (!_connected && mounted) setState(() => _connected = true);
    });
  }

  void _onDisconnect() {
    if (_disposed) return;
    _sub?.cancel();
    _sub = null;
    try { _ws?.sink.close(); } catch (_) {}
    _ws = null;
    if (mounted) setState(() => _connected = false);

    const delays = [1, 2, 4, 8, 16, 30];
    final secs = delays[min(_attempt, delays.length - 1)];
    _attempt++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: secs), _connect);
  }

  void _ingestServerMessage(Map<String, dynamic> m, {bool scroll = true}) {
    final serverId = m['id']?.toString();
    if (serverId == null) return;
    final clientId = m['client_id']?.toString();
    final createdAt = (m['created_at'] as num?)?.toInt() ?? 0;

    // 1) Наш ack: ищем pending по client_id.
    if (clientId != null && _pending.containsKey(clientId)) {
      final p = _pending.remove(clientId)!;
      p.serverId = serverId;
      p.createdAt = createdAt;
      p.status = _Status.sent;
      _lastSeenAt = max(_lastSeenAt, createdAt);
      if (mounted) setState(() {});
      if (scroll) _scrollToEnd();
      return;
    }

    // 2) Дедуп по serverId (могло прийти и через broadcast, и через catchup).
    for (final existing in _messages) {
      if (existing.serverId == serverId) {
        _lastSeenAt = max(_lastSeenAt, createdAt);
        return;
      }
    }

    // 3) Новое сообщение.
    final msg = _Msg(
      serverId: serverId,
      clientId: clientId,
      userId: m['user_id']?.toString() ?? '',
      username: m['username']?.toString() ?? '',
      text: m['text']?.toString() ?? '',
      createdAt: createdAt,
      status: _Status.sent,
    );
    _messages.add(msg);
    _lastSeenAt = max(_lastSeenAt, createdAt);
    if (mounted) setState(() {});
    if (scroll) _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _send() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    final auth = ref.read(authProvider);
    if (auth == null) return;

    final clientId = _uuidV4();
    final msg = _Msg(
      clientId: clientId,
      userId: auth.userId,
      username: auth.username,
      text: t,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: _Status.sending,
    );
    _messages.add(msg);
    _pending[clientId] = msg;
    _ctrl.clear();
    setState(() {});
    _scrollToEnd();

    _trySend(msg);
  }

  void _trySend(_Msg m) {
    final ws = _ws;
    if (ws == null) return; // отправится в _resendPending при реконнекте
    try {
      ws.sink.add(jsonEncode({
        'type': 'msg',
        'client_id': m.clientId,
        'text': m.text,
      }));
    } catch (_) {
      // дроп — переотправится при следующем connect
    }
  }

  void _resendPending() {
    for (final m in _pending.values) {
      _trySend(m);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    try { _ws?.sink.close(ws_status.normalClosure); } catch (_) {}
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authProvider)?.userId;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.roomName),
        bottom: _connected
            ? null
            : const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(8),
              itemCount: _messages.length,
              itemBuilder: (_, i) {
                final m = _messages[i];
                final mine = m.userId == me;
                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75,
                    ),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: mine ? Colors.indigo.shade400 : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!mine)
                          Text(
                            m.username,
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        Text(
                          m.text,
                          style: TextStyle(color: mine ? Colors.white : Colors.black87),
                        ),
                        if (mine)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(
                              m.status == _Status.sent ? Icons.done_all : Icons.access_time,
                              size: 12,
                              color: Colors.white70,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      decoration: const InputDecoration(
                        hintText: 'Сообщение...',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
