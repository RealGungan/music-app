import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/queue_player.dart';

/// The external-pause lie, hardened twice over:
///  1. the visible play screen re-asks the handler DIRECTLY every 1s
///     (was 2s), so a native pause that lands outside Dart cannot hold the
///     skin on "playing" long enough to need a second tap;
///  2. a native POSITION truth check at 1s — a player that dies without
///     any focus event freezes the clock, and 2s of frozen position under
///     a playing claim forces the paused repaint + a `skin-mismatch`
///     client-log row naming which path lied.
void main() {
  group('frozen-position run (1s samples, 2s threshold)', () {
    test('one frozen tick is jitter, not a dead player', () {
      expect(frozenRun(advanced: false, prev: 0), 1);
    });

    test('two consecutive frozen ticks reach the limit (== 2s)', () {
      final one = frozenRun(advanced: false, prev: 0);
      final two = frozenRun(advanced: false, prev: one);
      expect(two, 2);
      expect(two >= 2, isTrue);
    });

    test('any movement resets the run to zero', () {
      final frozen = frozenRun(advanced: false, prev: 1);
      expect(frozenRun(advanced: true, prev: frozen), 0);
      expect(frozenRun(advanced: true, prev: 99), 0);
    });

    test('a run of 2 flips the verdict to paused under a playing claim', () {
      // The audit gates on the frozen RUN; the verdict itself still reads
      // the raw per-tick "did position advance" signal.
      var run = 0;
      final verdicts = <StallFix>[];
      for (var i = 0; i < 3; i++) {
        run = frozenRun(advanced: false, prev: run);
        final fix = run >= 2
            ? stallAudit(
                enginePlaying: true,
                posAdvanced: false,
                loading: false,
              )
            : StallFix.none;
        verdicts.add(fix);
      }
      expect(verdicts, [StallFix.none, StallFix.toPaused, StallFix.toPaused]);
    });

    test('buffering suppresses the frozen-position correction', () {
      // Dead player vs slow relay start look identical on a frozen clock;
      // the loading flag is the only thing that tells them apart.
      expect(
        stallAudit(enginePlaying: true, posAdvanced: false, loading: true),
        StallFix.none,
      );
    });
  });

  group('skin-mismatch evidence row', () {
    test('a playing skin over a frozen clock is reported, paused skin is not',
        () {
      expect(
        skinMismatch(skinShows: true, nativePlaying: false),
        isTrue,
      );
      expect(
        skinMismatch(skinShows: false, nativePlaying: false),
        isFalse,
      );
      expect(
        skinMismatch(skinShows: true, nativePlaying: true),
        isFalse,
      );
    });

    test('the report names both sides so the lying path is identifiable', () {
      final m = skinMismatchMessage(
        skinShows: true,
        nativePlaying: false,
        engine: 'playing',
        handler: 'playing',
      );
      expect(m, contains('skin=playing'));
      expect(m, contains('expected=paused'));
      expect(m, contains('engine=playing'));
      expect(m, contains('handler=playing'));
    });
  });
}