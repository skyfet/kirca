import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../api.dart';
import '../../config.dart';
import '../../crypto/room_cipher.dart';
import '../../storage/cache.dart';
import '../../theme/app_theme.dart';
import '../../util/uuid.dart';
import 'attachment_image.dart';
import 'chat_row.dart';

/// One message bubble. Pure rendering — selection / actions are wired by the
/// parent through callbacks. The bubble itself never reads providers.
class MessageBubble extends StatefulWidget {
  final ChatRow row;
  final bool mine;
  final String roomId;
  final bool e2e;
  final String token;
  final VoidCallback? onLongPress;

  /// F1: swipe-right to set this message as the reply target.
  final VoidCallback? onReply;

  /// F1: resolves a [ChatRow.replyToId] to the quoted message in the current
  /// cached list (null when it's gone / not loaded).
  final CachedMessage? Function(String id)? resolveQuoted;

  /// F1: tap the quoted snippet to scroll to the source message.
  final void Function(String sourceId)? onTapQuote;

  /// F2: tap an existing reaction chip to toggle your reaction.
  final void Function(String emoji)? onToggleReaction;

  const MessageBubble({
    super.key,
    required this.row,
    required this.mine,
    required this.roomId,
    required this.e2e,
    required this.token,
    this.onLongPress,
    this.onReply,
    this.resolveQuoted,
    this.onTapQuote,
    this.onToggleReaction,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  double _dragDx = 0;

  bool get _isVoice {
    final att = widget.row.attachment;
    return att != null && att.mime.startsWith('audio/');
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final mine = widget.mine;
    final maxW = MediaQuery.of(context).size.width * 0.75;

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxW),
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: _decoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!mine && row.username.isNotEmpty) _authorLine(),
          if (row.isForwarded) _forwardedLine(),
          if (row.replyToId != null) _quote(context),
          if (row.attachment != null) _attachment(),
          if (row.deleted)
            const _DeletedNotice()
          else if (row.text.isNotEmpty)
            _body(),
          _footer(),
        ],
      ),
    );

    final column = Column(
      crossAxisAlignment:
          mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        bubble,
        if (row.reactions.isNotEmpty) _reactionChips(),
      ],
    );

    // F1: swipe-right (a small drag) sets the reply target. We translate the
    // bubble slightly during the drag for feedback, then snap back.
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: widget.onLongPress,
        onHorizontalDragUpdate: widget.onReply == null
            ? null
            : (d) {
                setState(() {
                  _dragDx = (_dragDx + d.delta.dx).clamp(0.0, 72.0);
                });
              },
        onHorizontalDragEnd: widget.onReply == null
            ? null
            : (_) {
                if (_dragDx > 48) widget.onReply!.call();
                setState(() => _dragDx = 0);
              },
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            if (_dragDx > 8)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Opacity(
                  opacity: (_dragDx / 72).clamp(0.0, 1.0),
                  child: const Icon(Icons.reply,
                      size: 20, color: AppColors.onGlassMuted),
                ),
              ),
            Transform.translate(
              offset: Offset(_dragDx, 0),
              child: column,
            ),
          ],
        ),
      ),
    );
  }

  BoxDecoration _decoration() => BoxDecoration(
        gradient: widget.mine
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xCC6E6BFF), Color(0xCCB46CFF)],
              )
            : null,
        color: widget.mine ? null : const Color(0x1FFFFFFF),
        border: Border.all(color: const Color(0x33FFFFFF), width: 0.5),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(widget.mine ? 16 : 4),
          bottomRight: Radius.circular(widget.mine ? 4 : 16),
        ),
      );

  Widget _authorLine() => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(
          widget.row.username,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.onGlassMuted,
          ),
        ),
      );

  Widget _forwardedLine() {
    final from = widget.row.forwardedFromUsername;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.forward, size: 12, color: AppColors.onGlassDim),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              from == null ? 'переслано' : 'переслано от $from',
              style: const TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: AppColors.onGlassDim,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- F1 quote -------------------------------------------------------------

  Widget _quote(BuildContext context) {
    final id = widget.row.replyToId!;
    final quoted = widget.resolveQuoted?.call(id);
    final unavailable = quoted == null;
    final deleted = quoted?.deletedAt != null;
    final String sender = unavailable
        ? ''
        : (quoted.username.isNotEmpty ? quoted.username : '');
    final String snippet = unavailable
        ? 'сообщение недоступно'
        : deleted
            ? 'сообщение удалено'
            : (quoted.text.isNotEmpty
                ? quoted.text
                : (quoted.attachment != null ? 'вложение' : '…'));

    return GestureDetector(
      onTap: (!unavailable && widget.onTapQuote != null)
          ? () => widget.onTapQuote!.call(id)
          : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        decoration: const BoxDecoration(
          color: Color(0x22000000),
          border: Border(
            left: BorderSide(color: AppColors.accent, width: 2.5),
          ),
          borderRadius: BorderRadius.all(Radius.circular(6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (sender.isNotEmpty)
              Text(
                sender,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onGlassMuted,
                ),
              ),
            Text(
              snippet,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontStyle: unavailable || deleted
                    ? FontStyle.italic
                    : FontStyle.normal,
                color: AppColors.onGlassDim,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- attachment / voice ---------------------------------------------------

  Widget _attachment() {
    if (_isVoice) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: VoicePlayer(
          attachment: widget.row.attachment!,
          e2e: widget.e2e,
          roomId: widget.roomId,
          token: widget.token,
          mine: widget.mine,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AttachmentImage(
          attachment: widget.row.attachment!,
          e2e: widget.e2e,
          roomId: widget.roomId,
          token: widget.token,
        ),
      ),
    );
  }

  // ---- F3 mentions highlight ------------------------------------------------

  static final RegExp _mentionRe = RegExp(r'(@[A-Za-z0-9_]+)');

  Widget _body() {
    final text = widget.row.text;
    if (!text.contains('@')) {
      return Text(text, style: _textStyle);
    }
    final spans = <TextSpan>[];
    int last = 0;
    for (final m in _mentionRe.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      spans.add(TextSpan(
        text: m.group(0),
        style: const TextStyle(
          color: AppColors.accent,
          fontWeight: FontWeight.w700,
        ),
      ));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }
    return Text.rich(TextSpan(style: _textStyle, children: spans));
  }

  static const TextStyle _textStyle = TextStyle(
    color: AppColors.onGlass,
    fontSize: 14,
    height: 1.3,
  );

  // ---- F2 reaction chips ----------------------------------------------------

  Widget _reactionChips() => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 2),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final r in widget.row.reactions)
              GestureDetector(
                onTap: widget.onToggleReaction == null
                    ? null
                    : () => widget.onToggleReaction!.call(r.emoji),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: r.mine
                        ? const Color(0x553B82F6)
                        : const Color(0x1FFFFFFF),
                    border: Border.all(
                      color: r.mine
                          ? AppColors.accent
                          : const Color(0x33FFFFFF),
                      width: 0.6,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${r.emoji} ${r.count}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.onGlass,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _footer() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.row.edited && !widget.row.deleted)
            const Padding(
              padding: EdgeInsets.only(top: 2, right: 6),
              child: Text(
                'изменено',
                style: TextStyle(fontSize: 10, color: AppColors.onGlassDim),
              ),
            ),
          if (widget.mine)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                widget.row.isPending ? Icons.access_time : Icons.done_all,
                size: 12,
                color: AppColors.onGlassDim,
              ),
            ),
        ],
      );
}

