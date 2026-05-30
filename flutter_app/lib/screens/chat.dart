import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../api.dart';
import '../config.dart';
import '../crypto/mention_tags.dart';
import '../crypto/room_cipher.dart';
import '../services/media_picker.dart';
import '../state.dart';
import '../storage/cache.dart';
import '../storage/outbox.dart';
import '../theme/app_background.dart';
import '../theme/app_theme.dart';
import '../util/e2e_envelope.dart';
import '../util/uuid.dart';
import 'chat/chat_input.dart';
import 'chat/chat_row.dart';
import 'chat/chat_transport.dart';
import 'chat/message_bubble.dart';
import 'members.dart';

/// F2: the reaction emoji bar shown in the long-press menu.
const List<String> _kReactionEmojis = ['👍', '❤️', '😂', '🔥', '😮', '😢'];

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

  // ---- F1 reply target -----------------------------------------------------
  CachedMessage? _replyTarget;

  // ---- F4 unread divider ---------------------------------------------------
  /// Set once on open: id of the first unread message, used to anchor the
  /// "unread" divider even after we mark messages read.
  bool _capturedOpenRead = false;
  String? _firstUnreadId;

  // ---- F7 drafts -----------------------------------------------------------
  Timer? _draftDebounce;
  bool _draftRestored = false;

  // ---- F11 voice -----------------------------------------------------------
  final VoiceRecorder _recorder = VoiceRecorder();
  bool _recording = false;
  Duration _recordElapsed = Duration.zero;
  Timer? _recordTimer;

  // ---- latest cached snapshot (for quote lookup + scroll-to) ---------------
  List<CachedMessage> _lastList = const [];

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
    _selfId = ref.read(authProvider)?.userId;

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
    // прерывая остаток cleanup. Саму запись откладываем в microtask:
    // dispose часто вызывается из BuildOwner.finalizeTree, а Riverpod
    // запрещает мутировать provider в фазе build.
    final ctrl = _currentRoomCtrl;
    final roomId = widget.roomId;
    scheduleMicrotask(() {
      if (ctrl.state == roomId) ctrl.state = null;
    });
    // F7: flush the latest composer state to the draft cache on the way out.
    _persistDraftNow();
    _draftDebounce?.cancel();
    _recordTimer?.cancel();
    unawaited(_recorder.dispose());
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

  /// Synchronously kick off a draft write using the controller's current value.
  /// Safe to call from dispose (uses the cached room id, no ref access).
  void _persistDraftNow() {
    final text = _inputCtrl.text;
    final replyId = _replyTarget?.id;
    if (text.isEmpty && replyId == null) {
      unawaited(DraftsCache.clear(widget.roomId));
    } else {
      unawaited(DraftsCache.set(widget.roomId, text, replyToId: replyId));
    }
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
    await _restoreDraft();
    await _warmRoomKeyCache();
    _publishMentionTagIfE2e();
    _startTransport();
    unawaited(_runCatchupAndResend());
  }

  /// F7: restore the saved composer text + reply target for this room.
  Future<void> _restoreDraft() async {
    if (_draftRestored) return;
    _draftRestored = true;
    try {
      final draft = await DraftsCache.get(widget.roomId);
      if (draft == null) return;
      if (draft.text.isNotEmpty) _inputCtrl.text = draft.text;
      if (draft.replyToId != null) {
        // Resolve against whatever we have cached; if not present yet the
        // reply strip simply won't show a snippet until the message loads.
        final list = await MessagesCache.snapshot(widget.roomId);
        final found = _findById(list, draft.replyToId!);
        if (found != null) _replyTarget = found;
      }
      _setStateIfMounted();
    } catch (_) {/* no draft / cache miss */}
  }

  /// F3: publish our own keyed mention tag once on entering an E2E room so
  /// other members can @-mention us. Best-effort — silent on failure.
  void _publishMentionTagIfE2e() {
    if (!widget.e2e) return;
    final api = _api;
    final selfId = _selfId;
    if (api == null || selfId == null) return;
    unawaited(() async {
      try {
        await MentionTags.publishOwnTag(
          api,
          widget.roomId,
          selfId,
          fallbackKeyVersion: widget.keyVersion,
        );
      } catch (_) {}
    }());
  }

  String? _selfId;

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
      onReaction: _onWsReaction,
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

  /// F2: incoming Room-DO reaction frame. `mine` is true when the actor is us.
  void _onWsReaction(Map<String, dynamic> m) {
    final msgId = m['message_id']?.toString();
    final emoji = m['emoji']?.toString();
    final userId = m['user_id']?.toString() ?? '';
    if (msgId == null || emoji == null || emoji.isEmpty) return;
    final mine = userId == _selfId;
    if (m['type'] == 'reaction_remove') {
      MessagesCache.applyReactionRemove(widget.roomId, msgId, userId, emoji,
          mine: mine);
    } else {
      MessagesCache.applyReactionAdd(widget.roomId, msgId, userId, emoji,
          mine: mine);
    }
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
    unawaited(_sendText(t));
  }

  /// Text send path: resolves @mentions and threads any active reply target
  /// before handing off to [_sendCore].
  Future<void> _sendText(String text) async {
    final replyId = _replyTarget?.id;
    final mentions = await _resolveMentions(text);
    _sendCore(
      text: text,
      replyToId: replyId,
      mentions: mentions,
    );
  }

  /// F3: extract `@username` tokens, map them to member user_ids, and (for E2E
  /// rooms) convert those ids to keyed mention tags. Returns the payload list
  /// to put in the frame, or null when nothing resolves.
  Future<List<String>?> _resolveMentions(String text) async {
    final names = _mentionRe
        .allMatches(text)
        .map((m) => m.group(1)!.toLowerCase())
        .toSet();
    if (names.isEmpty) return null;
    final members = await MembersCache.snapshot(widget.roomId);
    final ids = <String>[];
    for (final m in members) {
      if (names.contains(m.username.toLowerCase())) ids.add(m.userId);
    }
    if (ids.isEmpty) return null;
    if (!widget.e2e) return ids;
    // E2E: substitute keyed tags for the user_ids. Skip silently if the room
    // key isn't available.
    final api = _api;
    if (api == null) return null;
    try {
      final tags = await MentionTags.tagsForRoom(
        api,
        widget.roomId,
        ids,
        fallbackKeyVersion: widget.keyVersion,
      );
      if (tags == null) return null;
      return ids.map((id) => tags[id]).whereType<String>().toList();
    } catch (_) {
      return null;
    }
  }

  static final RegExp _mentionRe = RegExp(r'@([A-Za-z0-9_]+)');

  void _sendCore({
    String text = '',
    String? attachmentId,
    CachedAttachment? attPreview,
    String? replyToId,
    List<String>? mentions,
  }) {
    final clientId = uuidV4();
    final createdAt = DateTime.now().millisecondsSinceEpoch;
    _pending[clientId] = PendingMessage(
      clientId: clientId,
      text: text,
      createdAt: createdAt,
      attachment: attPreview,
      replyToId: replyToId,
    );
    if (text.isNotEmpty) _inputCtrl.clear();
    // Clear the reply target + draft once the send is committed.
    _replyTarget = null;
    unawaited(DraftsCache.clear(widget.roomId));
    setState(() {});
    _scrollToEnd();
    Outbox.add(
      clientId: clientId,
      roomId: widget.roomId,
      text: text,
      createdAt: createdAt,
    );
    _transport?.send(
      clientId: clientId,
      text: text,
      attachmentId: attachmentId,
      replyToId: replyToId,
      mentions: mentions,
      // Plain rooms already persisted these server-side via reserveUpload;
      // the transport ignores them. E2E rooms get them wrapped into the
      // encrypted plaintext envelope so receivers see the placeholder/duration
      // without leaking metadata to the server.
      attachmentBlurhash: attPreview?.blurhash,
      attachmentDurationMs: attPreview?.durationMs,
    );
  }

  void _resendPending() {
    final t = _transport;
    if (t == null) return;
    for (final p in _pending.values) {
      t.send(
        clientId: p.clientId,
        text: p.text,
        attachmentId: p.attachment?.id,
        replyToId: p.replyToId,
        attachmentBlurhash: p.attachment?.blurhash,
        attachmentDurationMs: p.attachment?.durationMs,
      );
    }
  }

  void _onTextChanged(String _) {
    _transport?.notifyTyping();
    // F7: debounce draft persistence so we don't hammer SQLite per keystroke.
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 600), _persistDraftNow);
  }

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
  // F11 voice messages
  // ---------------------------------------------------------------------------

  Future<void> _startRecording() async {
    if (_recording) return;
    final ok = await _recorder.start();
    if (!ok) {
      _toast('Нет доступа к микрофону');
      return;
    }
    final started = DateTime.now();
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _setStateIfMounted(
          () => _recordElapsed = DateTime.now().difference(started));
    });
    _setStateIfMounted(() {
      _recording = true;
      _recordElapsed = Duration.zero;
    });
  }

  Future<void> _cancelRecording() async {
    _recordTimer?.cancel();
    await _recorder.cancel();
    _setStateIfMounted(() {
      _recording = false;
      _recordElapsed = Duration.zero;
    });
  }

  Future<void> _stopAndSendRecording() async {
    _recordTimer?.cancel();
    final wasRecording = _recording;
    _setStateIfMounted(() => _recording = false);
    if (!wasRecording) return;
    final clip = await _recorder.stop();
    if (clip == null) return;
    final api = _api;
    if (api == null) return;
    final picker = MediaPicker(api);
    try {
      final media = widget.e2e
          ? await picker.uploadVoiceEncrypted(
              clip.bytes,
              cipher: _cipher!,
              durationMs: clip.durationMs,
            )
          : await picker.uploadVoicePlain(
              clip.bytes,
              durationMs: clip.durationMs,
            );
      _sendCore(attachmentId: media.attachmentId, attPreview: media.preview);
    } on RoomKeyUnavailable {
      _toast('Нет ключа комнаты — отправка голосового невозможна');
    } catch (e) {
      _toast('$e');
    } finally {
      _setStateIfMounted(() => _recordElapsed = Duration.zero);
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
  // F18 forward
  // ---------------------------------------------------------------------------

  Future<void> _forwardMsg(CachedMessage m) async {
    final api = _api;
    if (api == null) return;
    final rooms = await RoomsCache.snapshot();
    // Only rooms we're a member of, excluding the current one.
    final targets = rooms
        .where((r) => r.isMember && r.id != widget.roomId)
        .toList(growable: false);
    if (!mounted) return;
    if (targets.isEmpty) {
      _toast('Нет комнат для пересылки');
      return;
    }
    final target = await _pickForwardTarget(targets);
    if (target == null) return;
    await _doForward(api, m, target);
  }

  Future<CachedRoom?> _pickForwardTarget(List<CachedRoom> rooms) {
    return showModalBottomSheet<CachedRoom>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GlassPanel(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Text('Переслать в…',
                      style: TextStyle(
                          color: AppColors.onGlass,
                          fontWeight: FontWeight.w700)),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final r in rooms)
                        GlassListTile.standalone(
                          leading: Icon(
                            r.e2e ? Icons.lock_outline : Icons.tag,
                            color: AppColors.onGlass,
                          ),
                          title: Text(r.name,
                              style:
                                  const TextStyle(color: AppColors.onGlass)),
                          onTap: () => Navigator.pop(ctx, r),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _doForward(
      Api api, CachedMessage m, CachedRoom target) async {
    final clientId = uuidV4();
    final hasAttachment = m.attachment != null;
    try {
      if (target.e2e) {
        // Re-encrypt under the TARGET room key. We have plaintext for shown
        // E2E messages (and for plain sources). Attachments can't be
        // re-uploaded yet — forward text only.
        if (hasAttachment && m.text.isEmpty) {
          _toast('Вложения пока нельзя пересылать в зашифрованные чаты');
          return;
        }
        if (hasAttachment) {
          _toast('Вложение не будет переслано в зашифрованный чат');
        }
        final targetCipher = RoomCipher(
          api: api,
          roomId: target.id,
          fallbackVersion: target.keyVersion,
        );
        final enc = await targetCipher.encryptMessage(m.text);
        await api.forwardMessage(
          target.id,
          clientId: clientId,
          sourceRoomId: widget.roomId,
          sourceMsgId: m.id,
          ciphertext: enc.cipher.ctB64,
          iv: enc.cipher.ivB64,
          keyVersion: enc.keyVersion,
        );
      } else {
        // Plaintext target. Pass text through; plain->plain may forward the
        // attachment id as well.
        await api.forwardMessage(
          target.id,
          clientId: clientId,
          sourceRoomId: widget.roomId,
          sourceMsgId: m.id,
          text: m.text.isEmpty ? null : m.text,
          attachmentId:
              (!widget.e2e && hasAttachment) ? m.attachment!.id : null,
        );
      }
      _toast('Переслано в ${target.name}');
    } on RoomKeyUnavailable {
      _toast('Нет ключа комнаты назначения');
    } catch (e) {
      _toast('$e');
    }
  }

  // ---------------------------------------------------------------------------
  // F1 reply helpers
  // ---------------------------------------------------------------------------

  void _setReplyTarget(CachedMessage m) {
    _setStateIfMounted(() => _replyTarget = m);
    _persistDraftNow();
  }

  void _clearReply() {
    _setStateIfMounted(() => _replyTarget = null);
    _persistDraftNow();
  }

  ReplyPreview? _replyPreview() {
    final m = _replyTarget;
    if (m == null) return null;
    final snippet = m.deletedAt != null
        ? 'сообщение удалено'
        : (m.text.isNotEmpty
            ? m.text
            : (m.attachment != null ? 'вложение' : '…'));
    return ReplyPreview(
      sender: m.username.isNotEmpty ? m.username : 'сообщение',
      snippet: snippet,
    );
  }

  CachedMessage? _findById(List<CachedMessage> list, String id) {
    for (final m in list) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Scroll the list so the source message of a quote becomes visible. The
  /// list is `reverse: true`, so we translate the message index into a scroll
  /// offset estimate; close enough for a "jump near it" behaviour.
  void _scrollToMessage(String id) {
    final idx = _lastList.indexWhere((m) => m.id == id);
    if (idx < 0 || !_scroll.hasClients) return;
    // reverse list: newest at offset 0. Items after [idx] sit "below" it.
    final fromEnd = _lastList.length - 1 - idx;
    final target = (fromEnd * 64.0).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  // ---------------------------------------------------------------------------
  // F2 reactions
  // ---------------------------------------------------------------------------

  Future<void> _toggleReaction(CachedMessage m, String emoji) async {
    final api = _api;
    if (api == null) return;
    final selfId = _selfId ?? '';
    final existing =
        m.reactions.where((r) => r.emoji == emoji).cast<MessageReaction?>();
    final mineNow = existing.isNotEmpty && (existing.first?.mine ?? false);
    try {
      if (mineNow) {
        await MessagesCache.applyReactionRemove(
            widget.roomId, m.id, selfId, emoji, mine: true);
        await api.removeReaction(widget.roomId, m.id, emoji);
      } else {
        await MessagesCache.applyReactionAdd(
            widget.roomId, m.id, selfId, emoji, mine: true);
        await api.addReaction(widget.roomId, m.id, emoji);
      }
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
    final env = decodeE2eEnvelope(plaintext);
    await MessagesCache.setDecryptedMessage(
      widget.roomId,
      m.id,
      env.text,
      blurhash: env.blurhash,
      durationMs: env.durationMs,
    );
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
    _lastList = cached;

    _wireMessageListener();
    _maybeInitialScroll(cached);
    _captureOpenRead();

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
                Container(
                  height: 2,
                  margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Color(0x00FFFFFF),
                        Color(0x66FFFFFF),
                        Color(0x00FFFFFF),
                      ],
                    ),
                  ),
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
                replyPreview: _replyPreview(),
                onCancelReply: _clearReply,
                onStartRecording: _startRecording,
                onStopRecording: _stopAndSendRecording,
                onCancelRecording: _cancelRecording,
                recording: _recording,
                recordElapsed: _recordElapsed,
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

  /// F4: snapshot the room's unread count once (on first build with data) so
  /// we can anchor an "unread" divider at the first unread message. Marking
  /// messages read afterwards won't move the divider.
  void _captureOpenRead() {
    if (_capturedOpenRead || _lastList.isEmpty) return;
    _capturedOpenRead = true;
    unawaited(() async {
      try {
        final rooms = await RoomsCache.snapshot();
        final room = rooms.where((r) => r.id == widget.roomId);
        final unread = room.isEmpty ? 0 : room.first.unread;
        if (unread <= 0) return;
        final list = _lastList;
        final firstId = unread >= list.length
            ? list.first.id
            : list[list.length - unread].id;
        _setStateIfMounted(() => _firstUnreadId = firstId);
      } catch (_) {}
    }());
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
            fontWeight: FontWeight.w700,
            fontSize: 18,
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
          final isServer = r.kind == ChatRowKind.server;
          final bubble = MessageBubble(
            row: r,
            mine: mine,
            roomId: widget.roomId,
            e2e: widget.e2e,
            token: _token ?? '',
            onLongPress:
                (isServer && !r.deleted) ? () => _showMsgMenu(r.serverMsg!) : null,
            onReply: (isServer && !r.deleted)
                ? () => _setReplyTarget(r.serverMsg!)
                : null,
            resolveQuoted: (id) => _findById(_lastList, id),
            onTapQuote: _scrollToMessage,
            onToggleReaction: (isServer && !r.deleted)
                ? (emoji) => _toggleReaction(r.serverMsg!, emoji)
                : null,
          );
          // F4: unread divider sits just above the first unread message.
          if (isServer && r.messageId == _firstUnreadId) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [_unreadDivider(), bubble],
            );
          }
          return bubble;
        },
      );

  Widget _unreadDivider() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: Divider(color: Color(0x33FFFFFF), height: 1)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'непрочитанные',
                style: TextStyle(fontSize: 11, color: AppColors.onGlassMuted),
              ),
            ),
            Expanded(child: Divider(color: Color(0x33FFFFFF), height: 1)),
          ],
        ),
      );

  void _showMsgMenu(CachedMessage m) {
    final mine = m.userId == (_selfId ?? '');
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
                // F2: quick-reaction emoji bar.
                _reactionBar(ctx, m),
                const Divider(color: Color(0x22FFFFFF), height: 1),
                // F1: reply.
                GlassListTile.standalone(
                  leading: const Icon(Icons.reply, color: AppColors.onGlass),
                  title: const Text('Ответить',
                      style: TextStyle(color: AppColors.onGlass)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _setReplyTarget(m);
                  },
                ),
                // F18: forward.
                GlassListTile.standalone(
                  leading:
                      const Icon(Icons.forward, color: AppColors.onGlass),
                  title: const Text('Переслать',
                      style: TextStyle(color: AppColors.onGlass)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _forwardMsg(m);
                  },
                ),
                if (mine && m.text.isNotEmpty)
                  GlassListTile.standalone(
                    leading: const Icon(Icons.edit_outlined,
                        color: AppColors.onGlass),
                    title: const Text('Редактировать',
                        style: TextStyle(color: AppColors.onGlass)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _editMsg(m);
                    },
                  ),
                if (mine)
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

  Widget _reactionBar(BuildContext ctx, CachedMessage m) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            for (final emoji in _kReactionEmojis)
              GestureDetector(
                onTap: () {
                  Navigator.pop(ctx);
                  _toggleReaction(m, emoji);
                },
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text(emoji, style: const TextStyle(fontSize: 24)),
                ),
              ),
          ],
        ),
      );
}
