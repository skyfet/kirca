import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../api.dart';
import 'room_cipher.dart';

/// F3: keyed mention tags for E2E rooms.
///
/// The server never sees plaintext in an E2E room, so it can't know who was
/// @-mentioned. Instead each member derives a *deterministic, room-scoped*
/// token from the room key + their own user id and publishes it via
/// [Api.publishMentionTag]. When a sender @-mentions someone they compute the
/// same token (they hold the same room key) and attach it to the message; the
/// server can then match tokens to deliver mention pushes without learning the
/// user ids.
///
/// Derivation (must match the iOS/Android/backend implementations):
///   prk = HKDF-SHA256(ikm=roomKey, salt=<empty>, info="kirca-mention-v1",
///                     length=32)
///   tag = base64( HMAC-SHA256(key=prk, message=utf8(user_id)) )
class MentionTags {
  static final _hmac = Hmac.sha256();
  static const _info = 'kirca-mention-v1';

  /// Derive the mention tag for [userId] under the AES-256 [roomKey].
  static Future<String> mentionTagFor(Uint8List roomKey, String userId) async {
    final prk = await _derivePrk(roomKey);
    final mac = await _hmac.calculateMac(
      utf8.encode(userId),
      secretKey: SecretKey(prk),
    );
    return base64Encode(mac.bytes);
  }

  /// Derive tags for many user ids under the same room key (one HKDF pass).
  static Future<Map<String, String>> mentionTagsForAll(
    Uint8List roomKey,
    Iterable<String> userIds,
  ) async {
    final prk = await _derivePrk(roomKey);
    final key = SecretKey(prk);
    final out = <String, String>{};
    for (final uid in userIds) {
      final mac = await _hmac.calculateMac(utf8.encode(uid), secretKey: key);
      out[uid] = base64Encode(mac.bytes);
    }
    return out;
  }

  /// Convenience for the chat agent: given an [api] + [roomId], fetch the
  /// current room key (via [RoomCipher]/[RoomKeyCache]) and compute tags for
  /// [userIds]. Returns null when the room key is unavailable (caller can fall
  /// back to skipping mention tokens). [fallbackKeyVersion] is the room row's
  /// `key_version`, used as a floor when the in-memory key cache is empty.
  static Future<Map<String, String>?> tagsForRoom(
    Api api,
    String roomId,
    Iterable<String> userIds, {
    int fallbackKeyVersion = 0,
  }) async {
    final cipher = RoomCipher(
      api: api,
      roomId: roomId,
      fallbackVersion: fallbackKeyVersion,
    );
    final key = await cipher.currentKey();
    if (key == null) return null;
    return mentionTagsForAll(key, userIds);
  }

  /// Convenience for a member publishing their OWN tag in [roomId] so senders'
  /// tokens can be matched against it. Returns the published tag, or null when
  /// the room key isn't available.
  static Future<String?> publishOwnTag(
    Api api,
    String roomId,
    String selfUserId, {
    int fallbackKeyVersion = 0,
  }) async {
    final cipher = RoomCipher(
      api: api,
      roomId: roomId,
      fallbackVersion: fallbackKeyVersion,
    );
    final key = await cipher.currentKey();
    if (key == null) return null;
    final tag = await mentionTagFor(key, selfUserId);
    await api.publishMentionTag(roomId, tag);
    return tag;
  }

  static Future<Uint8List> _derivePrk(Uint8List roomKey) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(roomKey),
      nonce: const <int>[], // empty salt
      info: utf8.encode(_info),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }
}
