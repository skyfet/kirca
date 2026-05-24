#!/usr/bin/env python3
"""Build the 24 per-book recovery-phrase wordlists from YLT.

A "recovery phrase" in kirca is 24 words: one drawn from each of 12 OT books and
12 NT books. The position of a word identifies its book; the word's index inside
that book's wordlist contributes 9 bits of entropy. 24 words = 216 bits.

The YLT (Young's Literal Translation, public domain, 1862/1898) is fetched from
a stable mirror of the public-domain text and reduced to 512 lowercase
alpha-only word-forms of length >= 4 per book, sorted alphabetically, first 512
taken. This script is deterministic: re-running on the same YLT JSON yields
byte-identical wordlists.

Outputs (relative to repo root):
  flutter_app/assets/bible/<NN>_<slug>.txt    one word per line, exactly 512
  flutter_app/assets/bible/manifest.json      { books: [{idx, name, slug, sha256}], list_size, min_word_len, source_sha256 }
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

# Stable mirror of the YLT JSON. If this 404s, swap the URL — the file format is
# {book: {chapter: {verse: text}}} keyed by canonical book names; any mirror
# matching that shape works.
YLT_URL = "https://raw.githubusercontent.com/Living-Word-Bibles/ylt-online/main/YLT/YLT_bible.json"

# Note: this JSON spells the 19th OT book "Psalm" (singular). We accept either.
BOOKS_ORDERED = [
    # 12 OT (Part 1: Torah+; Part 2: historical/poetic/prophets)
    ("Genesis",       "genesis"),
    ("Exodus",        "exodus"),
    ("Leviticus",     "leviticus"),
    ("Numbers",       "numbers"),
    ("Deuteronomy",   "deuteronomy"),
    ("Joshua",        "joshua"),
    ("Judges",        "judges"),
    ("1 Samuel",      "1_samuel"),
    ("2 Samuel",      "2_samuel"),
    ("1 Kings",       "1_kings"),
    ("Psalm",         "psalms"),
    ("Isaiah",        "isaiah"),
    # 12 NT (Part 3: Gospels+Acts+Romans; Part 4: Epistles+Revelation)
    ("Matthew",       "matthew"),
    ("Mark",          "mark"),
    ("Luke",          "luke"),
    ("John",          "john"),
    ("Acts",          "acts"),
    ("Romans",        "romans"),
    ("1 Corinthians", "1_corinthians"),
    ("2 Corinthians", "2_corinthians"),
    ("Galatians",     "galatians"),
    ("Ephesians",     "ephesians"),
    ("Hebrews",       "hebrews"),
    ("Revelation",    "revelation"),
]

LIST_SIZE = 512
MIN_WORD_LEN = 4
WORD_RE = re.compile(r"[A-Za-z]+")


def fetch_ylt(cache_path: Path) -> bytes:
    if cache_path.exists():
        return cache_path.read_bytes()
    req = urllib.request.Request(YLT_URL, headers={"User-Agent": "kirca-wordlist-builder/1"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read()
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_bytes(data)
    return data


def extract_words(book: dict) -> list[str]:
    uniq: set[str] = set()
    for _ch, verses in book.items():
        for _v, text in verses.items():
            for w in WORD_RE.findall(text):
                w = w.lower()
                if len(w) >= MIN_WORD_LEN:
                    uniq.add(w)
    return sorted(uniq)


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cache = repo_root / "scripts" / ".cache" / "ylt_bible.json"
    raw = fetch_ylt(cache)
    src_sha = hashlib.sha256(raw).hexdigest()
    bible = json.loads(raw)

    out_dir = repo_root / "flutter_app" / "assets" / "bible"
    out_dir.mkdir(parents=True, exist_ok=True)

    manifest_books = []
    for idx, (name, slug) in enumerate(BOOKS_ORDERED):
        if name not in bible:
            print(f"missing book: {name}", file=sys.stderr)
            return 1
        words = extract_words(bible[name])
        if len(words) < LIST_SIZE:
            print(f"{name}: only {len(words)} unique >= {MIN_WORD_LEN}-letter words, need {LIST_SIZE}", file=sys.stderr)
            return 1
        chosen = words[:LIST_SIZE]
        payload = "\n".join(chosen) + "\n"
        h = hashlib.sha256(payload.encode("utf-8")).hexdigest()
        fname = f"{idx:02d}_{slug}.txt"
        (out_dir / fname).write_text(payload, encoding="utf-8")
        manifest_books.append({
            "idx": idx,
            "name": name,
            "slug": slug,
            "file": fname,
            "sha256": h,
        })

    manifest = {
        "version": 1,
        "source": "YLT (Young's Literal Translation, 1862/1898, public domain)",
        "source_url": YLT_URL,
        "source_sha256": src_sha,
        "list_size": LIST_SIZE,
        "min_word_len": MIN_WORD_LEN,
        "phrase_word_count": 24,
        "bits_per_word": 9,  # log2(512)
        "books": manifest_books,
    }
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"wrote 24 wordlists + manifest.json to {out_dir.relative_to(repo_root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
