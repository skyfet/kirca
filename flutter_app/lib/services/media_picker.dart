import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../crypto/room_cipher.dart';
import '../storage/cache.dart';
import '../util/mime.dart';

/// Thrown by [MediaPicker] when the user picks a file whose extension we
/// don't accept (server-side whitelist). Surfaces a clean error so the UI
/// can show a snackbar instead of failing deep inside the upload pipeline.
class UnsupportedMediaFormat implements Exception {
  final String path;
  UnsupportedMediaFormat(this.path);
  @override
  String toString() => 'UnsupportedMediaFormat($path)';
}

/// Result of a successful pick+upload: enough metadata for the chat screen
/// to inject a pending bubble and send a message referencing the upload.
class UploadedMedia {
  final String attachmentId;
  final CachedAttachment preview;
  const UploadedMedia({required this.attachmentId, required this.preview});
}

/// Picks an image from the gallery and uploads it.
///
/// Encapsulates the plain vs E2E branching so chat screens can stay focused
/// on local state and rendering: the only thing they receive back is a
/// ready-to-send [UploadedMedia].
class MediaPicker {
  final Api api;
  final ImagePicker _picker;

  MediaPicker(this.api, {ImagePicker? picker})
      : _picker = picker ?? ImagePicker();

  /// Pick + upload in plain mode. Returns null only when the user cancels
  /// the gallery sheet.
  Future<UploadedMedia?> pickAndUploadPlain() async {
    final picked = await _pick();
    if (picked == null) return null;
    final (path: path, bytes: bytes, mime: mime) = picked;
    final reserved = await api.reserveUpload(mime: mime, size: bytes.length);
    final ids = _idsFromReserve(reserved);
    if (ids == null) {
      throw const FormatException('upload reservation missing url/id');
    }
    await api.uploadBytes(ids.uploadUrl, bytes, mime);
    return UploadedMedia(
      attachmentId: ids.attachmentId,
      preview: CachedAttachment(
        id: ids.attachmentId,
        url: reserved['public_url']?.toString(),
        mime: mime,
      ),
    );
  }

  /// Pick + encrypt + upload for an E2E room. Returns null only on user
  /// cancellation. Throws [RoomKeyUnavailable] when the room key isn't ready
  /// yet, and [UnsupportedMediaFormat] for non-image extensions.
  Future<UploadedMedia?> pickAndUploadEncrypted({
    required RoomCipher cipher,
  }) async {
    final picked = await _pick();
    if (picked == null) return null;
    final (path: _, bytes: bytes, mime: mime) = picked;

    final enc = await cipher.encryptAttachment(Uint8List.fromList(bytes));
    final reserved = await api.reserveUpload(
      mime: 'application/octet-stream',
      size: enc.cipher.ciphertext.length,
      e2e: true,
      roomId: cipher.roomId,
      iv: base64Encode(enc.cipher.iv),
      wrappedKey: base64Encode(enc.cipher.wrappedKey),
      wrappedKeyIv: base64Encode(enc.cipher.wrappedKeyIv),
      keyVersion: enc.keyVersion,
    );
    final ids = _idsFromReserve(reserved);
    if (ids == null) {
      throw const FormatException('upload reservation missing url/id');
    }
    await api.uploadBytes(
      ids.uploadUrl,
      enc.cipher.ciphertext,
      'application/octet-stream',
    );
    return UploadedMedia(
      attachmentId: ids.attachmentId,
      preview: CachedAttachment(
        id: ids.attachmentId,
        url: reserved['public_url']?.toString(),
        mime: mime,
        wrappedKey: base64Encode(enc.cipher.wrappedKey),
        wrappedKeyIv: base64Encode(enc.cipher.wrappedKeyIv),
        iv: base64Encode(enc.cipher.iv),
        keyVersion: enc.keyVersion,
      ),
    );
  }

  Future<({String path, Uint8List bytes, String mime})?> _pick() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
    );
    if (picked == null) return null;
    final mime = imageMimeFromPath(picked.path);
    if (mime == null) throw UnsupportedMediaFormat(picked.path);
    final bytes = await File(picked.path).readAsBytes();
    return (path: picked.path, bytes: bytes, mime: mime);
  }

  ({String uploadUrl, String attachmentId})? _idsFromReserve(
    Map<String, dynamic> reserved,
  ) {
    final url = reserved['upload_url']?.toString();
    final id = reserved['id']?.toString();
    if (url == null || id == null) return null;
    return (uploadUrl: url, attachmentId: id);
  }
}
