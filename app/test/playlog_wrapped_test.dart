import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/demo_wrapped.dart';
import 'package:nasmusic/play_log.dart';
import 'package:nasmusic/wrapped.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PlayLog -> Wrapped contract: every path that seals a track must bank an
/// event Wrapped counts (>30s strict). Regression: finished songs banked ~0s
/// (stale UI clock) so only skips ever counted.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PlayLog.clear();
  });

  Future<List<PlayEvent>> events() => PlayLog.load();

  test('skip at 45s counts', () async {
    await PlayLog.switched('', 0, 'A - one');
    await PlayLog.switched('A - one', 45, 'B - two');
    final evs = await events();
    expect(evs.length, 1);
    expect(evs.single.seconds, 45);
    expect(WrappedStats.compute(evs).totalStreams, 1);
  });

  test('natural finish (full 200s sealed) counts', () async {
    await PlayLog.switched('', 0, 'A - one');
    await PlayLog.switched('A - one', 200, 'B - two');
    expect(WrappedStats.compute(await events()).totalStreams, 1);
  });

  test('single-item completion seals same-title', () async {
    await PlayLog.switched('', 0, 'A - one');
    await PlayLog.switched('A - one', 200, 'A - one');
    final evs = await events();
    expect(evs.length, 1);
    expect(WrappedStats.compute(evs).totalStreams, 1);
  });

  test('exactly 30s does NOT count (strict >30), minutes kept', () async {
    await PlayLog.switched('', 0, 'A - one');
    await PlayLog.switched('A - one', 30, 'B - two');
    final s = WrappedStats.compute(await events());
    expect(s.totalStreams, 0);
    expect(s.totalSeconds, 30);
  });

  test('29s and 31s boundary', () async {
    await PlayLog.switched('', 0, 'A - one');
    await PlayLog.switched('A - one', 29, 'B - two');
    await PlayLog.switched('B - two', 31, 'C - three');
    final s = WrappedStats.compute(await events());
    expect(s.totalStreams, 1);
    expect(s.topSongs.single.name, 'B - two');
  });

  test('background flush seals once, wrong title no-op', () async {
    await PlayLog.switched('', 0, 'A - one');
    await PlayLog.flush('A - one', 120);
    await PlayLog.flush('A - one', 120);
    await PlayLog.flush('other', 120);
    final evs = await events();
    expect(evs.length, 1);
    expect(WrappedStats.compute(evs).totalStreams, 1);
  });

  test('year filter keeps current year only', () async {
    await PlayLog.switched('', 0, 'A - one');
    await PlayLog.switched('A - one', 200, 'B - two');
    final now = DateTime.now().year;
    final s = WrappedStats.compute(await events(), year: now);
    expect(s.totalStreams, 1);
    final old = WrappedStats.compute(await events(), year: 2000);
    expect(old.totalStreams, 0);
  });

  test('demo unlocks, real empty stays locked, demo never persists',
      () async {
    final demo = demoEvents();
    expect(demo.every((e) => e.seconds > 30), isTrue);
    expect(WrappedStats.compute(demo).totalStreams, greaterThanOrEqualTo(30));
    expect(WrappedStats.compute(await events()).totalStreams, 0);
    expect(await events(), isEmpty);
  });
}
