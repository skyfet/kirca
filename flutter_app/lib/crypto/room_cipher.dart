import 'dart:typed_data';

import '../api.dart';
import 'e2e.dart';
import 'room_keys.dart';

/// Thrown when a caller asks for the current room key but [RoomKeyCache]
/// can't surface one (we never received an envelope, our identity isn't
/// loaded, etc.). The chat UI catches this to render a user-facing message
/// instead of silently dropping a send.
class RoomKeyUnavailable implements Exception {
  final String roomId;
  RoomKeyUnavailable(this.roomId);
  @override
  String toString() => 'RoomKeyUnavailable($roomId)';
}

/// Per-room view over [RoomKeyCache] + [E2E]. Folds the recurring
/// "latest key + latest version + encrypt" boilerplate into a single object
/// that callers can pass around. Stateless aside from the room/version
/// bindings — safe to construct on demand.
class RoomCipher {
  final Api api;
  final String roomId;

  /// Last server-known key version, used as a floor when the in-memory cache
  /// is empty (e.g. immediately after [Api.history] returns a ciphertext-only
  /// row but the key envelope hasn't been refreshed yet).
  final int fallbackVersion;

  const RoomCipher({
    required this.api,
    required this.roomId,
    this.fallbackVersion = 0,
  });

  /// Currently active room key. Triggers a server refresh if the in-memory
  /// cache is empty. Returns null only when the server has no envelope for
  /// us — callers typically translate this into [RoomKeyUnavailable].
  Future<Uint8List?> currentKey() =>
      RoomKeyCache.latest(api, roomId);

  /// Version the current key was published under. Falls back to
  /// [fallbackVersion] (typically the room row's `key_version`) when nothing
  /// has been cached yet.
  int currentVersion() =>
      RoomKeyCache.latestVersion(roomId) ?? fallbackVersion;

  Future<Uint8List?> keyAt(int keyVersion) =>
      RoomKeyCache.get(api, roomId, keyVersion);

  /// Wraps [currentKey] + null-check into a single throw-on-miss call so
  /// callers can stop repeating the "if (key == null) snackbar" branch.
  Future<Uint8List> _requireKey() async {
    final k = await currentKey();
    if (k == null) throw RoomKeyUnavailable(roomId);
    return k;
  }

  /// Encrypts a plaintext message under the current room key.
  Future<({MessageCipher cipher, int keyVersion})> encryptMessage(
    String plaintext,
  ) async {
    final key = await _requireKey();
    final cipher = await E2E.encryptMessage(roomKey: key, plaintext: plaintext);
    return (cipher: cipher, keyVersion: currentVersion());
  }

  /// Encrypts attachment bytes under the current room key (per-blob AES key
  /// is generated inside [E2E.encryptAttachment]).
  Future<({AttachmentCipher cipher, int keyVersion})> encryptAttachment(
    Uint8List bytes,
  ) async {
    final key = await _requireKey();
    final cipher = await E2E.encryptAttachment(roomKey: key, bytes: bytes);
    return (cipher: cipher, keyVersion: currentVersion());
  }

  /// Decrypts a message ciphertext using whichever key version it references.
  /// Returns null when the matching key isn't (yet) available, so callers
  /// can leave the bubble empty for a later retry.
  Future<String?> decryptMessage({
    required int keyVersion,
    required Uint8List iv,
    required Uint8List ciphertext,
  }) async {
    final key = await keyAt(keyVersion);
    if (key == null) return null;
    try {
      return await E2E.decryptMessage(
        roomKey: key,
        cipher: MessageCipher(iv: iv, ciphertext: ciphertext),
      );
    } catch (_) {
      return null;
    }
  }

  /// Decrypts attachment ciphertext. Returns null if the key isn't available
  /// or the ciphertext is malformed.
  Future<Uint8List?> decryptAttachment({
    required int keyVersion,
    required Uint8List iv,
    required Uint8List wrappedKey,
    required Uint8List wrappedKeyIv,
    required Uint8List ciphertext,
  }) async {
    final key = await keyAt(keyVersion);
    if (key == null) return null;
    try {
      return await E2E.decryptAttachment(
        roomKey: key,
        cipher: AttachmentCipher(
          ciphertext: ciphertext,
          iv: iv,
          wrappedKey: wrappedKey,
          wrappedKeyIv: wrappedKeyIv,
        ),
      );
    } catch (_) {
      return null;
    }
  }
}
