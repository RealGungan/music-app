/// Pure-Dart text normalization + similarity helpers for the infinite-queue
/// algorithm (Spotify/YT-Music style "up next").
///
/// Mirrors the server's `norm()`/`_norm_core()` folding so that an app-side
/// fuzzy match agrees with `/api/innas`: NFKD-style accent stripping, lower-
/// casing, dropping parenthesized tags like "(2017 Remaster)" and collapsing
/// "feat."/"ft." joiners. Everything here is dependency-free so it can be
/// unit-tested without a device.
library;

/// Fold [s] like the server's `norm()`: strip diacritics, lowercase, drop
/// anything that is not a letter, digit or space (spaces are kept so token
/// sets still split afterwards), then collapse whitespace and trim.
String norm(String s) {
  return _stripDiacritics(s)
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Like [norm] but also removes bracketed/parenthesized tags first
/// ("(2017 Remaster)", "[feat. X]", "{live}") — the common NAS-name
/// variation that breaks exact matches.
String normCore(String s) {
  final cleaned = s.replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]|\{[^}]*\}'), ' ');
  return norm(cleaned);
}

/// Server-compatible norm (mirrors scorer.py norm()): NFKD diacritics,
/// lowercase, drop EVERYTHING but [a-z0-9] (no spaces). The server's
/// radio/recommend exclude-set compares against this exact shape — the
/// local norm() keeps spaces and never matches, which silently disabled
/// exclusion (same ~9 songs forever).
String normServer(String s) {
  return _stripDiacritics(s)
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), '');
}

/// Title-only server norm for an "Artist - Title" row (or a bare title).
String excludeNorm(String fullTitle) {
  final i = fullTitle.indexOf(' - ');
  final t = i > 0 ? fullTitle.substring(i + 3) : fullTitle;
  return normServer(t);
}

/// Artist-only core: strips "feat.", "ft", "with", "&" and everything after,
/// then applies [normCore]. Turns "Metallica (Ft. Jason Newsted)" and
/// "Metallica & Symphony" both into "metallica".
String normArtist(String s) {
  final noFeat =
      s.split(
            RegExp(r'\s*(?:feat(?:\.|uring)?|ft\.?|with)\s*',
                caseSensitive: false),
          )
          .first;
  final noJoin = noFeat.split(RegExp(r'\s*&\s*')).first;
  return normCore(noJoin);
}

/// Tokenized word set of [s] (after [norm]).
Set<String> normTokens(String s) {
  return norm(s).split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toSet();
}

/// Jaccard similarity of the token sets (0..1).
double tokenJaccard(String a, String b) {
  final ta = normTokens(a);
  final tb = normTokens(b);
  if (ta.isEmpty && tb.isEmpty) return 1.0;
  if (ta.isEmpty || tb.isEmpty) return 0.0;
  final inter = ta.intersection(tb).length;
  return inter / ta.union(tb).length;
}

/// Title similarity (0..1): exact fold = 1.0, word-subset containment = 0.85,
/// otherwise token Jaccard. Good enough to catch "In Da Club" vs
/// "In da club (feat.)" and "The Unforgiven II" vs "The Unforgiven II (Live)".
double titleSimilarity(String a, String b) {
  final na = normCore(a);
  final nb = normCore(b);
  if (na.isEmpty || nb.isEmpty) return 0.0;
  if (na == nb) return 1.0;
  final ta = na.split(RegExp(r'\s+')).toSet();
  final tb = nb.split(RegExp(r'\s+')).toSet();
  if (ta.isNotEmpty && tb.isNotEmpty &&
      (ta.containsAll(tb) || tb.containsAll(ta))) {
    return 0.85;
  }
  return tokenJaccard(a, b) * 0.8;
}

/// Artist similarity (0..1): folded equality = 1.0, containment = 0.75,
/// otherwise token Jaccard.
double artistSimilarity(String a, String b) {
  final na = normArtist(a);
  final nb = normArtist(b);
  if (na.isEmpty || nb.isEmpty) return 0.0;
  if (na == nb) return 1.0;
  if (na.contains(nb) || nb.contains(na)) return 0.75;
  return tokenJaccard(a, b) * 0.5;
}

/// Combined identity similarity for "is this the same song?" decisions.
/// Title weighs more than artist (title uniqueness dominates).
double songSimilarity({
  required String artistA,
  required String titleA,
  required String artistB,
  required String titleB,
}) {
  final t = titleSimilarity(titleA, titleB);
  final a = artistSimilarity(artistA, artistB);
  if (t == 0 && a == 0) return 0.0;
  // Rows without an artist separator (whole filename is the title): no artist
  // to compare, so the title alone decides — otherwise a 0.0 artist term
  // drags an exact title match below the match threshold.
  if (artistA.trim().isEmpty && artistB.trim().isEmpty) return t;
  return t * 0.6 + a * 0.4;
}

String _stripDiacritics(String s) {
  final buf = StringBuffer();
  for (final rune in s.runes) {
    buf.write(_accentFold[rune] ?? String.fromCharCode(rune));
  }
  return buf.toString();
}

const Map<int, String> _accentFold = {
  0xC0: 'A', 0xC1: 'A', 0xC2: 'A', 0xC3: 'A', 0xC4: 'A', 0xC5: 'A',
  0xC7: 'C',
  0xC8: 'E', 0xC9: 'E', 0xCA: 'E', 0xCB: 'E',
  0xCC: 'I', 0xCD: 'I', 0xCE: 'I', 0xCF: 'I',
  0xD0: 'D',
  0xD1: 'N',
  0xD2: 'O', 0xD3: 'O', 0xD4: 'O', 0xD5: 'O', 0xD6: 'O', 0xD8: 'O',
  0xD9: 'U', 0xDA: 'U', 0xDB: 'U', 0xDC: 'U',
  0xDD: 'Y',
  0xDF: 'ss',
  0xE0: 'a', 0xE1: 'a', 0xE2: 'a', 0xE3: 'a', 0xE4: 'a', 0xE5: 'a', 0xE6: 'ae',
  0xE7: 'c',
  0xE8: 'e', 0xE9: 'e', 0xEA: 'e', 0xEB: 'e',
  0xEC: 'i', 0xED: 'i', 0xEE: 'i', 0xEF: 'i',
  0xF0: 'd',
  0xF1: 'n',
  0xF2: 'o', 0xF3: 'o', 0xF4: 'o', 0xF5: 'o', 0xF6: 'o', 0xF8: 'o',
  0xF9: 'u', 0xFA: 'u', 0xFB: 'u', 0xFC: 'u',
  0xFD: 'y', 0xFE: 'th', 0xFF: 'y',
};