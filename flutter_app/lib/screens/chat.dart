import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../api.dart';
import '../config.dart';
import '../crypto/room_cipher.dart';
import '../services/media_picker.dart';
import '../state.dart';
import '../storage/cache.dart';
import '../storage/outbox.dart';
import '../theme/app_background.dart';
import '../theme/app_theme.dart';
import '../util/uuid.dart';
import 'chat/chat_input.dart';
import 'chat/chat_row.dart';
import 'chat/chat_transport.dart';
import 'chat/message_bubble.dart';
import 'members.dart';

const int _kHistoryPageSize = 50;
const int _kCatchupLimit = 200;

class ChatScreen extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;
  final bool isPublic;
  final bool muted;
  final bool e2e;
  final int keyVersion;
  const ChatScreen({
    super.key,
    required this.roomId,
    required this.roomName,
    this.isPublic = true,
    this.muted = false,
    this.e2e = false,
    this.keyVersion = 0,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  // ---- input + scroll ------------------------------------------------------
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scroll = ScrollController();

  // ---- transport (WS + send) ----------------------------------------------
  ChatTransport? _transport;
  bool _connected = false;

  // ---- lifecycle flag ------------------------------------------------------
  bool _disposed = false;

  // ---- local optimistic state ---------------------------------------------
  /// pending sends keyed by clientId. Bubble shows immediately; row is
  /// removed when the server echoes the message back with the same clientId.
  final Map<String, PendingMessage> _pending = {};

  // ---- read-state tracking ------------------------------------------------
  int _lastSeenAt = 0;
  int _lastReadSent = 0;

  // ---- pagination ----------------------------------------------------------
  bool _loadingOlder = false;
  bool _hasMoreOlder = true;

  // ---- typing indicators (peers we're seeing, not our own) ----------------
  final Map<String, Timer> _peerTyping = {};

  // ---- room state ----------------------------------------------------------
  bool _muted = false;
  String? _lastTailId;
  bool _didInitialScroll = false;

  // ---- ref-derived state, cached so dispose() / late callbacks don't touch
  // ref after the element is defunct (flutter_riverpod's ref.read checks
  // context.mounted and throws once the element is unmounted).
  late final StateController<String?> _currentRoomCtrl;
  String? _token;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _muted = widget.muted;
    _currentRoomCtrl = ref.read(currentRoomProvider.notifier);
    _token = ref.read(authProvider)?.token;

    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) _currentRoomCtrl.state = widget.roomId;
    });
    _hydrateAndConnect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _maybeMarkRead();
  }

  @override
  void dispose() {
    _disposed = true;
    // Снимаем флаг активной комнаты через закешированный controller — на
    // момент dispose Element уже defunct, и ref.read бросил бы StateError,
    // прерывая остаток cleanup.
    if (_currentRoomCtrl.state == widget.roomId) {
      _currentRoomCtrl.state = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _transport?.dispose();
    for (final t in _peerTyping.values) {
      t.cancel();
    }
    _inputCtrl.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Helpers — shared boilerplate
  // ---------------------------------------------------------------------------

  Api? get _api {
    final t = _token;
    return t == null ? null : Api(token: t);
  }

  /// Returns a RoomCipher for this room, or null when we're not in an E2E
  /// room / not authed. Constructed on demand — RoomCipher is stateless.
  RoomCipher? get _cipher {
    if (!widget.e2e) return null;
    final api = _api;
    return api == null
        ? null
        : RoomCipher(
            api: api,
            roomId: widget.roomId,
            fallbackVersion: widget.keyVersion,
          );
  }

  void _setStateIfMounted([VoidCallback? fn]) {
    if (!mounted) return;
    fn == null ? setState(() {}) : setState(fn);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // Hydration + initial connect
  // ---------------------------------------------------------------------------

  Future<void> _hydrateAndConnect() async {
    await _restorePendingFromOutbox();
    await _warmRoomKeyCache();
    _startTransport();
    unawaited(_runCatchupAndResend());
  }

  Future<void> _restorePendingFromOutbox() async {
    try {
      final saved = await Outbox.byRoom(widget.roomId);
      for (final s in saved) {
        _pending[s.clientId] = PendingMessage(
          clientId: s.clientId,
          text: s.text,
          createdAt: s.createdAt,
        );
      }
      if (saved.isNotEmpty) _setStateIfMounted();
    } catch (_) {/* кэш мог быть пустым */}
  }

  Future<void> _warmRoomKeyCache() async {
    final cipher = _cipher;
    if (cipher == null) return;
    try {
      await cipher.currentKey();
    } catch (_) {/* офлайн — повторим при первой расшифровке */}
  }

  // ---------------------------------------------------------------------------
  // Transport bootstrap
  // ---------------------------------------------------------------------------

  void _startTransport() {
    if (_disposed) return;
    final token = _token;
    if (token == null) return;
    _transport = ChatTransport(
      roomId: widget.roomId,
      token: token,
      wsBase: Config.wsBase,
      cipher: _cipher,
      onMessage: _onWsMessage,
      onEdit: _onWsEdit,
      onDelete: _onWsDelete,
      onTyping: _onWsTyping,
      onConnectedChanged: (c) => _setStateIfMounted(() => _connected = c),
      onUnauthorized: () => ref.read(authProvider.notifier).forceLogout(),
      onRateLimited: () => _toast('Слишком много сообщений, подожди немного'),
      onMissingRoomKey: () =>
          _toast('Не удалось получить ключ комнаты — отправка отложена'),
    )..start();
  }

  /// Backfill anything we missed while offline, then re-flush pending sends.
  /// Catchup is REST-driven so it doesn't need to wait for WS handshake.
  Future<void> _runCatchupAndResend() async {
    final api = _api;
    if (api != null && _lastSeenAt > 0) {
      try {
        final h = await api.history(
          widget.roomId,
          after: _lastSeenAt,
          limit: _kCatchupLimit,
        );
        if (h.isNotEmpty) {
          await MessagesCache.upsertAll(
              widget.roomId, h.cast<Map<String, dynamic>>());
        }
      } catch (_) {}
    }
    _resendPending();
  }

  // ---------------------------------------------------------------------------
  // WS event handlers
  // ---------------------------------------------------------------------------

  void _onWsMessage(Map<String, dynamic> m) {
    final clientId = m['client_id']?.toString();
    final createdAt = (m['created_at'] as num?)?.toInt() ?? 0;
    if (clientId != null && _pending.remove(clientId) != null) {
      Outbox.remove(clientId);
    }
    // For E2E rooms we want to flip the message to its decrypted form before
    // the cache notify fires, so the UI never shows the empty bubble.
    Future<void>.microtask(() async {
      await MessagesCache.upsert(widget.roomId, m);
      if (widget.e2e && m['ciphertext'] != null) {
        await _decryptIfNeeded(
          CachedMessage.fromRow({
            'id': m['id'],
            'room_id': widget.roomId,
            'client_id': m['client_id'],
            'user_id': m['user_id'] ?? '',
            'username': m['username'] ?? '',
            'text': '',
            'created_at': createdAt,
            'ciphertext': m['ciphertext'],
            'iv': m['iv'],
            'key_version': m['key_version'],
          }),
        );
      }
    });
    _lastSeenAt = max(_lastSeenAt, createdAt);
    _setStateIfMounted();
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
    _peerTyping[uid]?.cancel();
    if (m['is_typing'] != false) {
      _peerTyping[uid] = Timer(const Duration(seconds: 4), () {
        _peerTyping.remove(uid);
        _setStateIfMounted();
      });
    } else {
      _peerTyping.remove(uid);
    }
    _setStateIfMounted();
  }

  // ---------------------------------------------------------------------------
  // Send pipeline
  // ---------------------------------------------------------------------------

  void _send() {
    final t = _inputCtrl.text.trim();
    if (t.isEmpty) return;
    _sendCore(text: t);
  }

  void _sendCore({
    String text = '',
    String? attachmentId,
    CachedAttachment? attPreview,
  }) {
    final clientId = uuidV4();
    final createdAt = DateTime.now().millisecondsSinceEpoch;
    _pending[clientId] = PendingMessage(
      clientId: clientId,
      text: text,
      createdAt: createdAt,
      attachment: attPreview,
    );
    if (text.isNotEmpty) _inputCtrl.clear();
    setState(() {});
    _scrollToEnd();
    Outbox.add(
      clientId: clientId,
      roomId: widget.roomId,
      text: text,
      createdAt: createdAt,
    );
    _transport?.send(
        clientId: clientId, text: text, attachmentId: attachmentId);
  }

  void _resendPending() {
    final t = _transport;
    if (t == null) return;
    for (final p in _pending.values) {
      t.send(
          clientId: p.clientId, text: p.text, attachmentId: p.attachment?.id);
    }
  }

  void _onTextChanged(String _) => _transport?.notifyTyping();

  // ---------------------------------------------------------------------------
  // Image picking + upload
  // ---------------------------------------------------------------------------

  Future<void> _pickAndSendImage() async {
    final api = _api;
    if (api == null) return;
    final picker = MediaPicker(api);
    try {
      final media = widget.e2e
          ? await picker.pickAndUploadEncrypted(cipher: _cipher!)
          : await picker.pickAndUploadPlain();
      if (media == null) return;
      _sendCore(attachmentId: media.attachmentId, attPreview: media.preview);
    } on UnsupportedMediaFormat {
      _toast('Неподдерживаемый формат');
    } on RoomKeyUnavailable {
      _toast('Нет ключа комнаты — загрузка невозможна');
    } catch (e) {
      _toast('$e');
    }
  }

  // ---------------------------------------------------------------------------
  // Edit / delete
  // ---------------------------------------------------------------------------

  Future<void> _editMsg(CachedMessage m) async {
    final api = _api;
    if (api == null) return;
    final newText = await _promptEdit(m.text);
    if (newText == null || newText == m.text) return;
    try {
      if (widget.e2e) {
        final enc = await _cipher!.encryptMessage(newText);
        await api.editMessage(
          widget.roomId,
          m.id,
          '',
          ciphertext: enc.cipher.ctB64,
          iv: enc.cipher.ivB64,
          keyVersion: enc.keyVersion,
        );
      } else {
        await api.editMessage(widget.roomId, m.id, newText);
      }
      // Keep local plaintext fresh so the bubble updates immediately.
      await MessagesCache.applyEdit(
        widget.roomId,
        m.id,
        newText,
        DateTime.now().millisecondsSinceEpoch,
      );
    } on RoomKeyUnavailable {
      _toast('нет ключа комнаты');
    } catch (e) {
      _toast('$e');
    }
  }

  Future<String?> _promptEdit(String initial) async {
    final ctrl = TextEditingController(text: initial);
    final ok = await GlassDialog.show<bool>(
      context: context,
      title: 'Редактировать',
      content: GlassTextField(
        controller: ctrl,
        autofocus: true,
        maxLines: 4,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      actions: [
        GlassDialogAction(
            label: 'Отмена',
            onPressed: () => Navigator.pop(context, false)),
        GlassDialogAction(
            label: 'Сохранить',
            isPrimary: true,
            onPressed: () => Navigator.pop(context, true)),
      ],
    );
    if (ok != true) return null;
    final text = ctrl.text.trim();
    return text.isEmpty ? null : text;
  }

  Future<void> _deleteMsg(CachedMessage m) async {
    final api = _api;
    if (api == null) return;
    final ok = await GlassDialog.show<bool>(
      context: context,
      title: 'Удалить сообщение?',
      actions: [
        GlassDialogAction(
            label: 'Отмена',
            onPressed: () => Navigator.pop(context, false)),
        GlassDialogAction(
            label: 'Удалить',
            isDestructive: true,
            onPressed: () => Navigator.pop(context, true)),
      ],
    );
    if (ok != true) return;
    try {
      await api.deleteMessage(widget.roomId, m.id);
      await MessagesCache.applyDelete(
          widget.roomId, m.id, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      _toast('$e');
    }
  }

  // ---------------------------------------------------------------------------
  // Read state + mute
  // ---------------------------------------------------------------------------

  Future<void> _maybeMarkRead() async {
    if (_disposed) return;
    if (_lastSeenAt <= _lastReadSent) return;
    final api = _api;
    if (api == null) return;
    final ts = _lastSeenAt;
    _lastReadSent = ts;
    try {
      await api.markRead(widget.roomId, ts);
      await RoomsCache.setUnread(widget.roomId, 0);
    } catch (_) {}
  }

  Future<void> _toggleMute() async {
    final api = _api;
    if (api == null) return;
    final next = !_muted;
    setState(() => _muted = next);
    await RoomsCache.setMuted(widget.roomId, next);
    try {
      await api.setMuted(widget.roomId, next);
    } catch (_) {
      if (!mounted) return;
      setState(() => _muted = !next);
      await RoomsCache.setMuted(widget.roomId, !next);
    }
  }

  // ---------------------------------------------------------------------------
  // History pagination + decrypt
  // ---------------------------------------------------------------------------

  void _onScroll() {
    if (!_scroll.position.hasContentDimensions) return;
    final distanceFromOldest =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (distanceFromOldest <= 80 && !_loadingOlder && _hasMoreOlder) {
      _loadOlder();
    }
  }

  Future<void> _loadOlder() async {
    final api = _api;
    if (api == null) return;
    final cached = await MessagesCache.snapshot(widget.roomId);
    if (cached.isEmpty) {
      _hasMoreOlder = false;
      return;
    }
    _loadingOlder = true;
    _setStateIfMounted();
    try {
      final h = await api.history(widget.roomId,
          before: cached.first.createdAt, limit: _kHistoryPageSize);
      if (h.isEmpty) {
        _hasMoreOlder = false;
        return;
      }
      await MessagesCache.upsertAll(
          widget.roomId, h.cast<Map<String, dynamic>>());
      if (h.length < _kHistoryPageSize) _hasMoreOlder = false;
      // reverse: true ListView — newer items pinned to offset 0 (bottom);
      // prepending older rows extends maxScrollExtent upward, so the user's
      // current pixels value still anchors the same visible content.
    } catch (_) {/* тихо — в следующий раз */} finally {
      _loadingOlder = false;
      _setStateIfMounted();
    }
  }

  Future<void> _decryptIfNeeded(CachedMessage m) async {
    if (_disposed) return;
    if (!widget.e2e || !m.isE2e || m.text.isNotEmpty || m.deletedAt != null) {
      return;
    }
    final cipher = _cipher;
    if (cipher == null) return;
    final plaintext = await cipher.decryptMessage(
      keyVersion: m.keyVersion ?? widget.keyVersion,
      iv: Uint8List.fromList(base64Decode(m.iv!)),
      ciphertext: Uint8List.fromList(base64Decode(m.ciphertext!)),
    );
    if (plaintext == null) return; // wrong key version / not yet available
    await MessagesCache.setDecryptedText(widget.roomId, m.id, plaintext);
  }

  // ---------------------------------------------------------------------------
  // Scroll helpers
  // ---------------------------------------------------------------------------

  void _scrollToEnd({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      // reverse: true — offset 0 is the newest message at the bottom.
      if (animate) {
        _scroll.animateTo(0,
            duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
      } else {
        _scroll.jumpTo(0);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authProvider)?.userId ?? '';
    final myUsername = ref.watch(authProvider)?.username ?? '';
    final cachedAsync = ref.watch(messagesProvider(widget.roomId));
    final cached = cachedAsync.valueOrNull ?? const <CachedMessage>[];

    _wireMessageListener();
    _maybeInitialScroll(cached);

    final rows = _buildRows(cached, me, myUsername);

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
          appBar: _appBar(),
          body: Column(
            children: [
              if (!_connected)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                  child:
                      GlassProgressIndicator.linear(height: 2, minWidth: 60),
                ),
              if (_loadingOlder)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: GlassProgressIndicator.circular(size: 18),
                ),
              Expanded(child: _messageList(rows, me)),
              TypingChip(peerCount: _peerTyping.length),
              ChatInputBar(
                controller: _inputCtrl,
                onChanged: _onTextChanged,
                onSend: _send,
                onPickImage: _pickAndSendImage,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Subscribes (idempotently per-build) to the room's message stream so we
  /// can react to new tails outside of build() — autoscroll, mark-read, and
  /// lazy decryption of ciphertext-only rows surfaced by REST history.
  void _wireMessageListener() {
    ref.listen<AsyncValue<List<CachedMessage>>>(
      messagesProvider(widget.roomId),
      (prev, next) {
        if (_disposed) return;
        final list = next.valueOrNull;
        if (list == null || list.isEmpty) return;
        _lastSeenAt = max(_lastSeenAt, list.last.createdAt);
        if (list.last.id != _lastTailId) {
          _lastTailId = list.last.id;
          _scrollToEnd();
          _maybeMarkRead();
        }
        if (widget.e2e) {
          for (final m in list) {
            if (m.isE2e && m.text.isEmpty && m.deletedAt == null) {
              unawaited(_decryptIfNeeded(m));
            }
          }
        }
      },
    );
  }

  void _maybeInitialScroll(List<CachedMessage> cached) {
    if (_didInitialScroll || cached.isEmpty) return;
    _didInitialScroll = true;
    _lastTailId = cached.last.id;
    _lastSeenAt = max(_lastSeenAt, cached.last.createdAt);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToEnd(animate: false);
      _maybeMarkRead();
    });
  }

  List<ChatRow> _buildRows(
    List<CachedMessage> cached,
    String me,
    String myUsername,
  ) {
    final items = <ChatRow>[
      for (final m in cached) ChatRow.server(m),
      for (final p in _pending.values) ChatRow.pending(p, me, myUsername),
    ];
    items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return items;
  }

  GlassAppBar _appBar() => GlassAppBar(
        leading: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: GlassIconButton(
            size: 36,
            icon: const Icon(Icons.arrow_back_ios_new,
                color: AppColors.onGlass, size: 18),
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
            onPressed: _openMembers,
          ),
          const SizedBox(width: 8),
        ],
      );

  void _openMembers() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MembersScreen(
          roomId: widget.roomId,
          roomName: widget.roomName,
          isPublic: widget.isPublic,
          e2e: widget.e2e,
          keyVersion: widget.keyVersion,
        ),
      ),
    );
  }

  Widget _messageList(List<ChatRow> rows, String me) => ListView.builder(
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        itemCount: rows.length,
        itemBuilder: (_, i) {
          final r = rows[rows.length - 1 - i];
          final mine = r.userId == me;
          return MessageBubble(
            row: r,
            mine: mine,
            roomId: widget.roomId,
            e2e: widget.e2e,
            token: _token ?? '',
            onLongPress: (r.kind == ChatRowKind.server && mine && !r.deleted)
                ? () => _showMsgMenu(r.serverMsg!)
                : null,
          );
        },
      );

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
                    leading:
                        const Icon(Icons.edit_outlined, color: AppColors.onGlass),
                    title: const Text('Редактировать',
                        style: TextStyle(color: AppColors.onGlass)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _editMsg(m);
                    },
                  ),
                GlassListTile.standalone(
                  leading: const Icon(Icons.delete_outline,
                      color: AppColors.danger),
                  title: const Text('Удалить',
                      style: TextStyle(color: AppColors.danger)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _deleteMsg(m);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
