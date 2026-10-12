import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/api_client.dart';
import 'package:nasmusic/main.dart' show warmRelFallback;
import 'package:nasmusic/screens/staging_screen.dart'
    show downloadsHash, downloadsPollDelaySec, filterDownloadsByUser, downloadOwners;

DownloadRow _dl(String id, String status, [String owner = '']) =>
    DownloadRow(id: id, baseName: 'b-$id', status: status, owner: owner);

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

  group('warmRelFallback', () {    test('serves cached rows minus excluded, capped at limit', () {
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

  group('filterDownloadsByUser', () {
    final rows = [_dl('1', 'staged', 'alice'), _dl('2', 'queued', 'bob')];
    test('empty filter keeps all rows', () {
      expect(filterDownloadsByUser(rows, '').length, 2);
    });
    test('owner filter keeps only own rows', () {
      final out = filterDownloadsByUser(rows, 'alice');
      expect(out.map((d) => d.id), ['1']);
    });
    test('unknown user yields empty', () {
      expect(filterDownloadsByUser(rows, 'carol'), isEmpty);
    });
  });

  group('downloadOwners', () {
    test('distinct uploaders sorted, blanks dropped', () {
      final rows = [
        _dl('1', 'staged', 'bob'),
        _dl('2', 'queued', 'alice'),
        _dl('3', 'staged', 'bob'),
        _dl('4', 'staged'),
      ];
      expect(downloadOwners(rows), ['alice', 'bob']);
    });
    test('empty rows yield no users', () {
      expect(downloadOwners([]), isEmpty);
    });
  });

  group('DownloadRow.owner', () {
    test('parses owner, defaults to empty', () {
      expect(
          DownloadRow.fromJson({
            'id': '1',
            'base_name': 'a - b',
            'status': 'staged',
            'owner': 'alice',
          }).owner,
          'alice');
      expect(
          DownloadRow.fromJson(
              {'id': '1', 'base_name': 'a - b', 'status': 'staged'}).owner,
          '');
    });
  });
}
