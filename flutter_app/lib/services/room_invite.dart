import 'dart:convert';
import 'dart:typed_data';

import '../api.dart';
import '../crypto/e2e.dart';
import '../crypto/room_cipher.dart';

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
}
