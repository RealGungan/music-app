import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/play_log.dart';
import 'package:nasmusic/wrapped.dart';

PlayEvent ev(String base, int day, int seconds, [int month = 1]) =>
    PlayEvent(
      base: base,
      atMs: DateTime(2026, month, day, 12).millisecondsSinceEpoch,
      seconds: seconds,
    );

void main() {
  test('streams need >30s; top songs by count', () {
    final s = WrappedStats.compute([
      ev('A - one', 1, 200),
      ev('A - one', 2, 200),
      ev('B - two', 1, 200),
      ev('C - skip', 1, 10),
    ]);
    expect(s.totalStreams, 3);
    expect(s.topSongs.first.name, 'A - one');
    expect(s.topSongs.first.streams, 2);
    expect(s.distinctSongs, 2);
  });

  test('minutes sum everything incl short tails', () {
    final s = WrappedStats.compute([
      ev('A - one', 1, 200),
      ev('C - skip', 1, 10),
    ]);
    expect(s.totalSeconds, 210);
    expect(s.totalStreams, 1);
  });

  test('featured artists split credit', () {
    final s = WrappedStats.compute([
      ev('Main, Feat - song', 1, 200),
      ev('Main, Feat - song', 2, 200),
      ev('Solo - other', 1, 200),
      ev('Solo - other', 2, 200),
      ev('Solo - other', 3, 200),
    ]);
    expect(s.topArtists.first.name, 'Solo');
    expect(s.topArtists.first.streams, 3);
  });

  test('sprint + biggest day', () {
    final s = WrappedStats.compute([
      ev('A - one', 1, 300),
      ev('B - two', 1, 300),
      ev('B - two', 1, 300),
    ]);
    expect(s.artistMonth['2026-01'], 'B');
    expect(s.biggestDay, '2026-01-01');
    expect(s.biggestDaySeconds, 900);
  });

  test('year filter', () {
    final s = WrappedStats.compute([
      ev('A - one', 1, 200),
      PlayEvent(
          base: 'B - two',
          atMs: DateTime(2025, 6, 3, 12).millisecondsSinceEpoch,
          seconds: 200),
    ], year: 2026);
    expect(s.totalStreams, 1);
    expect(s.topSongs.first.name, 'A - one');
  });
}
