import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'e2e.dart';

/// Persists the user's X25519 identity locally so E2E ops don't need to
/// re-prompt for the recovery phrase on every session. Secrets live in the
/// platform keyring via flutter_secure_storage.
class KeyStore {
  static const _store = FlutterSecureStorage();
  static const _idPubKey = 'e2e_id_pub';
  static const _idPrivKey = 'e2e_id_priv';

  static Future<IdentityKeyPair?> loadIdentity() async {
    try {
      final pub = await _store.read(key: _idPubKey);
      final priv = await _store.read(key: _idPrivKey);
      if (pub == null || priv == null) return null;
      return IdentityKeyPair(
        publicKey: Uint8List.fromList(base64Decode(pub)),
        privateKey: Uint8List.fromList(base64Decode(priv)),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveIdentity(IdentityKeyPair id) async {
    try {
      await _store.write(key: _idPubKey, value: base64Encode(id.publicKey));
      await _store.write(key: _idPrivKey, value: base64Encode(id.privateKey));
    } catch (_) { /* best-effort */ }
  }

  static Future<void> wipeIdentity() async {
    try {
      await _store.delete(key: _idPubKey);
      await _store.delete(key: _idPrivKey);
    } catch (_) { /* */ }
  }

  /// Per-room decrypted symmetric keys are NOT persisted — they're re-derived
  /// from the sealed envelopes on /rooms/:id/keys at app start. This avoids
  /// stale-key bugs after rotation.
}
