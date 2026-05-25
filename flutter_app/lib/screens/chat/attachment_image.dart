import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../api.dart';
import '../../config.dart';
import '../../crypto/room_cipher.dart';
import '../../storage/cache.dart';
import '../../theme/app_theme.dart';

/// Fixed dimensions for in-bubble thumbnails. Keeping width/height stable
/// avoids ListView jank when the image swaps from placeholder to content.
const double _kThumbW = 220;
const double _kThumbH = 160;

/// Renders an attachment as a thumbnail inside a chat bubble.
///
/// Two modes:
/// - **E2E + sealed blob**: pulls the ciphertext via the authed
///   `/attachments/:id` passthrough, decrypts with the room key, then renders
///   from memory.
/// - **Plain**: prefers the public R2 URL when configured (production); falls
///   back to the authed worker endpoint in dev / when `R2_PUBLIC_BASE` is
///   empty.
///
/// Always shows a placeholder while loading and a broken-image icon on
/// failure, so callers never have to render their own loading state.
class AttachmentImage extends StatefulWidget {
  final CachedAttachment attachment;
  final bool e2e;
  final String roomId;
  final String token;

  const AttachmentImage({
    super.key,
    required this.attachment,
    required this.e2e,
    required this.roomId,
    required this.token,
  });

  @override
  State<AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<AttachmentImage> {
  Uint8List? _bytes;
  bool _failed = false;

  bool get _needsDecrypt => widget.e2e && widget.attachment.isE2e;

  @override
  void initState() {
    super.initState();
    if (_needsDecrypt) _loadAndDecrypt();
  }

  Future<void> _loadAndDecrypt() async {
    final att = widget.attachment;
    if (att.id == null || att.iv == null || att.wrappedKey == null ||
        att.wrappedKeyIv == null) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    try {
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
      if (!mounted) return;
      setState(() {
        if (plain == null) {
          _failed = true;
        } else {
          _bytes = plain;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_needsDecrypt) {
      if (_failed) return const _BrokenThumb();
      if (_bytes == null) return const _LoadingThumb();
      return Image.memory(_bytes!, width: _kThumbW, fit: BoxFit.cover);
    }
    return _PlainNetworkThumb(
      attachment: widget.attachment,
      token: widget.token,
    );
  }
}

/// Plain (non-E2E) thumbnail. Picks the best URL available and routes auth
/// headers when we have to go through the worker.
class _PlainNetworkThumb extends StatelessWidget {
  final CachedAttachment attachment;
  final String token;

  const _PlainNetworkThumb({
    required this.attachment,
    required this.token,
  });

  @override
  Widget build(BuildContext context) {
    final source = _resolveSource();
    if (source == null) return const _BrokenThumb();
    return Image.network(
      source.url,
      width: _kThumbW,
      fit: BoxFit.cover,
      headers: source.headers,
      loadingBuilder: (_, child, progress) =>
          progress == null ? child : const _LoadingThumb(),
      errorBuilder: (_, __, ___) => const _BrokenThumb(),
    );
  }

  /// Returns the (url, headers) pair Image.network should hit, or null if the
  /// attachment lacks any addressable source.
  ({String url, Map<String, String>? headers})? _resolveSource() {
    final publicUrl = attachment.url;
    if (publicUrl != null && publicUrl.isNotEmpty) {
      return (url: publicUrl, headers: null);
    }
    final id = attachment.id;
    if (id == null) return null;
    return (
      url: '${Config.apiBase}/attachments/$id',
      headers:
          token.isEmpty ? null : {'Authorization': 'Bearer $token'},
    );
  }
}

class _LoadingThumb extends StatelessWidget {
  const _LoadingThumb();
  @override
  Widget build(BuildContext context) => Container(
        width: _kThumbW,
        height: _kThumbH,
        alignment: Alignment.center,
        color: const Color(0x22000000),
        child: const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
}

class _BrokenThumb extends StatelessWidget {
  const _BrokenThumb();
  @override
  Widget build(BuildContext context) => const SizedBox(
        width: _kThumbW,
        height: _kThumbH,
        child: Center(
          child: Icon(Icons.broken_image, color: AppColors.onGlassDim),
        ),
      );
}
