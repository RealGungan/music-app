import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/now_playing.dart' show displayMs;
import 'package:nasmusic/queue_player.dart';

DateTime _t(int secs) => DateTime(2026, 1, 1, 0, 0, secs);

bool _drop({
  required Duration tick,
  required Duration max,
  Duration? seek,
  DateTime? seekAt,
  DateTime? now,
  DateTime? loadAt,
}) => dropStalePositionTick(
  tick: tick,
  maxAccepted: max,
  seekTarget: seek,
  seekAt: seekAt ?? _t(0),
  now: now ?? _t(100),
  // Default: fresh load (tail window open), preserving the original cases.
  loadAt: loadAt ?? now ?? _t(100),
);

void main() {
  test('fresh switch: previous-track tail is dropped, live start passes', () {
    expect(_drop(tick: const Duration(seconds: 83), max: Duration.zero), true);
    expect(
      _drop(tick: const Duration(milliseconds: 400), max: Duration.zero),
      false,
    );
  });

  test(
    'stale tail after small live ticks is still dropped (exact-zero hole)',
    () {
      expect(
        _drop(
          tick: const Duration(seconds: 83),
          max: const Duration(milliseconds: 400),
        ),
        true,
      );
    },
  );

  test('normal advance and small rewinds always pass', () {
    expect(
      _drop(
        tick: const Duration(seconds: 84),
        max: const Duration(seconds: 83),
      ),
      false,
    );
    expect(
      _drop(
        tick: const Duration(seconds: 25),
        max: const Duration(seconds: 30),
      ),
      false,
    );
  });

  test('background advance after long idle passes (frozen-clock guard)', () {
    // Handler kept playing while the UI slept: the resync tick jumps far
    // past the pre-background max. Dropping it would freeze the clock
    // forever (max never advances, so every later tick drops too).
    final load = _t(0);
    expect(
      _drop(
        tick: const Duration(seconds: 180),
        max: const Duration(seconds: 45),
        now: _t(300),
        loadAt: load,
      ),
      false,
    );
    // Same jump seconds after the load is still the old engine's tail.
    expect(
      _drop(
        tick: const Duration(seconds: 180),
        max: const Duration(seconds: 45),
        now: _t(5),
        loadAt: load,
      ),
      true,
    );
    // Window edge: inside 10s drops, past it adopts.
    expect(
      _drop(
        tick: const Duration(seconds: 60),
        max: Duration.zero,
        now: _t(9),
        loadAt: load,
      ),
      true,
    );
    expect(
      _drop(
        tick: const Duration(seconds: 60),
        max: Duration.zero,
        now: _t(11),
        loadAt: load,
      ),
      false,
    );
  });

  test('genuine forward seek passes briefly, stale seek does not', () {
    final at = _t(100);
    expect(
      _drop(
        tick: const Duration(seconds: 120),
        max: const Duration(seconds: 30),
        seek: const Duration(seconds: 120),
        seekAt: at,
        now: at.add(const Duration(seconds: 1)),
      ),
      false,
    );
    expect(
      _drop(
        tick: const Duration(seconds: 120),
        max: const Duration(seconds: 30),
        seek: const Duration(seconds: 120),
        seekAt: at,
        now: at.add(const Duration(seconds: 60)),
      ),
      true,
    );
  });

  test('displayMs holds the seek target until the engine catches up', () {
    const at = 100000;
    // Far behind (forward seek lagging) and far ahead (backward seek
    // lingering) both hold the target.
    expect(displayMs(1000, 120000, at, at + 1000), 120000);
    expect(displayMs(125000, 120000, at, at + 1000), 120000);
    // Within 2s either side, or past 3s: show the live clock.
    expect(displayMs(119000, 120000, at, at + 1000), 119000);
    expect(displayMs(121000, 120000, at, at + 1000), 121000);
    expect(displayMs(1000, 120000, at, at + 4000), 1000);
    // No target: always live.
    expect(displayMs(45000, null, at, at + 1000), 45000);
  });

  test('stampHidden: labels hide until the new track ticks', () {
    // Fresh switch (posGen still the previous load): hidden.
    expect(stampHidden(posGen: 5, playGen: 6), isTrue);
    // Never ticked at all: hidden.
    expect(stampHidden(posGen: -1, playGen: 1), isTrue);
    // First accepted tick of the new load arrived: visible.
    expect(stampHidden(posGen: 6, playGen: 6), isFalse);
    // Same-track advance: visible.
    expect(stampHidden(posGen: 3, playGen: 3), isFalse);
  });

  test('resumeFireAllowed: pause token kills every deferred resume', () {
    // Fresh schedule, audio stalled: may fire.
    expect(
      resumeFireAllowed(
        gen: 7,
        playGen: 7,
        healToken: 3,
        currentHeal: 3,
        isPlaying: false,
      ),
      isTrue,
    );
    // User paused after schedule (pause bumps _healGen): dead.
    expect(
      resumeFireAllowed(
        gen: 7,
        playGen: 7,
        healToken: 3,
        currentHeal: 4,
        isPlaying: false,
      ),
      isFalse,
    );
    // Track changed (stale nudge/heal for the previous song): dead.
    expect(
      resumeFireAllowed(
        gen: 6,
        playGen: 7,
        healToken: 3,
        currentHeal: 3,
        isPlaying: false,
      ),
      isFalse,
    );
    // Audio already flowing: no nudge needed.
    expect(
      resumeFireAllowed(
        gen: 7,
        playGen: 7,
        healToken: 3,
        currentHeal: 3,
        isPlaying: true,
      ),
      isFalse,
    );
  });

  test('resumeFireAllowed: pause latch kills even fresh-token resumes', () {
    // Heal STARTED after the pause owns a fresh token (healToken ==
    // currentHeal) with stale isPlaying=true (ack in flight) — the latch
    // alone must still kill it.
    expect(
      resumeFireAllowed(
        gen: 7,
        playGen: 7,
        healToken: 4,
        currentHeal: 4,
        isPlaying: true,
        pauseIntent: true,
      ),
      isFalse,
    );
    expect(
      resumeFireAllowed(
        gen: 7,
        playGen: 7,
        healToken: 4,
        currentHeal: 4,
        isPlaying: false,
        pauseIntent: false,
      ),
      isTrue,
    );
  });

  test('healResumeAllowed: paused never resumes, playing resumes', () {
    expect(healResumeAllowed(wasPlaying: true, pauseIntent: false), isTrue);
    expect(healResumeAllowed(wasPlaying: true, pauseIntent: true), isFalse);
    expect(healResumeAllowed(wasPlaying: false, pauseIntent: false), isFalse);
    expect(healResumeAllowed(wasPlaying: false, pauseIntent: true), isFalse);
  });

  test('pause at +200ms stays paused for 5s (no auto-resume)', () {
    // Timeline: play at t=0 (gen=1, heal=5). Cold-start nudge scheduled
    // (gen=1, healToken=5, fires ~2s), slow-start watchdog (~4s), spinner
    // bound (~12s). User pauses at +200ms: healGen bumps (5→6) + latch set.
    // Every deferred fire point through 12s must stay dead — including a
    // heal STARTED after the pause (fresh token 6==6) reading stale
    // isPlaying=true while the engine ack is still in flight.
    const gen = 1, playGen = 1, scheduledHeal = 5, afterPauseHeal = 6;
    for (final _ in [2000, 4000, 5000, 12000]) {
      expect(
        resumeFireAllowed(
          gen: gen,
          playGen: playGen,
          healToken: scheduledHeal,
          currentHeal: afterPauseHeal,
          isPlaying: false,
          pauseIntent: true,
        ),
        isFalse,
      );
      expect(
        resumeFireAllowed(
          gen: gen,
          playGen: playGen,
          healToken: afterPauseHeal,
          currentHeal: afterPauseHeal,
          isPlaying: true, // stale: pause ack in flight
          pauseIntent: true,
        ),
        isFalse,
      );
      expect(healResumeAllowed(wasPlaying: true, pauseIntent: true), isFalse);
    }
  });

  group('stall detector (claim vs native clock)', () {
    test('stall-corrects-to-paused: playing claim, frozen clock', () {
      expect(
        stallAudit(
            enginePlaying: true, posAdvanced: false, loading: false),
        StallFix.toPaused,
      );
    });
    test('reverse: paused claim, moving clock corrects to playing', () {
      expect(
        stallAudit(
            enginePlaying: false, posAdvanced: true, loading: false),
        StallFix.toPlaying,
      );
    });
    test('loading/buffering never corrects (no false pause)', () {
      expect(
        stallAudit(enginePlaying: true, posAdvanced: false, loading: true),
        StallFix.none,
      );
    });
    test('agreement never corrects', () {
      expect(
        stallAudit(enginePlaying: true, posAdvanced: true, loading: false),
        StallFix.none,
      );
      expect(
        stallAudit(
            enginePlaying: false, posAdvanced: false, loading: false),
        StallFix.none,
      );
    });
  });
}