class _DeletedNotice extends StatelessWidget {
  const _DeletedNotice();
  @override
  Widget build(BuildContext context) => const Text(
        'сообщение удалено',
        style: TextStyle(
          fontSize: 14,
          fontStyle: FontStyle.italic,
          color: AppColors.onGlassDim,
        ),
      );
}

/// F11: in-bubble voice message player. Lazily resolves the audio source on
/// first play — plain blobs stream from the worker (with auth), E2E blobs are
/// downloaded + decrypted to a temp file then played from there.
class VoicePlayer extends StatefulWidget {
  final CachedAttachment attachment;
  final bool e2e;
  final String roomId;
  final String token;
  final bool mine;

  const VoicePlayer({
    super.key,
    required this.attachment,
    required this.e2e,
    required this.roomId,
    required this.token,
    required this.mine,
  });

  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  final AudioPlayer _player = AudioPlayer();
  bool _prepared = false;
  bool _loading = false;
  bool _failed = false;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;
  String? _tempPath;

  bool get _needsDecrypt => widget.e2e && widget.attachment.isE2e;

  @override
  void initState() {
    super.initState();
    final ms = widget.attachment.durationMs;
    if (ms != null && ms > 0) _total = Duration(milliseconds: ms);
    _player.positionStream.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.durationStream.listen((d) {
      if (d != null && mounted) setState(() => _total = d);
    });
    _player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (s.processingState == ProcessingState.completed) {
        _player.pause();
        _player.seek(Duration.zero);
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _player.dispose();
    final t = _tempPath;
    if (t != null) {
      try {
        File(t).deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _prepare() async {
    if (_prepared || _loading) return;
    setState(() => _loading = true);
    try {
      if (_needsDecrypt) {
        await _prepareEncrypted();
      } else {
        await _preparePlain();
      }
      _prepared = true;
    } catch (_) {
      _failed = true;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _preparePlain() async {
    final att = widget.attachment;
    final publicUrl = att.url;
    if (publicUrl != null && publicUrl.isNotEmpty) {
      await _player.setUrl(publicUrl);
      return;
    }
    final id = att.id;
    if (id == null) throw const FormatException('no audio source');
    await _player.setUrl(
      '${Config.apiBase}/attachments/$id',
      headers:
          widget.token.isEmpty ? null : {'Authorization': 'Bearer ${widget.token}'},
    );
  }

  Future<void> _prepareEncrypted() async {
    final att = widget.attachment;
    if (att.id == null ||
        att.iv == null ||
        att.wrappedKey == null ||
        att.wrappedKeyIv == null) {
      throw const FormatException('missing e2e material');
    }
    final api = Api(token: widget.token);
    final cipherBytes = await api.downloadAttachment(att.id!);
    final cipher = RoomCipher(api: api, roomId: widget.roomId);
    final plain = await cipher.decryptAttachment(
      keyVersion: att.keyVersion ?? 0,
      iv: Uint8List.fromList(base64Decode(att.iv!)),
      wrappedKey: Uint8List.fromList(base64Decode(att.wrappedKey!)),
      wrappedKeyIv: Uint8List.fromList(base64Decode(att.wrappedKeyIv!)),
      ciphertext: Uint8List.fromList(cipherBytes),
    );
    if (plain == null) throw const FormatException('decrypt failed');
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_play_${uuidV4()}.m4a';
    await File(path).writeAsBytes(plain, flush: true);
    _tempPath = path;
    await _player.setFilePath(path);
  }

  Future<void> _toggle() async {
    if (_failed) return;
    if (!_prepared) {
      await _prepare();
      if (_failed) return;
    }
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  String _fmt(Duration d) {
    final s = d.inSeconds;
    final mm = (s ~/ 60).toString();
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final playing = _player.playing;
    final total = _total.inMilliseconds > 0 ? _total : null;
    final progress = (total != null && total.inMilliseconds > 0)
        ? (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final label = _failed
        ? 'ошибка'
        : total != null
            ? _fmt(playing || _position > Duration.zero ? _position : total)
            : '--:--';

    return SizedBox(
      width: 180,
      child: Row(
        children: [
          GestureDetector(
            onTap: _toggle,
            child: Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                color: Color(0x33FFFFFF),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _failed
                          ? Icons.error_outline
                          : playing
                              ? Icons.pause
                              : Icons.play_arrow,
                      color: AppColors.onGlass,
                      size: 20,
                    ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    backgroundColor: const Color(0x33FFFFFF),
                    valueColor:
                        const AlwaysStoppedAnimation(AppColors.onGlass),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.onGlassDim,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
