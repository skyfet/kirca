import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../api.dart';
import '../config.dart';
import '../state.dart';
import '../storage/outbox.dart';
import 'members.dart';

enum _Status { sending, sent }

class _Attachment {
  final String? id;
  final String? url;
  final String mime;
  final int? width;
  final int? height;
  _Attachment({this.id, this.url, required this.mime, this.width, this.height});
}

class _Msg {
  String? serverId;
  final String? clientId;
  final String userId;
  final String username;
  String text;
  int createdAt;
  int? editedAt;
  int? deletedAt;
  _Attachment? attachment;
  _Status status;

  _Msg({
    this.serverId,
    this.clientId,
    required this.userId,
    required this.username,
    required this.text,
    required this.createdAt,
    this.editedAt,
    this.deletedAt,
    this.attachment,
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
  final bool isPublic;
  final bool muted;
  const ChatScreen({
    super.key,
    required this.roomId,
    required this.roomName,
    this.isPublic = true,
    this.muted = false,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> with WidgetsBindingObserver {
  final List<_Msg> _messages = [];
  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scroll = ScrollController();

  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  bool _connected = false;
  bool _disposed = false;
  bool _muted = false;

  final Map<String, _Msg> _pending = {};

  // Метка последнего полученного сообщения для catchup-запроса при реконнекте.
  int _lastSeenAt = 0;
  // Метка, до которой мы пометили «прочитано».
  int _lastReadSent = 0;
  // Подгрузка истории вверх.
  bool _loadingOlder = false;
  bool _hasMoreOlder = true;

  // Typing-индикатор: пиры, которые сейчас печатают (user_id → таймер сброса).
  final Map<String, Timer> _peerTyping = {};
  // Своё состояние: когда последний раз слали typing=true.
  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _typingStopTimer;

  int _attempt = 0;
  Timer? _reconnectTimer;

  @override
  void initState() {
    super.initState();
    _muted = widget.muted;
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _maybeMarkRead();
    }
  }

  Future<void> _init() async {
    try {
      final saved = await Outbox.byRoom(widget.roomId);
      final auth = ref.read(authProvider);
      for (final s in saved) {
        final m = _Msg(
          clientId: s.clientId,
          userId: auth?.userId ?? '',
          username: auth?.username ?? '',
          text: s.text,
          createdAt: s.createdAt,
          status: _Status.sending,
        );
        _messages.add(m);
        _pending[s.clientId] = m;
      }
      if (saved.isNotEmpty && mounted) setState(() {});
    } catch (_) {}

    final auth = ref.read(authProvider);
    if (auth == null) return;
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

  void _onScroll() {
    // Подгружаем старые сообщения при скролле к самому верху.
    if (_scroll.position.pixels <= 80 && !_loadingOlder && _hasMoreOlder && _messages.isNotEmpty) {
      _loadOlder();
    }
  }

  Future<void> _loadOlder() async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    _loadingOlder = true;
    if (mounted) setState(() {});
    try {
      // ищем самый ранний реальный (с serverId) — outbox-сообщения не считаются.
      final firstServer = _messages.firstWhere(
        (m) => m.serverId != null,
        orElse: () => _Msg(userId: '', username: '', text: '', createdAt: 0, status: _Status.sent),
      );
      if (firstServer.createdAt == 0) {
        _hasMoreOlder = false;
        return;
      }
      final h = await Api(token: auth.token).history(
        widget.roomId,
        before: firstServer.createdAt,
        limit: 50,
      );
      if (h.isEmpty) {
        _hasMoreOlder = false;
        return;
      }
      // сохраняем offset скролла, чтобы не «прыгало»
      final beforeMax = _scroll.position.maxScrollExtent;
      final beforePixels = _scroll.position.pixels;
      // Префиксим список (старые в начале).
      final older = <_Msg>[];
      for (final raw in h.cast<Map<String, dynamic>>()) {
        final m = _msgFromMap(raw);
        // Игнорим дубли, если ровно граница.
        if (m.serverId != null &&
            _messages.any((x) => x.serverId == m.serverId)) {
          continue;
        }
        older.add(m);
      }
      if (older.isEmpty) {
        _hasMoreOlder = h.length >= 50;
        return;
      }
      _messages.insertAll(0, older);
      if (mounted) setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final newMax = _scroll.position.maxScrollExtent;
        _scroll.jumpTo(beforePixels + (newMax - beforeMax));
      });
    } catch (_) {
      // не блокируем UI, попробуем в другой раз
    } finally {
      _loadingOlder = false;
      if (mounted) setState(() {});
    }
  }

  _Msg _msgFromMap(Map<String, dynamic> m) {
    final att = m['attachment'] as Map<String, dynamic>?;
    return _Msg(
      serverId: m['id']?.toString(),
      clientId: m['client_id']?.toString(),
      userId: m['user_id']?.toString() ?? '',
      username: m['username']?.toString() ?? '',
      text: m['text']?.toString() ?? '',
      createdAt: (m['created_at'] as num?)?.toInt() ?? 0,
      editedAt: (m['edited_at'] as num?)?.toInt(),
      deletedAt: (m['deleted_at'] as num?)?.toInt(),
      attachment: att == null
          ? null
          : _Attachment(
              id: att['id']?.toString(),
              url: att['url']?.toString(),
              mime: att['mime']?.toString() ?? 'image/*',
              width: (att['width'] as num?)?.toInt(),
              height: (att['height'] as num?)?.toInt(),
            ),
      status: _Status.sent,
    );
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
          final type = m['type'];
          switch (type) {
            case 'msg':
              _ingestServerMessage(m);
              break;
            case 'edit':
              _applyEdit(m);
              break;
            case 'delete':
              _applyDelete(m);
              break;
            case 'typing':
              _applyTyping(m);
              break;
            case 'read':
              // на эту версию визуализация «кто прочитал» опущена;
              // событие игнорируем.
              break;
            case 'presence':
              // обновлять иконки в шапке смысла нет — это список участников.
              break;
            case 'error':
              if (m['code']?.toString() == 'rate_limited' && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Слишком много сообщений, подожди немного')),
                );
              }
              break;
          }
        } catch (_) {}
      },
      onDone: _onDisconnect,
      onError: (_) => _onDisconnect(),
      cancelOnError: true,
    );

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

  void _applyEdit(Map<String, dynamic> m) {
    final id = m['id']?.toString();
    if (id == null) return;
    for (final x in _messages) {
      if (x.serverId == id) {
        x.text = m['text']?.toString() ?? x.text;
        x.editedAt = (m['edited_at'] as num?)?.toInt();
        if (mounted) setState(() {});
        break;
      }
    }
  }

  void _applyDelete(Map<String, dynamic> m) {
    final id = m['id']?.toString();
    if (id == null) return;
    for (final x in _messages) {
      if (x.serverId == id) {
        x.text = '';
        x.deletedAt = (m['deleted_at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
        if (mounted) setState(() {});
        break;
      }
    }
  }

  void _applyTyping(Map<String, dynamic> m) {
    final uid = m['user_id']?.toString();
    final me = ref.read(authProvider)?.userId;
    if (uid == null || uid == me) return;
    final isTyping = m['is_typing'] != false;
    _peerTyping[uid]?.cancel();
    if (isTyping) {
      _peerTyping[uid] = Timer(const Duration(seconds: 4), () {
        _peerTyping.remove(uid);
        if (mounted) setState(() {});
      });
    } else {
      _peerTyping.remove(uid);
    }
    if (mounted) setState(() {});
  }

  void _onDisconnect() {
    if (_disposed) return;
    final code = _ws?.closeCode;
    _sub?.cancel();
    _sub = null;
    try { _ws?.sink.close(); } catch (_) {}
    _ws = null;
    if (mounted) setState(() => _connected = false);

    if (code == 1008) {
      ref.read(authProvider.notifier).forceLogout();
      return;
    }

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

    if (clientId != null && _pending.containsKey(clientId)) {
      final p = _pending.remove(clientId)!;
      p.serverId = serverId;
      p.createdAt = createdAt;
      p.status = _Status.sent;
      final att = m['attachment'] as Map<String, dynamic>?;
      if (att != null) {
        p.attachment = _Attachment(
          id: att['id']?.toString(),
          url: att['url']?.toString(),
          mime: att['mime']?.toString() ?? 'image/*',
          width: (att['width'] as num?)?.toInt(),
          height: (att['height'] as num?)?.toInt(),
        );
      }
      _lastSeenAt = max(_lastSeenAt, createdAt);
      Outbox.remove(clientId);
      if (mounted) setState(() {});
      if (scroll) _scrollToEnd();
      _maybeMarkRead();
      return;
    }

    for (final existing in _messages) {
      if (existing.serverId == serverId) {
        _lastSeenAt = max(_lastSeenAt, createdAt);
        return;
      }
    }

    _messages.add(_msgFromMap(m));
    _lastSeenAt = max(_lastSeenAt, createdAt);
    if (mounted) setState(() {});
    if (scroll) _scrollToEnd();
    _maybeMarkRead();
  }

  Future<void> _maybeMarkRead() async {
    if (_lastSeenAt <= _lastReadSent) return;
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final ts = _lastSeenAt;
    _lastReadSent = ts;
    try {
      await Api(token: auth.token).markRead(widget.roomId, ts);
    } catch (_) { /* best-effort */ }
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

  void _onTextChanged(String _) {
    final ws = _ws;
    if (ws == null) return;
    final now = DateTime.now();
    if (now.difference(_lastTypingSent) > const Duration(seconds: 2)) {
      _lastTypingSent = now;
      try {
        ws.sink.add(jsonEncode({'type': 'typing', 'is_typing': true}));
      } catch (_) {}
    }
    _typingStopTimer?.cancel();
    _typingStopTimer = Timer(const Duration(seconds: 3), () {
      try {
        _ws?.sink.add(jsonEncode({'type': 'typing', 'is_typing': false}));
      } catch (_) {}
    });
  }

  void _send() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    _sendCore(text: t);
  }

  void _sendCore({String text = '', String? attachmentId, _Attachment? attPreview}) {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final clientId = _uuidV4();
    final createdAt = DateTime.now().millisecondsSinceEpoch;
    final msg = _Msg(
      clientId: clientId,
      userId: auth.userId,
      username: auth.username,
      text: text,
      createdAt: createdAt,
      attachment: attPreview,
      status: _Status.sending,
    );
    _messages.add(msg);
    _pending[clientId] = msg;
    if (text.isNotEmpty) _ctrl.clear();
    setState(() {});
    _scrollToEnd();

    Outbox.add(
      clientId: clientId,
      roomId: widget.roomId,
      text: text,
      createdAt: createdAt,
    );
    _trySend(msg, attachmentId: attachmentId);
  }

  void _trySend(_Msg m, {String? attachmentId}) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.sink.add(jsonEncode({
        'type': 'msg',
        'client_id': m.clientId,
        if (m.text.isNotEmpty) 'text': m.text,
        if (attachmentId != null) 'attachment_id': attachmentId,
      }));
    } catch (_) {}
  }

  void _resendPending() {
    for (final m in _pending.values) {
      _trySend(m, attachmentId: m.attachment?.id);
    }
  }

  Future<void> _pickAndSendImage() async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    // Сжатие на клиенте: re-encode в JPEG q80, max 1280px по большей стороне.
    // Без этого крупное фото с iPhone не пройдёт серверный лимит (800 КБ).
    final compressed = await FlutterImageCompress.compressWithFile(
      picked.path,
      minWidth: 1280,
      minHeight: 1280,
      quality: 80,
      format: CompressFormat.jpeg,
    );
    if (compressed == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось сжать изображение')));
      }
      return;
    }
    final bytes = compressed;
    const mime = 'image/jpeg';
    if (bytes.length > 800 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Изображение слишком большое после сжатия')));
      }
      return;
    }
    try {
      final reserved = await Api(token: auth.token).reserveUpload(
        mime: mime,
        size: bytes.length,
      );
      final uploadUrl = reserved['upload_url']?.toString();
      final attachmentId = reserved['id']?.toString();
      if (uploadUrl == null || attachmentId == null) return;
      await Api(token: auth.token).uploadBytes(uploadUrl, bytes, mime);
      _sendCore(
        attachmentId: attachmentId,
        attPreview: _Attachment(id: attachmentId, url: '/attachments/$attachmentId', mime: mime),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _editMsg(_Msg m) async {
    if (m.serverId == null) return;
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final ctrl = TextEditingController(text: m.text);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Редактировать'),
        content: TextField(controller: ctrl, autofocus: true, maxLines: 4),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok != true) return;
    final text = ctrl.text.trim();
    if (text.isEmpty || text == m.text) return;
    try {
      await Api(token: auth.token).editMessage(widget.roomId, m.serverId!, text);
      // оптимистично применяем (DO разошлёт edit-событие — но мы можем уже отрисовать)
      m.text = text;
      m.editedAt = DateTime.now().millisecondsSinceEpoch;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _deleteMsg(_Msg m) async {
    if (m.serverId == null) return;
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить сообщение?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api(token: auth.token).deleteMessage(widget.roomId, m.serverId!);
      m.text = '';
      m.deletedAt = DateTime.now().millisecondsSinceEpoch;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _toggleMute() async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final next = !_muted;
    setState(() => _muted = next);
    try {
      await Api(token: auth.token).setMuted(widget.roomId, next);
    } catch (_) {
      setState(() => _muted = !next);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _typingStopTimer?.cancel();
    for (final t in _peerTyping.values) {
      t.cancel();
    }
    _sub?.cancel();
    try { _ws?.sink.close(ws_status.normalClosure); } catch (_) {}
    _ctrl.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final me = auth?.userId;
    final typingNames = _peerTyping.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.roomName),
        actions: [
          IconButton(
            tooltip: _muted ? 'Включить уведомления' : 'Заглушить',
            icon: Icon(_muted ? Icons.notifications_off : Icons.notifications_active),
            onPressed: _toggleMute,
          ),
          IconButton(
            tooltip: 'Участники',
            icon: const Icon(Icons.people_outline),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MembersScreen(
                  roomId: widget.roomId,
                  roomName: widget.roomName,
                  isPublic: widget.isPublic,
                ),
              ),
            ),
          ),
        ],
        bottom: _connected
            ? null
            : const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              ),
      ),
      body: Column(
        children: [
          if (_loadingOlder)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(8),
              itemCount: _messages.length,
              itemBuilder: (_, i) {
                final m = _messages[i];
                final mine = m.userId == me;
                return GestureDetector(
                  onLongPress: mine && m.serverId != null && m.deletedAt == null
                      ? () => _showMsgMenu(m)
                      : null,
                  child: Align(
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
                          if (m.attachment != null && m.attachment!.url != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4, top: 2),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  resolveMediaUrl(m.attachment!.url!),
                                  headers: mediaHeaders(auth?.token),
                                  width: 220,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
                                ),
                              ),
                            ),
                          if (m.deletedAt != null)
                            Text(
                              'сообщение удалено',
                              style: TextStyle(
                                fontStyle: FontStyle.italic,
                                color: mine ? Colors.white70 : Colors.black54,
                              ),
                            )
                          else if (m.text.isNotEmpty)
                            Text(
                              m.text,
                              style: TextStyle(color: mine ? Colors.white : Colors.black87),
                            ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (m.editedAt != null && m.deletedAt == null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2, right: 4),
                                  child: Text(
                                    'изменено',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: mine ? Colors.white60 : Colors.black45,
                                    ),
                                  ),
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
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (typingNames > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  typingNames == 1 ? 'кто-то печатает…' : '$typingNames пользователей печатают…',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Прикрепить',
                    icon: const Icon(Icons.image_outlined),
                    onPressed: _pickAndSendImage,
                  ),
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
                      onChanged: _onTextChanged,
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

  void _showMsgMenu(_Msg m) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m.text.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Редактировать'),
                onTap: () {
                  Navigator.pop(ctx);
                  _editMsg(m);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Удалить', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteMsg(m);
              },
            ),
          ],
        ),
      ),
    );
  }
}
