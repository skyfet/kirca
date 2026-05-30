import 'package:flutter_test/flutter_test.dart';
import 'package:kirca/util/e2e_envelope.dart';

void main() {
  group('encodeE2eEnvelope', () {
    test('text-only stays raw for backward compat', () {
      expect(encodeE2eEnvelope(text: 'hello'), 'hello');
      expect(encodeE2eEnvelope(text: ''), '');
    });

    test('attachment metadata triggers envelope', () {
      final s = encodeE2eEnvelope(
        text: 'caption',
        blurhash: 'L6Pj0^jE',
        durationMs: 1500,
      );
      expect(s.startsWith('{'), isTrue);
      expect(s.contains(r'"$k":1'), isTrue);
      expect(s.contains('"t":"caption"'), isTrue);
      expect(s.contains('"bh":"L6Pj0^jE"'), isTrue);
      expect(s.contains('"d":1500'), isTrue);
    });
  });

  group('decodeE2eEnvelope', () {
    test('raw text falls through unchanged', () {
      final e = decodeE2eEnvelope('plain message');
      expect(e.text, 'plain message');
      expect(e.blurhash, isNull);
      expect(e.durationMs, isNull);
    });

    test('empty string is handled', () {
      final e = decodeE2eEnvelope('');
      expect(e.text, '');
      expect(e.blurhash, isNull);
    });

    test('user-typed JSON without magic is treated as raw text', () {
      const userJson = '{"hello":"world"}';
      final e = decodeE2eEnvelope(userJson);
      expect(e.text, userJson);
      expect(e.blurhash, isNull);
    });

    test('round-trip preserves attachment metadata', () {
      final wire = encodeE2eEnvelope(
        text: 'hi',
        blurhash: 'L6Pj0^jE',
        durationMs: 2400,
      );
      final e = decodeE2eEnvelope(wire);
      expect(e.text, 'hi');
      expect(e.blurhash, 'L6Pj0^jE');
      expect(e.durationMs, 2400);
    });

    test('partial metadata round-trips', () {
      final wireBh = encodeE2eEnvelope(text: '', blurhash: 'L6Pj0^jE');
      final eBh = decodeE2eEnvelope(wireBh);
      expect(eBh.text, '');
      expect(eBh.blurhash, 'L6Pj0^jE');
      expect(eBh.durationMs, isNull);

      final wireDur = encodeE2eEnvelope(text: 'voice', durationMs: 800);
      final eDur = decodeE2eEnvelope(wireDur);
      expect(eDur.text, 'voice');
      expect(eDur.blurhash, isNull);
      expect(eDur.durationMs, 800);
    });

    test('malformed JSON is treated as raw text (no crash)', () {
      const broken = '{not valid json';
      final e = decodeE2eEnvelope(broken);
      expect(e.text, broken);
    });
  });
}
