/// Fuzzy NAS-file matcher for the infinite queue (Spotify/YT-Music "prefer the
/// local copy" behavior).
///
/// The queue generates internet candidates ("Artist - Title" from the server's
/// Deezer-backed radio/recommend); before resolving + streaming one we ask
/// whether the same song already lives on the NAS. File names are dirty
/// ("Artist - Title (feat X).mp3", "artist  -  Title (2017 Remaster)") while
/// the candidate is clean, so plain equality misses most hits. This class
/// builds a small in-memory index over the server's `/api/tracks` list and
/// returns the best fuzzy match per candidate, with a confidence score.
library;

import 'text_norm.dart';

/// One NAS track as the server reports it (/api/tracks row).
class TracksRow {
  final String baseName;
  final String url;
  final String folder;
  TracksRow({
    required this.baseName,
    required this.url,
    this.folder = '',
  });

  factory TracksRow.fromJson(Map<String, dynamic> j) => TracksRow(
    baseName: (j['base_name'] ?? '').toString(),
    url: (j['url'] ?? '').toString(),
    folder: (j['folder'] ?? '').toString(),
  );
}

/// A matched NAS track: which file + how confident the algorithm is.
class NasMatch {
  final TracksRow track;
  final String matchedArtist;
  final String matchedTitle;
  final double score;
  final String? albumImage;
  NasMatch({
    required this.track,
    required this.matchedArtist,
    required this.matchedTitle,
    required this.score,
    this.albumImage,
  });

  /// A stable key for dedup ("artist\x00title", both folded).
  String get key => '${normArtist(matchedArtist)}\x00${normCore(matchedTitle)}';
}

/// In-memory index of the NAS library used to detect "this internet track is
/// already on the NAS" even when the file name varies.
class NasIndex {
  /// base name -> (artist, title) parts split on the first ' - '.
  final List<TracksRow> rows;
  final Map<String, (String, String)> _split = {};

  static final _extRe = RegExp(r'\.(?:mp3|flac|m4a|ogg|opus|wav|aac|wma)$',
      caseSensitive: false);

  NasIndex(List<TracksRow> all)
      : rows = List.of(all) {
    for (final r in rows) {
      final i = r.baseName.indexOf(' - ');
      if (i > 0) {
        var title = r.baseName.substring(i + 3).trim();
        title = title.replaceAll(_extRe, '');
        _split[r.baseName] = (r.baseName.substring(0, i).trim(), title);
      } else {
        _split[r.baseName] = ('', r.baseName.replaceAll(_extRe, ''));
      }
    }
  }

  factory NasIndex.fromJson(dynamic payload) {
    final list = <TracksRow>[];
    if (payload is List) {
      for (final e in payload) {
        if (e is Map<String, dynamic> && e.isNotEmpty) {
          list.add(TracksRow.fromJson(e));
        } else if (e is Map && e.isNotEmpty) {
          list.add(TracksRow.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    } else if (payload is Map && payload['tracks'] is List) {
      for (final e in payload['tracks'] as List) {
        if (e is Map<String, dynamic> && e.isNotEmpty) {
          list.add(TracksRow.fromJson(e));
        } else if (e is Map && e.isNotEmpty) {
          list.add(TracksRow.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    return NasIndex(list);
  }

  int get length => rows.length;
  bool get isEmpty => rows.isEmpty;

  /// Best fuzzy match for an [artist]+[title], or null when nothing clears
  /// [minScore]. [songSimilarity] (0..1) drives the decision; see docs.
  NasMatch? findBestMatch(
    String artist,
    String title, {
    double minScore = 0.72,
  }) {
    final qArtist = normArtist(artist);
    final qTitle = normCore(title);
    if (qArtist.isEmpty && qTitle.isEmpty) return null;

    TracksRow? best;
    double bestScore = 0;
    String? bestArtist;
    String? bestTitle;

    for (final r in rows) {
      final (ra, rt) = _split[r.baseName]!;
      // Folded artist prefilter: skip rows whose artist has no relationship
      // unless the query has no artist at all.
      final na = normArtist(ra);
      if (qArtist.isNotEmpty && na.isNotEmpty) {
        final ok = na == qArtist ||
            na.contains(qArtist) ||
            qArtist.contains(na) ||
            tokenJaccard(qArtist, na) >= 0.5;
        if (!ok) continue;
      }
      final score = songSimilarity(
        artistA: ra,
        titleA: rt,
        artistB: artist,
        titleB: title,
      );
      // Artist bonus: exact fold adds a win on top of title-only matches so
      // "same title, different band" doesn't false-positive.
      var s = score;
      if (na.isNotEmpty &&
          (na == qArtist || qArtist == na || qArtist.contains(na) ||
           na.contains(qArtist))) {
        s = s * 1.15 + 0.05;
      }
      if (s > bestScore) {
        bestScore = s;
        best = r;
        bestArtist = ra;
        bestTitle = rt;
      }
    }
    if (best == null || bestScore < minScore) return null;
    return NasMatch(
      track: best,
      matchedArtist: bestArtist ?? '',
      matchedTitle: bestTitle ?? '',
      score: bestScore,
    );
  }
}