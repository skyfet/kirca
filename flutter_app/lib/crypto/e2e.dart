import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// End-to-end cryptography primitives for kirca.
///
/// Layout of secrets:
///   identityKeyPair   X25519 keypair, generated locally on first registration
///                     or after recovery from phrase.
///   recoveryKey       32 bytes derived from PBKDF2-SHA512(phraseSeed, salt).
///   wrappedIdentity   AES-256-GCM(recoveryKey, iv, identityPrivBytes). Stored
///                     server-side so a new device can restore by re-entering
///                     the phrase.
///   roomKey           32-byte symmetric key per E2E room. Owner generates;
///                     wrapped per-member via sealed box (X25519 ephemeral +
///                     HKDF-SHA256 + AES-GCM).
///   messageCiphertext AES-256-GCM(roomKey, iv, plaintext). iv is 12 random
///                     bytes per message. roomKey rotation bumps key_version.
class E2E {
  static final X25519 _x25519 = X25519();
  static final AesGcm _aesGcm = AesGcm.with256bits();
  static const int _gcmIvLen = 12;

  // ---- identity key pair -------------------------------------------------

  static Future<IdentityKeyPair> generateIdentity() async {
    final kp = await _x25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    final priv = await kp.extractPrivateKeyBytes();
    return IdentityKeyPair(
      publicKey: Uint8List.fromList(pub.bytes),
      privateKey: Uint8List.fromList(priv),
    );
  }

  // ---- recovery key derivation -------------------------------------------

