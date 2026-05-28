import 'dart:convert';
import 'dart:typed_data';

import '../api.dart';
import 'e2e.dart';
import 'key_store.dart';
import 'shared_secrets.dart';

/// Process-wide cache of decrypted per-room AES keys, indexed by
/// (roomId, keyVersion). Cleared on logout.
class RoomKeyCache {
  static final Map<String, Map<int, Uint8List>> _cache = {};

  static Future<Uint8List?> get(
    Api api,
    String roomId,
    int keyVersion,
  ) async {
    final hit = _cache[roomId]?[keyVersion];
    if (hit != null) return hit;
    await _refresh(api, roomId);
    return _cache[roomId]?[keyVersion];
  }

  static Future<Uint8List?> latest(Api api, String roomId) async {
    final byVer = _cache[roomId];
    if (byVer == null || byVer.isEmpty) {
      await _refresh(api, roomId);
    }
    final map = _cache[roomId];
    if (map == null || map.isEmpty) return null;
    final maxV = map.keys.reduce((a, b) => a > b ? a : b);
    return map[maxV];
  }

  static int? latestVersion(String roomId) {
    final map = _cache[roomId];
    if (map == null || map.isEmpty) return null;
    return map.keys.reduce((a, b) => a > b ? a : b);
  }

  static void put(String roomId, int keyVersion, Uint8List key) {
    _cache.putIfAbsent(roomId, () => {})[keyVersion] = key;
    // Best-effort mirror into the App Group keychain so the iOS NSE can
    // decrypt offline pushes for this key version. Fire-and-forget — never
    // blocks or breaks the in-memory cache contract.
    SharedSecrets.writeRoomKey(roomId, keyVersion, key);
  }

  static void clear() {
    _cache.clear();
  }

  static Future<void> _refresh(Api api, String roomId) async {
    final id = await KeyStore.loadIdentity();
    if (id == null) return;
    List<dynamic> sealed;
    try {
      sealed = await api.getRoomKeys(roomId);
    } catch (_) {
      return;
    }
    for (final s in sealed) {
      final m = s as Map<String, dynamic>;
      final v = (m['key_version'] as num).toInt();
      final bytes = base64Decode(m['sealed'] as String);
      try {
        final unwrapped = await E2E.openRoomKey(
          recipientPrivKey: id.privateKey,
          recipientPubKey: id.publicKey,
          sealed: Uint8List.fromList(bytes),
        );
        put(roomId, v, unwrapped);
      } catch (_) {
        // Sealed for some other recipient or our key changed. Skip.
      }
    }
  }
}
