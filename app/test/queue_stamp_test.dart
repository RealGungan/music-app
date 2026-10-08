import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/queue_player.dart';

DateTime _t(int secs) => DateTime(2026, 1, 1, 0, 0, secs);

bool _drop({
  required Duration tick,
  required Duration max,
  Duration? seek,
  DateTime? seekAt,
  DateTime? now,
}) =>
    dropStalePositionTick(
      tick: tick,
      maxAccepted: max,
      seekTarget: seek,
      seekAt: seekAt ?? _t(0),
      now: now ?? _t(100),
    );

void main() {
  test('fresh switch: previous-track tail is dropped, live start passes', () {
    expect(_drop(tick: const Duration(seconds: 83), max: Duration.zero),
        true);
    expect(
        _drop(
            tick: const Duration(milliseconds: 400), max: Duration.zero),
        false);
  });

  test('stale tail after small live ticks is still dropped (exact-zero hole)',
      () {
    expect(
        _drop(
            tick: const Duration(seconds: 83),
            max: const Duration(milliseconds: 400)),
        true);
  });

  test('normal advance and small rewinds always pass', () {
    expect(
        _drop(
            tick: const Duration(seconds: 84),
            max: const Duration(seconds: 83)),
        false);
    expect(
        _drop(
            tick: const Duration(seconds: 25),
            max: const Duration(seconds: 30)),
        false);
  });

  test('genuine forward seek passes briefly, stale seek does not', () {
    final at = _t(100);
    expect(
        _drop(
            tick: const Duration(seconds: 120),
            max: const Duration(seconds: 30),
            seek: const Duration(seconds: 120),
            seekAt: at,
            now: at.add(const Duration(seconds: 1))),
        false);
    expect(
        _drop(
            tick: const Duration(seconds: 120),
            max: const Duration(seconds: 30),
            seek: const Duration(seconds: 120),
            seekAt: at,
            now: at.add(const Duration(seconds: 60))),
        true);
  });
}
