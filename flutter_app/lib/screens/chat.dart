import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../api.dart';
import '../config.dart';
import '../state.dart';
import '../storage/cache.dart';
import '../storage/outbox.dart';
import '../theme/app_background.dart';
import '../theme/app_theme.dart';
import 'members.dart';

enum _SendStatus { sending, sent }

class _Pending {
  final String clientId;
  final String text;
  final int createdAt;
  CachedAttachment? attachment;
  _SendStatus status;
  _Pending({
    required this.clientId,
    required this.text,
    required this.createdAt,
    this.attachment,
    this.status = _SendStatus.sending,
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

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scroll = ScrollController();

  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  bool _connected = false;
  bool _disposed = false;
  bool _muted = false;

  /// pending (sending) messages, key = clientId.
  final Map<String, _Pending> _pending = {};

  int _lastSeenAt = 0;
  int _lastReadSent = 0;

  bool _loadingOlder = false;
  bool _hasMoreOlder = true;

  // typing: peer_id -> reset timer.
  final Map<String, Timer> _peerTyping = {};
  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _typingStopTimer;

  int _attempt = 0;
  Timer? _reconnectTimer;

  // Хранит id последнего сообщения, чтобы автоскроллить только при появлении
  // нового, а не на каждое изменение (edit).
  String? _lastTailId;
  bool _didInitialScroll = false;

  @override
  void initState() {
    super.initState();
    _muted = widget.muted;
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    // Сообщаем глобальному WS, что активная комната — эта, чтобы не бампить
    // unread на свои же входящие сюда.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) {
        ref.read(currentRoomProvider.notifier).state = widget.roomId;
      }
    });
    _hydrateAndConnect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _maybeMarkRead();
  }

  Future<void> _hydrateAndConnect() async {
    // 1. Загрузить outbox → pending.
    try {
      final saved = await Outbox.byRoom(widget.roomId);
      for (final s in saved) {
        _pending[s.clientId] = _Pending(
          clientId: s.clientId,
          text: s.text,
          createdAt: s.createdAt,
        );
      }
      if (saved.isNotEmpty && mounted) setState(() {});
    } catch (_) {}

    // 2. Стартовать WS. История подтянется через `messagesProvider`.
    _connect();
  }

  void _onScroll() {
    if (_scroll.position.pixels <= 80 &&
        !_loadingOlder &&
        _hasMoreOlder) {
      _loadOlder();
    }
  }

  Future<void> _loadOlder() async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final cached = await MessagesCache.snapshot(widget.roomId);
    if (cached.isEmpty) {
      _hasMoreOlder = false;
      return;
    }
    _loadingOlder = true;
    if (mounted) setState(() {});
    try {
      final before = cached.first.createdAt;
      final h = await Api(token: auth.token)
          .history(widget.roomId, before: before, limit: 50);
      if (h.isEmpty) {
        _hasMoreOlder = false;
        return;
      }
      final beforeMax = _scroll.position.maxScrollExtent;
      final beforePixels = _scroll.position.pixels;
      await MessagesCache.upsertAll(widget.roomId, h.cast<Map<String, dynamic>>());
      if (h.length < 50) _hasMoreOlder = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final newMax = _scroll.position.maxScrollExtent;
        _scroll.jumpTo(beforePixels + (newMax - beforeMax));
      });
    } catch (_) {
      // тихо — в следующий раз
    } finally {
      _loadingOlder = false;
      if (mounted) setState(() {});
    }
  }

  void _connect() {
    if (_disposed) return;
    final auth = ref.read(authProvider);
    if (auth == null) return;

    final uri = Uri.parse(
        '${Config.wsBase}/rooms/${widget.roomId}/ws?token=${auth.token}');
    final ws = WebSocketChannel.connect(uri);
    _ws = ws;

    _sub = ws.stream.listen(
      (raw) {
        _attempt = 0;
        if (!_connected && mounted) setState(() => _connected = true);
        try {
          final m = jsonDecode(raw as String) as Map<String, dynamic>;
          switch (m['type']) {
            case 'msg':
              _onWsMessage(m);
              break;
            case 'edit':
              _onWsEdit(m);
              break;
            case 'delete':
              _onWsDelete(m);
              break;
            case 'typing':
              _onWsTyping(m);
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

    // Catchup пропущенного через REST + переотправка pending.
    Future<void>.microtask(() async {
      if (_lastSeenAt > 0) {
        try {
          final h = await Api(token: auth.token)
              .history(widget.roomId, after: _lastSeenAt, limit: 200);
          if (h.isNotEmpty) {
            await MessagesCache.upsertAll(
                widget.roomId, h.cast<Map<String, dynamic>>());
          }
        } catch (_) {}
      }
      _resendPending();
      if (!_connected && mounted) setState(() => _connected = true);
    });
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

  void _onWsMessage(Map<String, dynamic> m) {
    final clientId = m['client_id']?.toString();
    final createdAt = (m['created_at'] as num?)?.toInt() ?? 0;
    if (clientId != null && _pending.containsKey(clientId)) {
      _pending.remove(clientId);
      Outbox.remove(clientId);
    }
    MessagesCache.upsert(widget.roomId, m);
    _lastSeenAt = max(_lastSeenAt, createdAt);
    if (mounted) setState(() {});
    _maybeMarkRead();
  }

  void _onWsEdit(Map<String, dynamic> m) {
    final id = m['id']?.toString();
    if (id == null) return;
    MessagesCache.applyEdit(
      widget.roomId,
      id,
      m['text']?.toString() ?? '',
      (m['edited_at'] as num?)?.toInt(),
    );
  }

  void _onWsDelete(Map<String, dynamic> m) {
    final id = m['id']?.toString();
    if (id == null) return;
    MessagesCache.applyDelete(
      widget.roomId,
      id,
      (m['deleted_at'] as num?)?.toInt(),
    );
  }

  void _onWsTyping(Map<String, dynamic> m) {
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

  Future<void> _maybeMarkRead() async {
    if (_lastSeenAt <= _lastReadSent) return;
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final ts = _lastSeenAt;
    _lastReadSent = ts;
    try {
      await Api(token: auth.token).markRead(widget.roomId, ts);
      await RoomsCache.setUnread(widget.roomId, 0);
    } catch (_) {}
  }

  void _scrollToEnd({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(target,
            duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
      } else {
        _scroll.jumpTo(target);
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

  void _sendCore({String text = '', String? attachmentId, CachedAttachment? attPreview}) {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final clientId = _uuidV4();
    final createdAt = DateTime.now().millisecondsSinceEpoch;
    _pending[clientId] = _Pending(
      clientId: clientId,
      text: text,
      createdAt: createdAt,
      attachment: attPreview,
    );
    if (text.isNotEmpty) _ctrl.clear();
    setState(() {});
    _scrollToEnd();
    Outbox.add(
      clientId: clientId,
      roomId: widget.roomId,
      text: text,
      createdAt: createdAt,
    );
    _wsSend(clientId, text, attachmentId);
  }

  void _wsSend(String clientId, String text, String? attachmentId) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.sink.add(jsonEncode({
        'type': 'msg',
        'client_id': clientId,
        if (text.isNotEmpty) 'text': text,
        if (attachmentId != null) 'attachment_id': attachmentId,
      }));
    } catch (_) {}
  }

  void _resendPending() {
    for (final p in _pending.values) {
      _wsSend(p.clientId, p.text, p.attachment?.id);
    }
  }

  Future<void> _pickAndSendImage() async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(
        source: ImageSource.gallery, maxWidth: 2048, maxHeight: 2048);
    if (picked == null) return;
    final bytes = await File(picked.path).readAsBytes();
    final mime = _mimeFromPath(picked.path);
    if (mime == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Неподдерживаемый формат')),
        );
      }
      return;
    }
    try {
      final reserved =
          await Api(token: auth.token).reserveUpload(mime: mime, size: bytes.length);
      final uploadUrl = reserved['upload_url']?.toString();
      final attachmentId = reserved['id']?.toString();
      final publicUrl = reserved['public_url']?.toString();
      if (uploadUrl == null || attachmentId == null) return;
      await Api(token: auth.token).uploadBytes(uploadUrl, bytes, mime);
      _sendCore(
        attachmentId: attachmentId,
        attPreview: CachedAttachment(id: attachmentId, url: publicUrl, mime: mime),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  String? _mimeFromPath(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.webp')) return 'image/webp';
    if (p.endsWith('.gif')) return 'image/gif';
    if (p.endsWith('.heic')) return 'image/heic';
    return null;
  }

  Future<void> _editMsg(CachedMessage m) async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final ctrl = TextEditingController(text: m.text);
    final ok = await GlassDialog.show<bool>(
      context: context,
      title: 'Редактировать',
      content: GlassTextField(controller: ctrl, autofocus: true, maxLines: 4),
      actions: [
        GlassDialogAction(label: 'Отмена', onPressed: () => Navigator.pop(context, false)),
        GlassDialogAction(label: 'Сохранить', isPrimary: true, onPressed: () => Navigator.pop(context, true)),
      ],
    );
    if (ok != true) return;
    final text = ctrl.text.trim();
    if (text.isEmpty || text == m.text) return;
    try {
      await Api(token: auth.token).editMessage(widget.roomId, m.id, text);
      await MessagesCache.applyEdit(widget.roomId, m.id, text, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _deleteMsg(CachedMessage m) async {
    final auth = ref.read(authProvider);
    if (auth == null) return;
    final ok = await GlassDialog.show<bool>(
      context: context,
      title: 'Удалить сообщение?',
      actions: [
        GlassDialogAction(label: 'Отмена', onPressed: () => Navigator.pop(context, false)),
        GlassDialogAction(label: 'Удалить', isDestructive: true, onPressed: () => Navigator.pop(context, true)),
      ],
    );
    if (ok != true) return;
    try {
      await Api(token: auth.token).deleteMessage(widget.roomId, m.id);
      await MessagesCache.applyDelete(widget.roomId, m.id, DateTime.now().millisecondsSinceEpoch);
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
    await RoomsCache.setMuted(widget.roomId, next);
    try {
      await Api(token: auth.token).setMuted(widget.roomId, next);
    } catch (_) {
      if (!mounted) return;
      setState(() => _muted = !next);
      await RoomsCache.setMuted(widget.roomId, !next);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // Снимаем флаг активной комнаты — теперь фоновые сообщения снова
    // увеличивают unread.
    final notifier = ref.read(currentRoomProvider.notifier);
    if (notifier.state == widget.roomId) {
      notifier.state = null;
    }
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
    final me = ref.watch(authProvider)?.userId ?? '';
    final myUsername = ref.watch(authProvider)?.username ?? '';
    final cachedAsync = ref.watch(messagesProvider(widget.roomId));
    final cached = cachedAsync.valueOrNull ?? const <CachedMessage>[];

    // Реагируем на появление нового хвостового сообщения вне build-цикла:
    // обновить _lastSeenAt, скролл вниз, mark-read.
    ref.listen<AsyncValue<List<CachedMessage>>>(
      messagesProvider(widget.roomId),
      (prev, next) {
        final list = next.valueOrNull;
        if (list == null || list.isEmpty) return;
        _lastSeenAt = max(_lastSeenAt, list.last.createdAt);
        if (list.last.id != _lastTailId) {
          _lastTailId = list.last.id;
          _scrollToEnd();
          _maybeMarkRead();
        }
      },
    );

    // Один разовый скролл в конец при первом появлении кэша.
    if (!_didInitialScroll && cached.isNotEmpty) {
      _didInitialScroll = true;
      _lastTailId = cached.last.id;
      _lastSeenAt = max(_lastSeenAt, cached.last.createdAt);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToEnd(animate: false);
        _maybeMarkRead();
      });
    }

    final allItems = <_Row>[];
    for (final m in cached) {
      allItems.add(_Row.server(m));
    }
    for (final p in _pending.values) {
      allItems.add(_Row.pending(p, me, myUsername));
    }
    allItems.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return GlassPage(
      background: const AppBackground(),
      statusBarStyle: GlassStatusBarStyle.light,
      edgeToEdge: true,
      child: AdaptiveLiquidGlassLayer(
        clipBehavior: Clip.none,
        child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        extendBody: true,
        appBar: GlassAppBar(
          leading: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: GlassIconButton(
              size: 36,
              icon: const Icon(Icons.arrow_back_ios_new, color: AppColors.onGlass, size: 18),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          title: Text(
            widget.roomName,
            style: const TextStyle(
              color: AppColors.onGlass,
              fontWeight: FontWeight.w600,
              fontSize: 16,
            ),
          ),
          actions: [
            GlassIconButton(
              size: 36,
              icon: Icon(
                _muted ? Icons.notifications_off : Icons.notifications_active,
                color: AppColors.onGlass,
              ),
              onPressed: _toggleMute,
            ),
            const SizedBox(width: 6),
            GlassIconButton(
              size: 36,
              icon: const Icon(Icons.people_outline, color: AppColors.onGlass),
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
            const SizedBox(width: 8),
          ],
        ),
        body: Column(
          children: [
            if (!_connected)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                child: GlassProgressIndicator.linear(height: 2, minWidth: 60),
              ),
            if (_loadingOlder)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: GlassProgressIndicator.circular(size: 18),
              ),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
                itemCount: allItems.length,
                itemBuilder: (_, i) => _bubble(allItems[i], me),
              ),
            ),
            if (_peerTyping.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: GlassChip(
                    label: _peerTyping.length == 1
                        ? 'печатает…'
                        : '${_peerTyping.length} печатают…',
                    icon: const Icon(Icons.more_horiz, size: 14, color: AppColors.onGlassMuted),
                  ),
                ),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                child: GlassPanel(
                  padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      GlassIconButton(
                        size: 38,
                        icon: const Icon(Icons.image_outlined, color: AppColors.onGlass),
                        onPressed: _pickAndSendImage,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: GlassTextField(
                          controller: _ctrl,
                          placeholder: 'Сообщение…',
                          minLines: 1,
                          maxLines: 5,
                          textInputAction: TextInputAction.send,
                          onChanged: _onTextChanged,
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      const SizedBox(width: 6),
                      GlassIconButton(
                        size: 42,
                        icon: const Icon(Icons.send_rounded, color: AppColors.onGlass),
                        onPressed: _send,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _bubble(_Row r, String me) {
    final mine = r.userId == me;
    final maxW = MediaQuery.of(context).size.width * 0.75;
    final canEdit = r.kind == _RowKind.server && mine && !r.deleted;

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxW),
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: mine
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xCC6E6BFF), Color(0xCCB46CFF)],
              )
            : null,
        color: mine ? null : const Color(0x1FFFFFFF),
        border: Border.all(color: const Color(0x33FFFFFF), width: 0.5),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(mine ? 16 : 4),
          bottomRight: Radius.circular(mine ? 4 : 16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!mine && r.username.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                r.username,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onGlassMuted,
                ),
              ),
            ),
          if (r.attachmentUrl != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  r.attachmentUrl!,
                  width: 220,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.broken_image, color: AppColors.onGlassDim),
                ),
              ),
            ),
          if (r.deleted)
            const Text(
              'сообщение удалено',
              style: TextStyle(
                fontStyle: FontStyle.italic,
                color: AppColors.onGlassDim,
              ),
            )
          else if (r.text.isNotEmpty)
            Text(
              r.text,
              style: const TextStyle(color: AppColors.onGlass, height: 1.3),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (r.edited && !r.deleted)
                const Padding(
                  padding: EdgeInsets.only(top: 2, right: 6),
                  child: Text(
                    'изменено',
                    style: TextStyle(fontSize: 10, color: AppColors.onGlassDim),
                  ),
                ),
              if (mine)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    r.kind == _RowKind.pending
                        ? Icons.access_time
                        : Icons.done_all,
                    size: 12,
                    color: AppColors.onGlassDim,
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: canEdit ? () => _showMsgMenu(r.serverMsg!) : null,
        child: bubble,
      ),
    );
  }

  void _showMsgMenu(CachedMessage m) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GlassPanel(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (m.text.isNotEmpty)
                  GlassListTile.standalone(
                    leading: const Icon(Icons.edit_outlined, color: AppColors.onGlass),
                    title: const Text('Редактировать', style: TextStyle(color: AppColors.onGlass)),
                    onTap: () { Navigator.pop(ctx); _editMsg(m); },
                  ),
                GlassListTile.standalone(
                  leading: const Icon(Icons.delete_outline, color: AppColors.danger),
                  title: const Text('Удалить', style: TextStyle(color: AppColors.danger)),
                  onTap: () { Navigator.pop(ctx); _deleteMsg(m); },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _RowKind { server, pending }

class _Row {
  final _RowKind kind;
  final String userId;
  final String username;
  final String text;
  final int createdAt;
  final bool edited;
  final bool deleted;
  final String? attachmentUrl;
  final CachedMessage? serverMsg;

  _Row._({
    required this.kind,
    required this.userId,
    required this.username,
    required this.text,
    required this.createdAt,
    required this.edited,
    required this.deleted,
    required this.attachmentUrl,
    required this.serverMsg,
  });

  factory _Row.server(CachedMessage m) => _Row._(
        kind: _RowKind.server,
        userId: m.userId,
        username: m.username,
        text: m.text,
        createdAt: m.createdAt,
        edited: m.editedAt != null,
        deleted: m.deletedAt != null,
        attachmentUrl: m.attachment?.url,
        serverMsg: m,
      );

  factory _Row.pending(_Pending p, String userId, String username) => _Row._(
        kind: _RowKind.pending,
        userId: userId,
        username: username,
        text: p.text,
        createdAt: p.createdAt,
        edited: false,
        deleted: false,
        attachmentUrl: p.attachment?.url,
        serverMsg: null,
      );
}
