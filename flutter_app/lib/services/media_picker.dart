import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../api.dart';
import '../crypto/room_cipher.dart';
import '../storage/cache.dart';
import '../util/blurhash_encode.dart';
import '../util/mime.dart';
import '../util/uuid.dart';

/// MIME we upload recorded voice notes as (AAC in an MPEG-4/m4a container).
const String kVoiceMime = 'audio/mp4';

/// Result of stopping a [VoiceRecorder]: the recorded bytes plus how long the
/// clip ran (measured wall-clock, good enough for the bubble label).
class RecordedVoice {
  final Uint8List bytes;
  final int durationMs;
  const RecordedVoice({required this.bytes, required this.durationMs});
}

/// F11: thin wrapper over the `record` package for press-and-hold voice notes.
/// Records AAC/m4a to a temp file, then hands the bytes back so the chat screen
/// can push them through the existing attachment upload pipeline.
class VoiceRecorder {
  final AudioRecorder _rec = AudioRecorder();
  String? _path;
  DateTime? _startedAt;

  /// True once [start] has begun a recording and before [stop]/[cancel].
  bool get isRecording => _startedAt != null;

  /// Ask for the mic permission and begin recording. Returns false (and
  /// records nothing) when permission is denied.
  Future<bool> start() async {
    if (!await _rec.hasPermission()) return false;
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${uuidV4()}.m4a';
    await _rec.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, numChannels: 1),
      path: path,
    );
    _path = path;
    _startedAt = DateTime.now();
    return true;
  }

  /// Stop recording and return the captured clip, or null if nothing was
  /// recorded / the file is missing.
  Future<RecordedVoice?> stop() async {
    final started = _startedAt;
    _startedAt = null;
    if (started == null) return null;
    final outPath = await _rec.stop();
    final path = outPath ?? _path;
    _path = null;
    if (path == null) return null;
    final f = File(path);
    if (!await f.exists()) return null;
    final bytes = await f.readAsBytes();
    final durationMs = DateTime.now().difference(started).inMilliseconds;
    try {
      await f.delete();
    } catch (_) {/* best-effort temp cleanup */}
    if (bytes.isEmpty) return null;
    return RecordedVoice(bytes: bytes, durationMs: durationMs);
  }

  /// Abort the current recording, discarding any captured audio.
  Future<void> cancel() async {
    _startedAt = null;
    _path = null;
    try {
      await _rec.cancel();
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      await _rec.dispose();
    } catch (_) {}
  }
}

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
    final (path: _, bytes: bytes, mime: mime) = picked;
    final blurhash = await encodeBlurhash(bytes);
    final reserved = await api.reserveUpload(
      mime: mime,
      size: bytes.length,
      blurhash: blurhash,
    );
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
        blurhash: blurhash,
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
    // Blurhash is computed from the plaintext bytes BEFORE encryption so the
    // server never sees a thumbnail-ish hash. It rides to the receiver inside
    // the encrypted message envelope (see encodeE2eEnvelope).
    final blurhash = await encodeBlurhash(bytes);
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
        blurhash: blurhash,
      ),
    );
  }

  /// Upload an already-recorded voice note (plain mode). [durationMs] is
  /// carried through to the bubble so it can show the clip length immediately,
  /// and to the server so other clients pick it up from history.
  Future<UploadedMedia> uploadVoicePlain(
    Uint8List bytes, {
    required int durationMs,
  }) async {
    final reserved = await api.reserveUpload(
      mime: kVoiceMime,
      size: bytes.length,
      durationMs: durationMs,
    );
    final ids = _idsFromReserve(reserved);
    if (ids == null) {
      throw const FormatException('upload reservation missing url/id');
    }
    await api.uploadBytes(ids.uploadUrl, bytes, kVoiceMime);
    return UploadedMedia(
      attachmentId: ids.attachmentId,
      preview: CachedAttachment(
        id: ids.attachmentId,
        url: reserved['public_url']?.toString(),
        mime: kVoiceMime,
        durationMs: durationMs,
      ),
    );
  }

  /// Upload an already-recorded voice note for an E2E room: encrypt the audio
  /// bytes under the room key (same blob path as images) and carry the
  /// duration in the bubble preview (never sent to the server in the clear).
  Future<UploadedMedia> uploadVoiceEncrypted(
    Uint8List bytes, {
    required RoomCipher cipher,
    required int durationMs,
  }) async {
    final enc = await cipher.encryptAttachment(bytes);
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
        mime: kVoiceMime,
        wrappedKey: base64Encode(enc.cipher.wrappedKey),
        wrappedKeyIv: base64Encode(enc.cipher.wrappedKeyIv),
        iv: base64Encode(enc.cipher.iv),
        keyVersion: enc.keyVersion,
        durationMs: durationMs,
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
