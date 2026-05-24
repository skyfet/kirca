import 'dart:convert';
import 'dart:typed_data';

import '../api.dart';
import 'e2e.dart';
import 'key_store.dart';
import 'phrase.dart';

/// First-run identity setup: generate a fresh X25519 keypair, a recovery
/// phrase, derive the recovery key, AES-GCM-wrap the private key, and publish
/// the bundle to the server. Returns the 24-word phrase so the UI can show it
/// to the user.
class IdentitySetup {
  /// Generates a brand-new identity for this user. Returns the recovery
  /// phrase the user must write down.
  static Future<List<String>> initialize(Api api) async {
    final id = await E2E.generateIdentity();
    final phrase = await Phrase.generate();
    final seed = await Phrase.toSeed(phrase);
    final salt = E2E.newRecoverySalt();
    final recoveryKey = await E2E.deriveRecoveryKey(
      phraseSeed: seed,
      salt: salt,
    );
    final wrapped = await E2E.wrapWithKey(
      key: recoveryKey,
      plaintext: id.privateKey,
    );
    await KeyStore.saveIdentity(id);
    await api.publishIdentity(
      identityPub: base64Encode(id.publicKey),
      identityPrivWrapped: base64Encode(wrapped.ciphertext),
      identityPrivIv: base64Encode(wrapped.iv),
      recoverySalt: base64Encode(salt),
    );
    return phrase;
  }

  /// Restore the identity on a new device. Pulls the wrapped bundle from
  /// the server, derives the recovery key from the typed phrase, unwraps
  /// the private key, persists locally.
  static Future<void> restore(Api api, List<String> phrase) async {
    final bundle = await api.getMyIdentity();
    final pub = bundle['identity_pub'] as String?;
    final wrapped = bundle['identity_priv_wrapped'] as String?;
    final iv = bundle['identity_priv_iv'] as String?;
    final saltB64 = bundle['recovery_salt'] as String?;
    if (pub == null || wrapped == null || iv == null || saltB64 == null) {
      throw const FormatException('no identity bundle published yet');
    }
    final seed = await Phrase.toSeed(phrase);
    final salt = Uint8List.fromList(base64Decode(saltB64));
    final recoveryKey = await E2E.deriveRecoveryKey(
      phraseSeed: seed,
      salt: salt,
    );
    final priv = await E2E.unwrapWithKey(
      key: recoveryKey,
      blob: WrappedBlob(
        iv: Uint8List.fromList(base64Decode(iv)),
        ciphertext: Uint8List.fromList(base64Decode(wrapped)),
      ),
    );
    await KeyStore.saveIdentity(IdentityKeyPair(
      publicKey: Uint8List.fromList(base64Decode(pub)),
      privateKey: priv,
    ));
  }

  /// On every login, after the session token is set, check whether the
  /// server has an identity bundle and whether we already have local keys.
  /// Returns a status the UI can act on.
  static Future<IdentityStatus> probeIdentity(Api api) async {
    final local = await KeyStore.loadIdentity();
    Map<String, dynamic> server;
    try {
      server = await api.getMyIdentity();
    } catch (_) {
      return IdentityStatus.unknown;
    }
    final serverHasBundle = (server['identity_priv_wrapped'] as String?) != null;
    if (local != null && serverHasBundle) return IdentityStatus.ready;
    if (local != null && !serverHasBundle) return IdentityStatus.localOnly;
    if (local == null && serverHasBundle) return IdentityStatus.needsRestore;
    return IdentityStatus.absent;
  }
}

enum IdentityStatus {
  /// Local keys present, server bundle published. Steady state.
  ready,

  /// Local keys exist but server doesn't know about them yet (first session
  /// after a fresh install where keys came from somewhere local). UI should
  /// re-publish.
  localOnly,

  /// Server has a wrapped key, this device doesn't. User should be prompted
  /// for their recovery phrase to restore.
  needsRestore,

  /// Neither side has anything. First-time signup path — UI should call
  /// [IdentitySetup.initialize] and show the new phrase.
  absent,

  /// Couldn't determine (network error, etc.). Defer.
  unknown,
}
