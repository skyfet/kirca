import 'dart:convert';
import 'dart:typed_data';

import '../api.dart';
import '../crypto/e2e.dart';
import '../crypto/key_store.dart';
import '../crypto/room_cipher.dart';
import '../crypto/room_keys.dart';

/// Thrown when we try to seal a room key for a user who hasn't published
/// their X25519 identity yet — they need to enable E2E in their profile
/// before they can receive sealed envelopes.
class PeerHasNoIdentity implements Exception {
  final String userId;
  PeerHasNoIdentity(this.userId);
  @override
  String toString() => 'PeerHasNoIdentity($userId)';
}

/// Coordinates the "invite + seal room key" flow for E2E rooms.
///
/// Sealing happens at invite-time (rather than on invite acceptance) because
/// the inviter is the only one who holds the room key — the server stores
/// only opaque sealed envelopes, so without this step the invitee opens the
/// chat and finds no envelope addressed to them.
class RoomInviteService {
  final Api api;
  const RoomInviteService(this.api);

  /// Sends an invite to [username]. For E2E rooms, also publishes the
  /// current room key sealed for the new member. Throws [PeerHasNoIdentity]
  /// when the invitee can't receive sealed envelopes.
  Future<Map<String, dynamic>> inviteByUsername({
    required String roomId,
    required String username,
    RoomCipher? cipherForSealing,
  }) async {
    final invite = await api.invite(roomId, username: username);
    if (cipherForSealing != null) {
      await _sealCurrentKeyFor(invite, cipherForSealing);
    }
    return invite;
  }

  Future<void> _sealCurrentKeyFor(
    Map<String, dynamic> invite,
    RoomCipher cipher,
  ) async {
    final inviteeId = invite['invitee_user_id']?.toString();
    if (inviteeId == null) return;
    final roomKey = await cipher.currentKey();
    if (roomKey == null) return; // nothing to seal yet
    final peerPub = await _fetchPeerIdentity(inviteeId);
    final sealed = await E2E.sealRoomKey(
      recipientPubKey: peerPub,
      roomKey: roomKey,
    );
    await api.publishRoomKeys(
      cipher.roomId,
      keyVersion: cipher.currentVersion(),
      keys: [
        {
          'member_user_id': inviteeId,
          'sealed': base64Encode(sealed),
        },
      ],
    );
  }

  Future<Uint8List> _fetchPeerIdentity(String userId) async {
    final ident = await api.getUserIdentity(userId);
    final pubB64 = ident['identity_pub']?.toString();
    if (pubB64 == null || pubB64.isEmpty) {
      throw PeerHasNoIdentity(userId);
    }
    return Uint8List.fromList(base64Decode(pubB64));
  }

  /// F20: seal the freshly-minted DM room key for both members of a new
  /// friendship and publish the envelopes, then cache our own copy.
  ///
  /// The server auto-creates the E2E DM room when a friendship forms but never
  /// seals room keys — the client that accepts the request is the only one who
  /// holds the key, so it must wrap it for itself and (best-effort) for the
  /// peer.
  ///
  /// Returns a [DmKeyPairingResult] describing what happened so the caller can
  /// surface a soft message. Throws nothing for the "happy" and
  /// "peer-has-no-identity" paths; genuine failures (network etc.) propagate so
  /// the caller can show an error while the friendship itself still stands.
  Future<DmKeyPairingResult> sealDmKeyForFriendship({
    required String dmRoomId,
    required int keyVersion,
    required String myUserId,
    required String friendUserId,
  }) async {
    // Own identity — without it we can't even seal for ourselves.
    final me = await KeyStore.loadIdentity();
    if (me == null) {
      return DmKeyPairingResult.noLocalIdentity;
    }

    final roomKey = E2E.newRoomKey();

    // Seal for self (always).
    final sealedSelf = await E2E.sealRoomKey(
      recipientPubKey: me.publicKey,
      roomKey: roomKey,
    );
    final keys = <Map<String, String>>[
      {'member_user_id': myUserId, 'sealed': base64Encode(sealedSelf)},
    ];

    // Seal for the peer if they've published an identity; otherwise they'll
    // restore/re-seal later — don't hard-fail the friendship over it.
    bool sealedForPeer = false;
    try {
      final peerPub = await _fetchPeerIdentity(friendUserId);
      final sealedPeer = await E2E.sealRoomKey(
        recipientPubKey: peerPub,
        roomKey: roomKey,
      );
      keys.add(
        {'member_user_id': friendUserId, 'sealed': base64Encode(sealedPeer)},
      );
      sealedForPeer = true;
    } on PeerHasNoIdentity {
      // Peer hasn't enabled E2E yet — publish only our envelope.
    }

    await api.publishRoomKeys(dmRoomId, keyVersion: keyVersion, keys: keys);
    RoomKeyCache.put(dmRoomId, keyVersion, roomKey);

    return sealedForPeer
        ? DmKeyPairingResult.sealedForBoth
        : DmKeyPairingResult.sealedForSelfOnly;
  }
}

/// Outcome of [RoomInviteService.sealDmKeyForFriendship], so callers can show
/// an appropriate soft message without inspecting exceptions.
enum DmKeyPairingResult {
  /// Sealed for both members and published — DM is fully ready.
  sealedForBoth,

  /// Sealed only for self; the peer hasn't published an identity yet and will
  /// seal/restore on their side later.
  sealedForSelfOnly,

  /// We have no local identity, so nothing was sealed. The friendship still
  /// succeeded; messaging needs E2E keys set up first.
  noLocalIdentity,
}
