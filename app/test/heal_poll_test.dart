import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/api_client.dart';
import 'package:nasmusic/main.dart' show warmRelFallback;
import 'package:nasmusic/screens/staging_screen.dart'
    show downloadsHash, downloadsPollDelaySec;

DownloadRow _dl(String id, String status) =>
    DownloadRow(id: id, baseName: 'b-$id', status: status);

Suggestion _s(String artist, String title) =>
    Suggestion(artist: artist, title: title);

void main() {
  group('downloadsHash', () {
    test('stable for identical lists', () {
      final a = [_dl('1', 'queued'), _dl('2', 'staged')];
      expect(downloadsHash(a), downloadsHash([_dl('1', 'queued'), _dl('2', 'staged')]));
    });
    test('changes on status flip', () {
      expect(downloadsHash([_dl('1', 'queued')]),
          isNot(downloadsHash([_dl('1', 'downloading')])));
    });
    test('changes on row add/remove', () {
      expect(downloadsHash([_dl('1', 'queued')]),
          isNot(downloadsHash([_dl('1', 'queued'), _dl('2', 'queued')])));
    });
    test('empty list hashes stable', () {
      expect(downloadsHash([]), downloadsHash([]));
    });
  });

  group('downloadsPollDelaySec', () {
    test('3s while busy or just changed', () {
      expect(downloadsPollDelaySec(busy: true, stableTicks: 99), 3);
      expect(downloadsPollDelaySec(busy: false, stableTicks: 0), 3);
    });
    test('backs off 6/9/12 then caps at 15s', () {
      expect(downloadsPollDelaySec(busy: false, stableTicks: 1), 6);
      expect(downloadsPollDelaySec(busy: false, stableTicks: 2), 9);
      expect(downloadsPollDelaySec(busy: false, stableTicks: 3), 12);
      expect(downloadsPollDelaySec(busy: false, stableTicks: 4), 15);
      expect(downloadsPollDelaySec(busy: false, stableTicks: 40), 15);
    });
  });

  group('warmRelFallback', () {
    test('serves cached rows minus excluded, capped at limit', () {
      final cache = [_s('A', 'One'), _s('B', 'Two'), _s('C', 'Three')];
      final out = warmRelFallback(cache, {'two'}, 10);
      expect(out.map((s) => s.title), ['One', 'Three']);
      expect(warmRelFallback(cache, {}, 2).length, 2);
    });
    test('empty cache stays empty (caller logs, never parks dead)', () {
      expect(warmRelFallback([], {}, 20), isEmpty);
    });
    test('all-excluded yields empty', () {
      final cache = [_s('A', 'One')];
      expect(warmRelFallback(cache, {'one'}, 10), isEmpty);
    });
  });
}
