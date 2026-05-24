import 'dart:math';
import 'dart:typed_data';

import 'wordlists.dart';

class PhraseException implements Exception {
  final String message;
  final int? wordPosition; // 0-based
  PhraseException(this.message, {this.wordPosition});
  @override
  String toString() => message;
}

/// Recovery phrase codec.
///
/// A phrase is 24 words. Word at position `i` (0-based) is drawn from the
/// wordlist for the `i`-th book in [Wordlists.books]; its index inside that
/// list contributes 9 bits of entropy. Total: 24 * 9 = 216 bits, packed into
/// 27 bytes (big-endian, word-0 bits first).
class Phrase {
  /// Generate a fresh phrase from a CSPRNG. 216 bits of entropy.
  static Future<List<String>> generate() async {
    final spec = await Wordlists.spec();
    final r = Random.secure();
    final out = <String>[];
    for (var i = 0; i < spec.wordCount; i++) {
      final idx = r.nextInt(spec.listSize);
      final list = await Wordlists.bookList(i);
      out.add(list[idx]);
    }
    return out;
  }

  /// Pack a 24-word phrase into a 27-byte (216-bit) seed. Throws
  /// [PhraseException] if any word is missing from its book's list (positional:
  /// word #1 must be a Genesis word, etc.).
  static Future<Uint8List> toSeed(List<String> words) async {
    final spec = await Wordlists.spec();
    if (words.length != spec.wordCount) {
      throw PhraseException(
        'expected ${spec.wordCount} words, got ${words.length}',
      );
    }
    final totalBytes = (spec.totalBits + 7) ~/ 8;
    final out = Uint8List(totalBytes);
    var bitPos = 0;
    for (var i = 0; i < spec.wordCount; i++) {
      final w = words[i].trim().toLowerCase();
      final idx = await Wordlists.indexOf(i, w);
      if (idx < 0) {
        final book = (await Wordlists.books())[i].name;
        throw PhraseException(
          'word #${i + 1} "$w" is not in the $book wordlist',
          wordPosition: i,
        );
      }
      for (var b = spec.bitsPerWord - 1; b >= 0; b--) {
        if (((idx >> b) & 1) == 1) {
          out[bitPos >> 3] |= 1 << (7 - (bitPos & 7));
        }
        bitPos++;
      }
    }
    return out;
  }

  /// Decode a 27-byte seed back into 24 words. Used in tests and for
  /// re-deriving the canonical phrase form (lowercased, trimmed) from storage.
  static Future<List<String>> fromSeed(Uint8List seed) async {
    final spec = await Wordlists.spec();
    final totalBytes = (spec.totalBits + 7) ~/ 8;
    if (seed.length != totalBytes) {
      throw PhraseException(
        'seed must be $totalBytes bytes, got ${seed.length}',
      );
    }
    final out = <String>[];
    var bitPos = 0;
    for (var i = 0; i < spec.wordCount; i++) {
      var idx = 0;
      for (var b = 0; b < spec.bitsPerWord; b++) {
        final bit = (seed[bitPos >> 3] >> (7 - (bitPos & 7))) & 1;
        idx = (idx << 1) | bit;
        bitPos++;
      }
      final list = await Wordlists.bookList(i);
      out.add(list[idx]);
    }
    return out;
  }

  /// Canonical display string: lowercase words separated by single spaces,
  /// grouped into 4 lines of 6 for readability. The newline grouping is purely
  /// presentational; [toSeed] accepts any whitespace as a separator.
  static String format(List<String> words) {
    final buf = StringBuffer();
    for (var i = 0; i < words.length; i++) {
      if (i > 0) {
        buf.write(i % 6 == 0 ? '\n' : ' ');
      }
      buf.write(words[i]);
    }
    return buf.toString();
  }

  /// Parse user input. Accepts any whitespace separators; ignores empty tokens.
  static List<String> parse(String input) {
    return input
        .split(RegExp(r'\s+'))
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }
}
