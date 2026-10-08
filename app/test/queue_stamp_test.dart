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
}) => dropStalePositionTick(
  tick: tick,
  maxAccepted: max,
  seekTarget: seek,
  seekAt: seekAt ?? _t(0),
  now: now ?? _t(100),
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
}
