/// The infinite-queue planning engine — mirrors how Spotify / YouTube Music
/// build and refill "Up Next".
///
/// Design (verified against the server's radio/recommend plumbing + the app's
/// existing autoplay):
///  * **Keep-ahead refill**: the queue always keeps `keepAhead` playable rows
///    ahead of the cursor. When the user consumes the playhead below
///    `refillWhen`, we top back up to `keepAhead` — NOT a fixed "+N when you
///    reach the 6th". Scrolling the queue sheet just pulls the same keeper.
///  * **Seed drift**: the seed for the *next* candidate batch is the
///    currently-playing track (not the original queue seed), so content
///    gradually orbits the music the user is actually listening to.
///  * **Repeat decay**: a strict title-dedup + a recently-played window
///    (mirrors `QueuePlayer._recentlyPlayed`) — you don't hear the same
///    song again until it's scrolled out of the window.
///  * **Artist cooldown**: don't stack 3+ rows from the same artist in a row
///    (deflates any single-artist run in the upstream candidate list).
///  * **Similarity-first + novelty mix**: the closest matches to the current
///    track come first (Spotify/YT open up-next with the most-related
///    tracks); less-related-but-fresh rows fill the gaps so it never feels
///    like a broken record.
library;

import 'dart:math';

import 'text_norm.dart';

/// A candidate pulled from the internet radio/recommend feed.
class RelatedCandidate {
  final String artist;
  final String title;
  final String? album;
  final String? albumImage;
  final String? albumArtist;
  final int? durationS;
  final bool isExplicit;
  final String? provider;
  const RelatedCandidate({
    required this.artist,
    required this.title,
    this.album,
    this.albumImage,
    this.albumArtist,
    this.durationS,
    this.isExplicit = false,
    this.provider,
  });