  /// Derive the 32-byte recovery key from a phrase seed + per-user salt.
  /// PBKDF2-HMAC-SHA512, 200k iterations. The salt is published alongside the
  /// wrapped identity key so any device can re-derive given the phrase.
  static Future<Uint8List> deriveRecoveryKey({
    required Uint8List phraseSeed,
    required Uint8List salt,
  }) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha512(),
      iterations: 200000,
      bits: 256,
    );
    final secret = SecretKey(phraseSeed);
    final key = await pbkdf2.deriveKey(
      secretKey: secret,
      nonce: salt,
    );
    final bytes = await key.extractBytes();
    return Uint8List.fromList(bytes);
  }

  static Uint8List newRecoverySalt() => _randomBytes(16);

  // ---- AES-GCM wrap of a private key --------------------------------------

  static Future<WrappedBlob> wrapWithKey({
    required Uint8List key,
    required Uint8List plaintext,
    Uint8List? aad,
  }) async {
    final iv = _randomBytes(_gcmIvLen);
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: iv,
      aad: aad ?? const <int>[],
    );
    final ct = Uint8List(box.cipherText.length + box.mac.bytes.length);
    ct.setAll(0, box.cipherText);
    ct.setAll(box.cipherText.length, box.mac.bytes);
    return WrappedBlob(iv: iv, ciphertext: ct);
  }

  static Future<Uint8List> unwrapWithKey({
    required Uint8List key,
    required WrappedBlob blob,
    Uint8List? aad,
  }) async {
    if (blob.ciphertext.length < 16) {
      throw const FormatException('ciphertext too short for AES-GCM tag');
    }
    final ctLen = blob.ciphertext.length - 16;
    final ct = blob.ciphertext.sublist(0, ctLen);
    final mac = Mac(blob.ciphertext.sublist(ctLen));
    final box = SecretBox(ct, nonce: blob.iv, mac: mac);
    final pt = await _aesGcm.decrypt(
      box,
      secretKey: SecretKey(key),
      aad: aad ?? const <int>[],
    );
    return Uint8List.fromList(pt);
  }

  // ---- room key generation + sealed-box wrap for a recipient ------------

  static Uint8List newRoomKey() => _randomBytes(32);

  /// Wrap [roomKey] so only the holder of the private key matching
  /// [recipientPubKey] (X25519) can unwrap. Layout:
  ///   ephPub(32) || iv(12) || ct||tag
  /// Shared secret: X25519(eph_priv, recipient_pub). Derive 32-byte AES key
  /// via HKDF-SHA256(salt=ephPub||recipientPub, info="kirca-room-key-v1").
  static Future<Uint8List> sealRoomKey({
    required Uint8List recipientPubKey,
    required Uint8List roomKey,
  }) async {
    final ephKp = await _x25519.newKeyPair();
    final ephPub = await ephKp.extractPublicKey();
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephKp,
      remotePublicKey: SimplePublicKey(
        recipientPubKey,
        type: KeyPairType.x25519,
      ),
    );
    final wrapKey = await _hkdf(
      ikm: await shared.extractBytes(),
      salt: Uint8List.fromList([...ephPub.bytes, ...recipientPubKey]),
      info: utf8.encode('kirca-room-key-v1'),
      outLen: 32,
    );
    final wrapped = await wrapWithKey(key: wrapKey, plaintext: roomKey);
    final out = Uint8List(32 + _gcmIvLen + wrapped.ciphertext.length);
    out.setAll(0, ephPub.bytes);
    out.setAll(32, wrapped.iv);
    out.setAll(32 + _gcmIvLen, wrapped.ciphertext);
    return out;
  }

  static Future<Uint8List> openRoomKey({
    required Uint8List recipientPrivKey,
    required Uint8List recipientPubKey,
    required Uint8List sealed,
  }) async {
    if (sealed.length < 32 + _gcmIvLen + 16) {
      throw const FormatException('sealed room key too short');
    }
    final ephPub = sealed.sublist(0, 32);
    final iv = sealed.sublist(32, 32 + _gcmIvLen);
    final ct = sealed.sublist(32 + _gcmIvLen);
    final kp = SimpleKeyPairData(
      recipientPrivKey,
      publicKey: SimplePublicKey(recipientPubKey, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: kp,
      remotePublicKey: SimplePublicKey(ephPub, type: KeyPairType.x25519),
    );
    final wrapKey = await _hkdf(
      ikm: await shared.extractBytes(),
      salt: Uint8List.fromList([...ephPub, ...recipientPubKey]),
      info: utf8.encode('kirca-room-key-v1'),
      outLen: 32,
    );
    return unwrapWithKey(
      key: wrapKey,
      blob: WrappedBlob(iv: iv, ciphertext: ct),
    );
  }

  // ---- DM pairing key (deterministic, derived from both identities) ------

  /// Derive the symmetric AES-256 key for a 1:1 (DM) room straight from the
  /// two members' X25519 identity keys — no sealed envelope, no server
  /// round-trip, no "one side holds the key" race.
  ///
  /// Both peers compute the identical key because:
  ///   * the X25519 shared secret is symmetric:
  ///       X25519(myPriv, peerPub) == X25519(peerPriv, myPub)
  ///   * the HKDF salt is the two public keys in a canonical (sorted) order,
  ///     so it doesn't matter which side is "me".
  ///
  /// Requires the peer to have published their identity public key; callers
  /// that can't fetch it should treat the DM key as unavailable (the user
  /// needs E2E set up on both ends first).
  static Future<Uint8List> deriveDmKey({
    required Uint8List myPrivateKey,
    required Uint8List myPublicKey,
    required Uint8List peerPublicKey,
  }) async {
    final kp = SimpleKeyPairData(
      myPrivateKey,
      publicKey: SimplePublicKey(myPublicKey, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: kp,
      remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
    );
    final lo = _compareBytes(myPublicKey, peerPublicKey) <= 0;
    final salt = <int>[
      ...(lo ? myPublicKey : peerPublicKey),
      ...(lo ? peerPublicKey : myPublicKey),
    ];
    return _hkdf(
      ikm: await shared.extractBytes(),
      salt: salt,
      info: utf8.encode('kirca-dm-pairing-v1'),
      outLen: 32,
    );
  }

  /// Lexicographic compare of two byte strings. Returns <0, 0, or >0.
  static int _compareBytes(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  // ---- message encryption ------------------------------------------------

  static Future<MessageCipher> encryptMessage({
    required Uint8List roomKey,
    required String plaintext,
  }) async {
    final blob = await wrapWithKey(
      key: roomKey,
      plaintext: Uint8List.fromList(utf8.encode(plaintext)),
    );
    return MessageCipher(iv: blob.iv, ciphertext: blob.ciphertext);
  }

  static Future<String> decryptMessage({
    required Uint8List roomKey,
    required MessageCipher cipher,
  }) async {
    final pt = await unwrapWithKey(
      key: roomKey,
      blob: WrappedBlob(iv: cipher.iv, ciphertext: cipher.ciphertext),
    );
    return utf8.decode(pt);
  }

  // ---- attachment encryption: per-blob key, wrapped with room key --------

  static Future<AttachmentCipher> encryptAttachment({
    required Uint8List roomKey,
    required Uint8List bytes,
  }) async {
    final perBlobKey = _randomBytes(32);
    final body = await wrapWithKey(key: perBlobKey, plaintext: bytes);
    final wrappedKey = await wrapWithKey(key: roomKey, plaintext: perBlobKey);
    return AttachmentCipher(
      ciphertext: body.ciphertext,
      iv: body.iv,
      wrappedKey: wrappedKey.ciphertext,
      wrappedKeyIv: wrappedKey.iv,
    );
  }

  static Future<Uint8List> decryptAttachment({
    required Uint8List roomKey,
    required AttachmentCipher cipher,
  }) async {
    final perBlobKey = await unwrapWithKey(
      key: roomKey,
      blob: WrappedBlob(iv: cipher.wrappedKeyIv, ciphertext: cipher.wrappedKey),
    );
    return unwrapWithKey(
      key: perBlobKey,
      blob: WrappedBlob(iv: cipher.iv, ciphertext: cipher.ciphertext),
    );
  }

  // ---- helpers -----------------------------------------------------------

  static Future<Uint8List> _hkdf({
    required List<int> ikm,
    required List<int> salt,
    required List<int> info,
    required int outLen,
  }) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: outLen);
    final key = await hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: salt,
      info: info,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  static Uint8List _randomBytes(int n) {
    // SecretKeyData.random uses the platform CSPRNG.
    return Uint8List.fromList(SecretKeyData.random(length: n).bytes);
  }
}

class IdentityKeyPair {
  final Uint8List publicKey; // 32 bytes
  final Uint8List privateKey; // 32 bytes
  const IdentityKeyPair({required this.publicKey, required this.privateKey});
}

class WrappedBlob {
  final Uint8List iv;
  final Uint8List ciphertext; // includes 16-byte GCM tag at the end
  const WrappedBlob({required this.iv, required this.ciphertext});
}

class MessageCipher {
  final Uint8List iv;
  final Uint8List ciphertext;
  const MessageCipher({required this.iv, required this.ciphertext});

  String get ivB64 => base64Encode(iv);
  String get ctB64 => base64Encode(ciphertext);

  factory MessageCipher.fromB64({required String iv, required String ct}) =>
      MessageCipher(
        iv: Uint8List.fromList(base64Decode(iv)),
        ciphertext: Uint8List.fromList(base64Decode(ct)),
      );
}

class AttachmentCipher {
  final Uint8List ciphertext;
  final Uint8List iv;
  final Uint8List wrappedKey;
  final Uint8List wrappedKeyIv;
  const AttachmentCipher({
    required this.ciphertext,
    required this.iv,
    required this.wrappedKey,
    required this.wrappedKeyIv,
  });
}
