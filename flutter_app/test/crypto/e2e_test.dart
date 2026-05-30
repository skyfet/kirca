import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirca/crypto/e2e.dart';

void main() {
  group('E2E identity + recovery', () {
    test('generateIdentity returns 32-byte X25519 keys', () async {
      final id = await E2E.generateIdentity();
      expect(id.publicKey.length, 32);
      expect(id.privateKey.length, 32);
    });

    test('deriveRecoveryKey is deterministic for same seed+salt', () async {
      final seed = Uint8List.fromList(List<int>.generate(27, (i) => i));
      final salt = Uint8List.fromList(List<int>.generate(16, (i) => i * 7));
      final a = await E2E.deriveRecoveryKey(phraseSeed: seed, salt: salt);
      final b = await E2E.deriveRecoveryKey(phraseSeed: seed, salt: salt);
      expect(a, b);
      expect(a.length, 32);
    });

    test('deriveRecoveryKey changes with a different salt', () async {
      final seed = Uint8List.fromList(List<int>.generate(27, (i) => i));
      final salt1 = Uint8List(16);
      final salt2 = Uint8List(16)..[0] = 1;
      final a = await E2E.deriveRecoveryKey(phraseSeed: seed, salt: salt1);
      final b = await E2E.deriveRecoveryKey(phraseSeed: seed, salt: salt2);
      expect(a, isNot(equals(b)));
    });

    test('wrap then unwrap round-trips an identity private key', () async {
      final id = await E2E.generateIdentity();
      final seed = Uint8List.fromList(List<int>.generate(27, (i) => i + 1));
      final salt = E2E.newRecoverySalt();
      final recoveryKey = await E2E.deriveRecoveryKey(
        phraseSeed: seed,
        salt: salt,
      );
      final wrapped = await E2E.wrapWithKey(
        key: recoveryKey,
        plaintext: id.privateKey,
      );
      final unwrapped = await E2E.unwrapWithKey(
        key: recoveryKey,
        blob: wrapped,
      );
      expect(unwrapped, id.privateKey);
    });

    test('wrong recovery key fails to unwrap (auth tag mismatch)', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final wrong = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final wrapped = await E2E.wrapWithKey(
        key: key,
        plaintext: Uint8List.fromList(const [1, 2, 3, 4]),
      );
      expect(
        () => E2E.unwrapWithKey(key: wrong, blob: wrapped),
        throwsA(anything),
      );
    });
  });

  group('Room key sealing', () {
    test('only the recipient can open the sealed room key', () async {
      final alice = await E2E.generateIdentity();
      final bob = await E2E.generateIdentity();
      final roomKey = E2E.newRoomKey();
      final sealed = await E2E.sealRoomKey(
        recipientPubKey: bob.publicKey,
        roomKey: roomKey,
      );

      final opened = await E2E.openRoomKey(
        recipientPrivKey: bob.privateKey,
        recipientPubKey: bob.publicKey,
        sealed: sealed,
      );
      expect(opened, roomKey);

      await expectLater(
        E2E.openRoomKey(
          recipientPrivKey: alice.privateKey,
          recipientPubKey: alice.publicKey,
          sealed: sealed,
        ),
        throwsA(anything),
      );
    });
  });

  group('DM pairing key', () {
    test('both peers derive the IDENTICAL key (symmetry)', () async {
      final alice = await E2E.generateIdentity();
      final bob = await E2E.generateIdentity();

      final aliceSide = await E2E.deriveDmKey(
        myPrivateKey: alice.privateKey,
        myPublicKey: alice.publicKey,
        peerPublicKey: bob.publicKey,
      );
      final bobSide = await E2E.deriveDmKey(
        myPrivateKey: bob.privateKey,
        myPublicKey: bob.publicKey,
        peerPublicKey: alice.publicKey,
      );

      expect(aliceSide.length, 32);
      expect(aliceSide, bobSide);
    });

    test('derivation is deterministic across calls', () async {
      final alice = await E2E.generateIdentity();
      final bob = await E2E.generateIdentity();
      final first = await E2E.deriveDmKey(
        myPrivateKey: alice.privateKey,
        myPublicKey: alice.publicKey,
        peerPublicKey: bob.publicKey,
      );
      final second = await E2E.deriveDmKey(
        myPrivateKey: alice.privateKey,
        myPublicKey: alice.publicKey,
        peerPublicKey: bob.publicKey,
      );
      expect(first, second);
    });

    test('different peer pairs derive different keys', () async {
      final alice = await E2E.generateIdentity();
      final bob = await E2E.generateIdentity();
      final carol = await E2E.generateIdentity();

      final ab = await E2E.deriveDmKey(
        myPrivateKey: alice.privateKey,
        myPublicKey: alice.publicKey,
        peerPublicKey: bob.publicKey,
      );
      final ac = await E2E.deriveDmKey(
        myPrivateKey: alice.privateKey,
        myPublicKey: alice.publicKey,
        peerPublicKey: carol.publicKey,
      );
      expect(ab, isNot(equals(ac)));
    });

    test('a message encrypted by one peer decrypts for the other', () async {
      final alice = await E2E.generateIdentity();
      final bob = await E2E.generateIdentity();

      final aliceKey = await E2E.deriveDmKey(
        myPrivateKey: alice.privateKey,
        myPublicKey: alice.publicKey,
        peerPublicKey: bob.publicKey,
      );
      final bobKey = await E2E.deriveDmKey(
        myPrivateKey: bob.privateKey,
        myPublicKey: bob.publicKey,
        peerPublicKey: alice.publicKey,
      );

      const plaintext = 'парный ключ работает 🔑';
      final cipher =
          await E2E.encryptMessage(roomKey: aliceKey, plaintext: plaintext);
      final decrypted =
          await E2E.decryptMessage(roomKey: bobKey, cipher: cipher);
      expect(decrypted, plaintext);
    });
  });

  group('Message encryption', () {
    test('round-trip plaintext', () async {
      final roomKey = E2E.newRoomKey();
      final cipher = await E2E.encryptMessage(
        roomKey: roomKey,
        plaintext: 'привет, мир — hello 🌍',
      );
      final decoded = await E2E.decryptMessage(roomKey: roomKey, cipher: cipher);
      expect(decoded, 'привет, мир — hello 🌍');
    });

    test('different IV per encryption', () async {
      final roomKey = E2E.newRoomKey();
      final a = await E2E.encryptMessage(roomKey: roomKey, plaintext: 'hello');
      final b = await E2E.encryptMessage(roomKey: roomKey, plaintext: 'hello');
      expect(a.iv, isNot(equals(b.iv)));
      expect(a.ciphertext, isNot(equals(b.ciphertext)));
    });

    test('b64 round-trip through MessageCipher.fromB64', () async {
      final roomKey = E2E.newRoomKey();
      final c = await E2E.encryptMessage(roomKey: roomKey, plaintext: 'hi');
      final r = MessageCipher.fromB64(iv: c.ivB64, ct: c.ctB64);
      expect(r.iv, c.iv);
      expect(r.ciphertext, c.ciphertext);
    });
  });

  group('Attachment encryption', () {
    test('round-trip image-sized blob', () async {
      final roomKey = E2E.newRoomKey();
      final bytes = Uint8List(64 * 1024);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = i & 0xff;
      }
      final cipher = await E2E.encryptAttachment(
        roomKey: roomKey,
        bytes: bytes,
      );
      expect(cipher.ciphertext.length, bytes.length + 16); // + GCM tag
      final decoded = await E2E.decryptAttachment(
        roomKey: roomKey,
        cipher: cipher,
      );
      expect(decoded, bytes);
    });

    test('wrong room key fails to decrypt', () async {
      final roomKey = E2E.newRoomKey();
      final other = E2E.newRoomKey();
      final cipher = await E2E.encryptAttachment(
        roomKey: roomKey,
        bytes: Uint8List.fromList(const [1, 2, 3, 4, 5]),
      );
      await expectLater(
        E2E.decryptAttachment(roomKey: other, cipher: cipher),
        throwsA(anything),
      );
    });
  });
}