  factory RelatedCandidate.fromJson(Map<String, dynamic> j) =>
      RelatedCandidate(
        artist: (j['artist'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        album: j['album']?.toString(),
        albumImage: j['album_image']?.toString(),
        albumArtist: j['album_artist']?.toString(),
        durationS: j['duration_s'] is int ? j['duration_s'] as int : null,
        isExplicit: j['is_explicit'] == true,
        provider: j['provider']?.toString(),
      );

  /// Stable, normalization-insensitive identity for dedup.
  String get key => '${normArtist(artist)}\x00${normCore(title)}';
}

/// The result of asking the internet feed for the next batch.
class NextBatch {
  /// Ordered rows to append after the current playhead.
  final List<RelatedCandidate> rows;

  /// The seed we actually anchored on (usually the playing track).
  final RelatedCandidate seed;
  const NextBatch({required this.rows, required this.seed});
}

class QueuePlanner {
  QueuePlanner({
    this.keepAhead = 25,
    this.refillWhen = 10,
    this.recentWindow = 50,
    this.maxSameArtistRun = 2,
    this.similarityWeight = 0.7,
    Random? random,
  }) : _random = random ?? Random();

  /// Playable rows we keep buffered after the cursor.
  final int keepAhead;

  /// Below this remaining count we refill back up to [keepAhead].
  final int refillWhen;

  /// How many recently-played keys to remember for repeat-decay.
  final int recentWindow;

  /// Max consecutive rows from one artist before diversity kicks in.
  final int maxSameArtistRun;

  /// Blend: 0.7 = mostly similar-first, 0.3 novelty; 1.0 = pure similarity.
  final double similarityWeight;
  final Random _random;

  /// How many rows we need to append to fill back to [keepAhead].
  int needed(int remaining) {
    final want = keepAhead - remaining;
    return want < 0 ? 0 : want;
  }

  /// Should we refill right now? (remaining rows after the cursor.)
  bool shouldRefill(int remaining) => remaining <= refillWhen;

  /// Score a candidate against the seed; title similarity dominates.
  double _score(RelatedCandidate c, RelatedCandidate seed) {
    final t = titleSimilarity(c.title, seed.title);
    final a = c.artist.isNotEmpty && seed.artist.isNotEmpty
        ? artistSimilarity(c.artist, seed.artist)
        : 0.0;
    var s = similarityWeight * t + (1 - similarityWeight) * a;
    // Exact same-title-as-seed is almost certainly the same song; demote so
    // the CURRENT track never re-appears as "up next".
    if (t >= 1.0) s -= 0.35;
    if (s < 0) s = 0;
    return s;
  }

  /// Build the next batch of up to [maxRows] candidates.
  ///
  /// [candidates] is the fresh internet feed (already NAS-filtered upstream);
  /// [seed] is the track these are "related to" (USUALLY the playing track —
  /// the drift mechanism); [seen] are keys already in the queue this session
  /// and [recent] are the recently-played keys (bounded window) — both are
  /// used for repeat-decay. [queueTail] lists the artist keys of the last few
  /// queued rows so the run-length deflation can see what came right before.
  List<RelatedCandidate> pick({
    required List<RelatedCandidate> candidates,
    required RelatedCandidate seed,
    required Set<String> seen,
    required Set<String> recent,
    required List<String> queueTail,
    int? maxRows,
  }) {
    final excluded = {...seen, ...recent};
    final fresh = <RelatedCandidate>[];
    for (final c in candidates) {
      if (c.title.isEmpty) continue;
      if (excluded.contains(c.key)) continue;
      fresh.add(c);
    }
    if (fresh.isEmpty) return const [];

    final target = (maxRows ?? needed(0)).clamp(1, fresh.length);

    // Score each fresh row against the seed.
    final scored = fresh
        .map((c) => (imp: _score(c, seed), c: c))
        .toList()
      ..sort((a, b) => b.imp.compareTo(a.imp));

    // Split into lead (closest to seed) and rest (novelty).
    final mean =
        scored.fold<double>(0, (a, e) => a + e.imp) / scored.length;
    final lead = <RelatedCandidate>[];
    final rest = <RelatedCandidate>[];
    for (final e in scored) {
      (e.imp >= mean * 0.7 ? lead : rest).add(e.c);
    }

    final out = <RelatedCandidate>[];
    final run = <String>[]; // recent artist folds, for the run cap.

    bool runFull(RelatedCandidate c) {
      if (c.artist.isEmpty) return false;
      final na = normArtist(c.artist);
      var n = 0;
      for (final a in run.reversed) {
        if (a == na) {
          n++;
        } else {
          break;
        }
      }
      return n >= maxSameArtistRun;
    }

    RelatedCandidate? take(List<RelatedCandidate> pool) {
      for (var i = 0; i < pool.length; i++) {
        final c = pool[i];
        if (!runFull(c)) {
          pool.removeAt(i);
          return c;
        }
      }
      return null;
    }

    // Randomize: shuffle BOTH tiers so a refill for the same seed does not
    // return the same few closest tracks in the same order every time.
    // Interleave lead (closest) and rest (novelty) so "up next" opens related
    // but keeps drifting — weighted ~3:1 toward the closest matches.
    final leadPool = [...lead]..shuffle(_random);
    final restPool = [...rest]..shuffle(_random);
    // Seed the run with what was already queued ahead.
    run.addAll(queueTail.map(normArtist));

    var leadTaken = 0;
    while (out.length < target && (leadPool.isNotEmpty || restPool.isNotEmpty)) {
      // Prefer the lead tier but only 3 of every 4 picks, so novel-but-fresh
      // rows keep slipping in (diversity across refills + within one batch).
      final preferLead = leadPool.isNotEmpty &&
          (restPool.isEmpty || leadTaken < 3 || _random.nextDouble() < 0.25);
      var c = preferLead ? take(leadPool) : take(restPool);
      if (c == null && preferLead) c = take(restPool);
      if (c == null && !preferLead) c = take(leadPool);
      if (c == null) break;
      out.add(c);
      if (preferLead) {
        leadTaken++;
      } else {
        leadTaken = 0;
      }
      if (c.artist.isNotEmpty) run.add(normArtist(c.artist));
    }
    // If the artist cap blocked everything, relax it — but NEVER extend
    // an already-full run: a short batch (refilled again on the next
    // advance, with a drifted seed) beats an 8-Marea run. Only when a
    // pool holds nothing else at all may the run grow.
    bool runExtend(RelatedCandidate c) {
      if (c.artist.isEmpty) return false;
      final na = normArtist(c.artist);
      var n = 0;
      for (final a in run.reversed) {
        if (a == na) {
          n++;
        } else {
          break;
        }
      }
      return n >= maxSameArtistRun;
    }

    void addRelaxed(RelatedCandidate c) {
      out.add(c);
      if (c.artist.isNotEmpty) run.add(normArtist(c.artist));
    }

    if (out.length < target) {
      while (out.length < target && leadPool.isNotEmpty) {
        final c = leadPool.removeAt(0);
        if (runExtend(c)) continue;
        addRelaxed(c);
      }
      while (out.length < target && restPool.isNotEmpty) {
        final c = restPool.removeAt(0);
        if (runExtend(c)) continue;
        addRelaxed(c);
      }
    }
    // Trim trailing artist run so playback never opens on 3+ of the same.
    if (out.isNotEmpty) {
      final lastArtist = normArtist(out.last.artist);
      var keep = out.length;
      for (var i = out.length - 1; i >= 0 && normArtist(out[i].artist) == lastArtist; i--) {
        if (out.length - i > maxSameArtistRun) {
          keep = i + 1;
        }
      }
      if (keep < out.length) out.removeRange(keep, out.length);
    }
    return out;
  }
}