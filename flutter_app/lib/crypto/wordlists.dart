import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

/// Loader for the 24 per-book recovery-phrase wordlists.
///
/// Each wordlist has exactly 512 entries (9 bits of entropy per word). The
/// position of a word in the phrase identifies its book; the index inside that
/// book's list is the entropy contribution. See [PhraseSpec] for the binding
/// between word position and book.
class Wordlists {
  static List<List<String>>? _lists;
  static List<Map<String, int>>? _lookup;
  static PhraseSpec? _spec;

  /// Replaces the embedded asset loader. Used by tests that don't ship the
  /// Flutter asset bundle. After calling this, [load] returns immediately
  /// with the injected data.
  static void setForTesting({
    required PhraseSpec spec,
    required List<List<String>> lists,
  }) {
    if (lists.length != spec.bookCount) {
      throw ArgumentError('lists.length=${lists.length}, expected ${spec.bookCount}');
    }
    for (var i = 0; i < lists.length; i++) {
      if (lists[i].length != spec.listSize) {
        throw ArgumentError(
          'list[$i] has ${lists[i].length} words, expected ${spec.listSize}',
        );
      }
    }
    _spec = spec;
    _lists = lists;
    _lookup = lists.map((l) {
      final m = <String, int>{};
      for (var i = 0; i < l.length; i++) {
        m[l[i]] = i;
      }
      return m;
    }).toList(growable: false);
  }

  /// Clears any state set via [setForTesting]. Real bundle is re-read lazily.
  static void resetForTesting() {
    _lists = null;
    _lookup = null;
    _spec = null;
  }

  static Future<void> _ensureLoaded() async {
    if (_lists != null) return;
    final manifestRaw = await rootBundle.loadString('assets/bible/manifest.json');
    final manifest = jsonDecode(manifestRaw) as Map<String, dynamic>;
    final books = (manifest['books'] as List).cast<Map<String, dynamic>>();
    final spec = PhraseSpec(
      wordCount: (manifest['phrase_word_count'] as num).toInt(),
      bitsPerWord: (manifest['bits_per_word'] as num).toInt(),
      listSize: (manifest['list_size'] as num).toInt(),
      books: books
          .map((b) => BookInfo(
                idx: (b['idx'] as num).toInt(),
                name: b['name'] as String,
                slug: b['slug'] as String,
              ))
          .toList(growable: false),
    );
    final lists = <List<String>>[];
    final lookup = <Map<String, int>>[];
    for (final b in books) {
      final txt = await rootBundle.loadString('assets/bible/${b['file']}');
      final ws = txt.split('\n').where((s) => s.isNotEmpty).toList(growable: false);
      if (ws.length != spec.listSize) {
        throw StateError('asset ${b['file']} has ${ws.length} words, expected ${spec.listSize}');
      }
      lists.add(ws);
      final m = <String, int>{};
      for (var i = 0; i < ws.length; i++) {
        m[ws[i]] = i;
      }
      lookup.add(m);
    }
    _spec = spec;
    _lists = lists;
    _lookup = lookup;
  }

  static Future<PhraseSpec> spec() async {
    await _ensureLoaded();
    return _spec!;
  }

  static Future<List<String>> bookList(int bookIdx) async {
    await _ensureLoaded();
    return _lists![bookIdx];
  }

  /// Index of [word] in [bookIdx]'s wordlist, or -1 if absent.
  static Future<int> indexOf(int bookIdx, String word) async {
    await _ensureLoaded();
    return _lookup![bookIdx][word.trim().toLowerCase()] ?? -1;
  }

  /// All books, in canonical order.
  static Future<List<BookInfo>> books() async {
    await _ensureLoaded();
    return _spec!.books;
  }
}

class PhraseSpec {
  final int wordCount;
  final int bitsPerWord;
  final int listSize;
  final List<BookInfo> books;
  const PhraseSpec({
    required this.wordCount,
    required this.bitsPerWord,
    required this.listSize,
    required this.books,
  });
  int get bookCount => books.length;
  int get totalBits => wordCount * bitsPerWord;
}

class BookInfo {
  final int idx;
  final String name;
  final String slug;
  const BookInfo({required this.idx, required this.name, required this.slug});
}
