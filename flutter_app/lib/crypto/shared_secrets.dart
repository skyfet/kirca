import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config.dart';

/// Mirrors the few secrets the iOS Notification Service Extension (NSE) needs
/// at push time into a shared App Group keychain, so the extension — which
/// runs in its own process and cannot see the app's in-memory state — can
/// fetch + decrypt the message referenced by an `aps.mutable-content` push.
///
/// What the NSE reads back (Security framework, kSecClassGenericPassword):
///   service (kSecAttrService) = 'flutter_secure_storage_service'  (plugin default)
///   account (kSecAttrAccount) = the key below
///   accessGroup (kSecAttrAccessGroup) = 'group.com.example.kirca'
///
/// Keys:
///   auth_token                  bearer token (no "Bearer " prefix)
///   api_base_url                Config.apiBase
///   roomkey_<roomId>_<keyVer>   base64(rawRoomKey)  (32-byte AES-256-GCM key)
///
/// All writes are best-effort (try/catch swallowed) exactly like [KeyStore],
/// so a missing keyring / non-iOS platform never breaks the auth or chat flow.
class SharedSecrets {
  // App Group used for both the keychain-access-group sharing and the App
  // Group container. Must match the value in the Runner + NSE entitlements
  // and the `group.com.example.kirca` registered in the Apple Dev portal.
  static const String appGroup = 'group.com.example.kirca';

  static const String _kAuthToken = 'auth_token';
  static const String _kApiBaseUrl = 'api_base_url';
  static const String _roomKeyPrefix = 'roomkey_';

  // Shared-keychain handle. The groupId routes items into the App Group
  // access-group; first_unlock keeps them readable from a background NSE
  // launch after the first device unlock (matching APNs delivery semantics).
  static const FlutterSecureStorage _store = FlutterSecureStorage(
    iOptions: IOSOptions(
      groupId: appGroup,
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );

  static String _roomKeyName(String roomId, int keyVersion) =>
      '$_roomKeyPrefix${roomId}_$keyVersion';

  /// Write the bearer token + API base URL the NSE uses to fetch a single
  /// message. Called wherever auth is established (login / restore).
  static Future<void> writeAuth(String token) async {
    try {
      await _store.write(key: _kAuthToken, value: token);
      await _store.write(key: _kApiBaseUrl, value: Config.apiBase);
    } catch (_) {
      /* best-effort — non-iOS / no keyring */
    }
  }

  /// Mirror a decrypted room key so the NSE can decrypt that key version's
  /// ciphertext. [key] is the raw 32-byte AES key; stored as base64.
  static Future<void> writeRoomKey(
    String roomId,
    int keyVersion,
    Uint8List key,
  ) async {
    try {
      await _store.write(
        key: _roomKeyName(roomId, keyVersion),
        value: base64Encode(key),
      );
    } catch (_) {
      /* best-effort */
    }
  }

  /// Drop every shared item (auth + all room keys) on logout / wipe.
  static Future<void> clearAll() async {
    try {
      await _store.deleteAll();
    } catch (_) {
      /* best-effort */
    }
  }
}
