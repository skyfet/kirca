import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirca/crypto/phrase.dart';
import 'package:kirca/crypto/wordlists.dart';

PhraseSpec _spec() => PhraseSpec(
      wordCount: 24,
      bitsPerWord: 9,
      listSize: 512,
      books: List<BookInfo>.generate(
        24,
        (i) => BookInfo(idx: i, name: 'Book$i', slug: 'book_$i'),
      ),
    );

List<List<String>> _lists() {
  // Synthetic 24 × 512 wordlists: words are unique per (book, index) so we can
  // unambiguously verify positional decoding.
  return List<List<String>>.generate(24, (b) {
    return List<String>.generate(512, (i) => 'b${b}w$i', growable: false);
  }, growable: false);
}

void main() {
  setUp(() {
    Wordlists.setForTesting(spec: _spec(), lists: _lists());
  });
  tearDown(Wordlists.resetForTesting);

  group('Phrase', () {
    test('generate yields 24 words, one from each book', () async {
      final phrase = await Phrase.generate();
      expect(phrase.length, 24);
      for (var i = 0; i < 24; i++) {
        expect(phrase[i], startsWith('b${i}w'));
      }
    });

    test('toSeed → fromSeed round-trips', () async {
      final phrase = await Phrase.generate();
      final seed = await Phrase.toSeed(phrase);
      expect(seed.length, 27); // 216 bits packed
      final decoded = await Phrase.fromSeed(seed);
      expect(decoded, phrase);
    });

    test('toSeed packs bits in big-endian order per word', () async {
      // All words index 0 → seed is all zero bytes.
      final allZero = List<String>.generate(24, (b) => 'b${b}w0');
      expect(await Phrase.toSeed(allZero), Uint8List(27));

      // All words index 511 (binary 111111111) → all bits set.
      final allOnes = List<String>.generate(24, (b) => 'b${b}w511');
      final seed = await Phrase.toSeed(allOnes);
      expect(seed.length, 27);
      for (var i = 0; i < 27; i++) {
        expect(seed[i], 0xff);
      }
    });

    test('toSeed rejects wrong word count', () async {
      await expectLater(
        Phrase.toSeed(const ['b0w0']),
        throwsA(isA<PhraseException>()),
      );
    });

    test('toSeed rejects word from wrong book', () async {
      // b0w5 is valid at position 0 but invalid at position 1.
      final bad = List<String>.generate(24, (b) => 'b${b}w0');
      bad[1] = 'b0w5';
      await expectLater(
        Phrase.toSeed(bad),
        throwsA(isA<PhraseException>().having(
          (e) => e.wordPosition,
          'wordPosition',
          1,
        )),
      );
    });

    test('toSeed accepts uppercase + whitespace, normalizes', () async {
      final phrase = List<String>.generate(24, (b) => '  B${b}W0  ');
      final seed = await Phrase.toSeed(phrase);
      expect(seed, Uint8List(27));
    });

    test('parse splits on any whitespace', () {
      final got = Phrase.parse('  Foo  bar\nbaz\tqux  ');
      expect(got, ['foo', 'bar', 'baz', 'qux']);
    });

    test('format produces 4 lines of 6 words', () async {
      final phrase = await Phrase.generate();
      final lines = Phrase.format(phrase).split('\n');
      expect(lines.length, 4);
      for (final line in lines) {
        expect(line.split(' ').length, 6);
      }
    });
  });
}
