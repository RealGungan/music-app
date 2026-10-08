import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/queue/queue_planner.dart';

RelatedCandidate _c(String artist, String title) =>
    RelatedCandidate(artist: artist, title: title);

void main() {
  group('QueuePlanner.needed', () {
    test('returns 0 when above keepAhead', () {
      final p = QueuePlanner(keepAhead: 25);
      expect(p.needed(30), 0);
    });

    test('returns 0 when at keepAhead', () {
      final p = QueuePlanner(keepAhead: 25);
      expect(p.needed(25), 0);
    });

    test('returns deficit to fill keepAhead', () {
      final p = QueuePlanner(keepAhead: 25);
      expect(p.needed(20), 5);
      expect(p.needed(10), 15);
      expect(p.needed(0), 25);
    });
  });

  group('QueuePlanner.shouldRefill', () {
    test('triggers at or below refillWhen', () {
      final p = QueuePlanner(refillWhen: 10);
      expect(p.shouldRefill(10), true);
      expect(p.shouldRefill(5), true);
      expect(p.shouldRefill(0), true);
    });

    test('does not trigger above refillWhen', () {
      final p = QueuePlanner(refillWhen: 10);
      expect(p.shouldRefill(11), false);
      expect(p.shouldRefill(20), false);
    });
  });

  group('QueuePlanner continuous refill (refillWhen == keepAhead)', () {
    test('never lets the queue drain: refills from every consumed row', () {
      // The app wires its default planner with keepAhead == refillWhen so a
      // top-up happens after EVERY track advance — the tail never visibly
      // drains down to a "refill line" and jumps back up in a batch. This is
      // the opposite of "+N when you reach the Nth": consume 1 → top back up 1.
      final p = QueuePlanner(keepAhead: 25, refillWhen: 25);
      for (var remaining = 24; remaining >= 0; remaining--) {
        expect(p.shouldRefill(remaining), true,
            reason: 'remaining=$remaining must trigger a continuous refill');
        expect(p.needed(remaining), 25 - remaining);
      }
    });

    test('still tops up in one shot when very short (honest deficit)', () {
      final p = QueuePlanner(keepAhead: 25, refillWhen: 25);
      expect(p.needed(0), 25);
      expect(p.needed(3), 22);
    });
  });

  group('QueuePlanner.pick randomization (refill diversity)', () {
    test('same inputs with different random seeds produce different orders',
        () {
      // User complaint: "6 songs, divider, 4, divider, 5, divider, 5 —
      // that's it". The old pick() took the lead tier in sorted order, so
      // every refill for the same seed returned the same few closest tracks
      // in the same order → the queue stalled. Both tiers must be shuffled.
      final candidates = List.generate(
        20,
        (i) => _c('Artist $i', 'Song $i'),
      );
      final seed = _c('Seed Artist', 'Seed Song');
      final a = QueuePlanner(keepAhead: 25, refillWhen: 10, random: Random(1))
          .pick(
        candidates: candidates,
        seed: seed,
        seen: {},
        recent: {},
        queueTail: [],
      );
      final b = QueuePlanner(keepAhead: 25, refillWhen: 10, random: Random(2))
          .pick(
        candidates: candidates,
        seed: seed,
        seen: {},
        recent: {},
        queueTail: [],
      );
      expect(a.map((c) => c.title), isNot(b.map((c) => c.title)));
    });

    test('opening picks still come from the lead (closest-to-seed) tier',
        () {
      // Randomization interleaves ~3:1 toward the closest matches — the first
      // pick must never regress into a random unrelated row.
      final lead = List.generate(10, (i) => _c('L$i', 'Main $i'));
      final rest = List.generate(10, (i) => _c('R$i', 'zzz $i'));
      final picked = QueuePlanner(keepAhead: 25, refillWhen: 10, random: Random(42))
          .pick(
        candidates: [...lead, ...rest],
        seed: _c('Seed', 'Main'),
        seen: {},
        recent: {},
        queueTail: [],
      );
      expect(picked.first.artist, startsWith('L'),
          reason: 'first "up next" row should be a close match');
      // And the batch still contains some novelty rows from the rest tier.
      expect(picked.any((c) => c.artist.startsWith('R')), true);
    });
  });

  group('QueuePlanner.pick', () {
    late QueuePlanner planner;
    setUp(() {
      planner = QueuePlanner(
        keepAhead: 25,
        refillWhen: 10,
        recentWindow: 50,
        maxSameArtistRun: 2,
        random: Random(42), // deterministic
      );
    });

    test('returns unique candidates (no duplicates)', () {
      final picked = planner.pick(
        candidates: List.generate(20, (i) => _c('Artist $i', 'Song $i')),
        seed: _c('Seed Artist', 'Seed Song'),
        seen: {},
        recent: {},
        queueTail: [],
      );
      final keys = picked.map((c) => c.key).toSet();
      expect(keys.length, picked.length);
    });

    test('respects seen keys (no repeats)', () {
      final c1 = _c('Radiohead', 'Creep');
      final picked = planner.pick(
        candidates: [c1, _c('Metallica', 'Enter Sandman')],
        seed: _c('Seed', 'Song'),
        seen: {c1.key},
        recent: {},
        queueTail: [],
      );
      expect(picked.every((c) => c.key != c1.key), true);
    });

    test('respects recent keys', () {
      final c1 = _c('Nirvana', 'Smells Like Teen Spirit');
      final picked = planner.pick(
        candidates: [c1, _c('Metallica', 'Enter Sandman')],
        seed: _c('Seed', 'Song'),
        seen: {},
        recent: {c1.key},
        queueTail: [],
      );
      expect(picked.every((c) => c.key != c1.key), true);
    });

    test('enforces artist cooldown (maxSameArtistRun)', () {
      final picked = planner.pick(
        candidates: [
          _c('Metallica', 'Enter Sandman'),
          _c('Metallica', 'Nothing Else Matters'),
          _c('Metallica', 'Fade to Black'),
          _c('Metallica', 'One'),
          _c('Radiohead', 'Creep'),
          _c('Nirvana', 'Come As You Are'),
        ],
        seed: _c('Some Other Artist', 'Song'),
        seen: {},
        recent: {},
        queueTail: [],
      );
      // No more than 2 consecutive Metallica tracks
      int run = 0;
      for (final c in picked) {
        if (c.artist == 'Metallica') {
          run++;
          expect(run, lessThanOrEqualTo(2));
        } else {
          run = 0;
        }
      }
    });

    test('returns empty when all candidates excluded', () {
      final candidates = [
        _c('A', 'B'),
        _c('C', 'D'),
      ];
      final picked = planner.pick(
        candidates: candidates,
        seed: _c('X', 'Y'),
        seen: candidates.map((c) => c.key).toSet(),
        recent: {},
        queueTail: [],
      );
      expect(picked, isEmpty);
    });

    test('returns up to maxRows', () {
      final picked = planner.pick(
        candidates: List.generate(30, (i) => _c('Artist $i', 'Song $i')),
        seed: _c('Seed', 'Song'),
        seen: {},
        recent: {},
        queueTail: [],
        maxRows: 5,
      );
      expect(picked.length, lessThanOrEqualTo(5));
    });

    test('handles empty candidates', () {
      final picked = planner.pick(
        candidates: [],
        seed: _c('Seed', 'Song'),
        seen: {},
        recent: {},
        queueTail: [],
      );
      expect(picked, isEmpty);
    });

    test('seed-drift: candidates similar to seed rank first', () {
      final picked = planner.pick(
        candidates: [
          _c('Metallica', 'Nothing Else Matters'),
          _c('Metallica', 'Enter Sandman'),
          _c('Metallica', 'Fade to Black'),
        ],
        seed: _c('Metallica', 'Enter Sandman'),
        seen: {},
        recent: {},
        queueTail: [],
      );
      // Same song as seed should be demoted (title similarity penalty),
      // related songs should come first
      if (picked.length >= 2) {
        // First pick should NOT be the exact same song as seed
        expect(picked.first.title, isNot('Enter Sandman'));
      }
    });

    test('randomizes across refills: same seed does NOT repeat the same order', () {
      // Regression for "the queue always shows the same few closest tracks":
      // pick() used to take the lead tier in SORTED order, so every refill for
      // the same seed returned the identical top-N. Both tiers are now
      // shuffled, so two planners (different RNG) must diverge.
      final a = QueuePlanner(
        keepAhead: 25,
        refillWhen: 10,
        recentWindow: 50,
        maxSameArtistRun: 2,
        random: Random(1),
      );
      final b = QueuePlanner(
        keepAhead: 25,
        refillWhen: 10,
        recentWindow: 50,
        maxSameArtistRun: 2,
        random: Random(2),
      );
      final cands = List.generate(
        12,
        (i) => _c('Metallica', 'Tune ${12 - i}'),
      );
      final seed = _c('Metallica', 'Enter Sandman');
      final listA = a.pick(
        candidates: cands,
        seed: seed,
        seen: {},
        recent: {},
        queueTail: [],
        maxRows: 6,
      );
      final listB = b.pick(
        candidates: cands,
        seed: seed,
        seen: {},
        recent: {},
        queueTail: [],
        maxRows: 6,
      );
      expect(listA.map((c) => c.key).toList(),
          isNot(equals(listB.map((c) => c.key).toList())),
          reason: 'two refills for the same seed must diverge (randomized)');
    });

    test('relaxed fallback fills when artist cap blocks everything', () {
      // All candidates are from one artist — should still get some
      final picked = planner.pick(
        candidates: List.generate(10, (i) => _c('Metallica', 'Song $i')),
        seed: _c('Radiohead', 'Creep'),
        seen: {},
        recent: {},
        queueTail: [],
      );
      expect(picked.length, greaterThan(0));
    });

    test('refill diversity: same seed + same feed yields a different order', () {
      // Regression for the "6 songs, AUTOPLAY, 4, AUTOPLAY, 5, AUTOPLAY, 5 —
      // and that's it" stall. The OLD pick took the lead tier in SORTED order,
      // so every refill returned the same few closest tracks and the tail
      // never grew past ~20. Now BOTH tiers are shuffled, so a repeated
      // refill for the same seed diverges instead of recycling.
      final candidates = List.generate(10, (i) => _c('Metallica', 'Song $i'));
      final seed = _c('Metallica', 'Song X');
      List<String> orderFor(int seedVal) => QueuePlanner(
            keepAhead: 25,
            refillWhen: 10,
            random: Random(seedVal),
          ).pick(
            candidates: candidates,
            seed: seed,
            seen: {},
            recent: {},
            queueTail: [],
            maxRows: 6,
          ).map((c) => c.key).toList();

      final a = orderFor(41);
      final b = orderFor(42);
      // Astronomically unlikely to collide with 10! permutations at fixed
      // seeds — this deterministically proves the lead tier is shuffled.
      expect(a, isNot(equals(b)));
      // Both still dedup and respect the requested width.
      expect(a.toSet().length, a.length);
      expect(b.length, lessThanOrEqualTo(6));
    });
  });

  group('RelatedCandidate.key', () {
    test('normalized artist+title key', () {
      final c = RelatedCandidate(artist: 'Metallica', title: 'Enter Sandman');
      expect(c.key, contains('\x00'));
    });

    test('accent normalization in key', () {
      final c1 = RelatedCandidate(artist: 'Café', title: 'Bébé');
      final c2 = RelatedCandidate(artist: 'cafe', title: 'bebe');
      expect(c1.key, c2.key);
    });

    test('parenthesized tags stripped from key', () {
      final c1 = RelatedCandidate(artist: 'Radiohead', title: 'Creep');
      final c2 = RelatedCandidate(
        artist: 'Radiohead',
        title: 'Creep (2017 Remaster)',
      );
      expect(c1.key, c2.key);
    });
  });

  group('QueuePlanner artist-run cap (Wrapped-log Marea x8 run)', () {
    List<RelatedCandidate> monoPool(String artist, int n) =>
        [for (var i = 0; i < n; i++) _c(artist, 'Song $i')];

    int maxRun(List<RelatedCandidate> rows) {
      var best = 0, cur = 0;
      String? prev;
      for (final r in rows) {
        if (r.artist == prev) {
          cur++;
        } else {
          cur = 1;
          prev = r.artist;
        }
        if (cur > best) best = cur;
      }
      return best;
    }

    test('never extends an already-full run, even to fill target', () {
      final p = QueuePlanner(random: Random(7));
      final pool = [...monoPool('Marea', 10), _c('Platero y Tu', 'Cigarrito')];
      final out = p.pick(
        candidates: pool,
        seed: _c('Marea', 'Puta'),
        seen: {},
        recent: {},
        // Previous batch ended on a full Marea run:
        queueTail: ['Marea', 'Marea'],
        maxRows: 6,
      );
      expect(maxRun(out), lessThanOrEqualTo(2));
      expect(out.map((r) => r.artist), contains('Platero y Tu'));
    });

    test('mono-artist pool with full run returns short batch, no violation', () {
      final p = QueuePlanner(random: Random(7));
      final out = p.pick(
        candidates: monoPool('Marea', 10),
        seed: _c('Marea', 'Puta'),
        seen: {},
        recent: {},
        queueTail: ['Marea', 'Marea'],
        maxRows: 6,
      );
      expect(maxRun(out), lessThanOrEqualTo(2));
      expect(out.length, lessThan(6));
    });

    test('fresh pool keeps growing the queue (no silent stall)', () {
      final p = QueuePlanner(random: Random(7));
      final seen = {
        for (var i = 0; i < 30; i++) _c('Seen', 'Old $i').key,
      };
      final fresh = [
        for (var i = 0; i < 10; i++) _c('New Artist $i', 'Fresh $i'),
      ];
      final out = p.pick(
        candidates: fresh,
        seed: _c('Seed', 'Track'),
        seen: seen,
        recent: {},
        queueTail: [],
        maxRows: 10,
      );
      expect(out.length, 10);
    });
  });
}
