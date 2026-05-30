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

  /// Maps a DM room id -> the peer's user id. DM rooms don't use sealed
  /// envelopes; their key is derived deterministically from both members'
  /// X25519 identities (see [E2E.deriveDmKey]). Populated wherever DM rooms
  /// become known (rooms refresh, room_added, opening a friend's chat).
  static final Map<String, String> _dmPeers = {};

  /// DM pairing keys live at version 1 (the server seeds DM rooms with
  /// key_version = 1 and never rotates them).
  static const int dmKeyVersion = 1;

  /// Record that [roomId] is a DM with [peerUserId] so [_refresh] derives the
  /// pairing key instead of looking for (non-existent) sealed envelopes.
  /// Idempotent and best-effort; empty peer ids are ignored.
  static void registerDm(String roomId, String? peerUserId) {
    if (peerUserId == null || peerUserId.isEmpty) return;
    _dmPeers[roomId] = peerUserId;
  }

  /// Eagerly derive + cache the DM pairing key for [roomId] with [peerUserId].
  /// Returns the key, or null when our identity / the peer's published key is
  /// missing. Safe to call repeatedly — derivation is deterministic.
  static Future<Uint8List?> ensureDmKey(
    Api api,
    String roomId,
    String peerUserId,
  ) async {
    registerDm(roomId, peerUserId);
    final hit = _cache[roomId]?[dmKeyVersion];
    if (hit != null) return hit;
    await _refresh(api, roomId);
    return _cache[roomId]?[dmKeyVersion];
  }

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
    _dmPeers.clear();
  }

  static Future<void> _refresh(Api api, String roomId) async {
    final id = await KeyStore.loadIdentity();
    if (id == null) return;

    // DM rooms: derive the deterministic pairing key from both members'
    // identities. No sealed envelopes are ever published for a DM, so this is
    // the only key source — and it's symmetric, so both peers land on the same
    // key with zero coordination.
    final peer = _dmPeers[roomId];
    if (peer != null && peer.isNotEmpty) {
      try {
        final ident = await api.getUserIdentity(peer);
        final pubB64 = ident['identity_pub']?.toString();
        if (pubB64 == null || pubB64.isEmpty) return; // peer has no E2E yet
        final key = await E2E.deriveDmKey(
          myPrivateKey: id.privateKey,
          myPublicKey: id.publicKey,
          peerPublicKey: Uint8List.fromList(base64Decode(pubB64)),
        );
        put(roomId, dmKeyVersion, key);
      } catch (_) {
        // Network / malformed key — leave the cache empty so the caller can
        // surface "key unavailable" and retry later.
      }
      return;
    }

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
