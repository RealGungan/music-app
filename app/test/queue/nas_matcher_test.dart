import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/queue/nas_matcher.dart';

void main() {
  group('TracksRow', () {
    test('fromJson parses correctly', () {
      final row = TracksRow.fromJson({
        'base_name': 'Radiohead - Creep.mp3',
        'url': '/music/Radiohead - Creep.mp3',
        'folder': 'Rock',
      });
      expect(row.baseName, 'Radiohead - Creep.mp3');
      expect(row.url, '/music/Radiohead - Creep.mp3');
      expect(row.folder, 'Rock');
    });

    test('fromJson defaults empty fields', () {
      final row = TracksRow.fromJson(<String, dynamic>{});
      expect(row.baseName, '');
      expect(row.url, '');
      expect(row.folder, '');
    });
  });

  group('NasIndex', () {
    test('builds from a plain list of maps', () {
      final idx = NasIndex.fromJson([
        {'base_name': 'Metallica - Enter Sandman.mp3', 'url': '/f1', 'folder': 'Metal'},
        {'base_name': 'Radiohead - Creep.mp3', 'url': '/f2', 'folder': 'Alt'},
      ]);
      expect(idx.length, 2);
    });

    test('builds from {tracks: [...]} wrapper', () {
      final idx = NasIndex.fromJson({
        'tracks': [
          {'base_name': 'A - B.mp3', 'url': '/x'},
        ],
      });
      expect(idx.length, 1);
    });

    test('skips non-map entries', () {
      final idx = NasIndex.fromJson([
        'string entry',
        42,
        {'base_name': 'Good - Track.mp3', 'url': '/g'},
      ]);
      expect(idx.length, 1);
    });

    test('handles entries without " - " separator', () {
      final idx = NasIndex.fromJson([
        {'base_name': 'Unknown Track.mp3', 'url': '/u'},
      ]);
      final m = idx.findBestMatch('', 'Unknown Track');
      expect(m, isNotNull);
    });
  });

  group('NasIndex.findBestMatch', () {
    late NasIndex idx;

    setUp(() {
      idx = NasIndex.fromJson([
        {'base_name': 'Metallica - Enter Sandman.mp3', 'url': '/metal', 'folder': 'Metal'},
        {'base_name': 'Metallica - Enter Sandman (Remastered).mp3', 'url': '/metal-r', 'folder': 'Metal'},
        {'base_name': 'Radiohead - Creep.mp3', 'url': '/rh', 'folder': 'Alt'},
        {'base_name': 'Drake - God\'s Plan.mp3', 'url': '/drake', 'folder': 'HipHop'},
      ]);
    });

    test('exact match returns high score', () {
      final m = idx.findBestMatch('Metallica', 'Enter Sandman');
      expect(m, isNotNull);
      expect(m!.score, greaterThan(0.9));
      expect(m.track.url, '/metal');
    });

    test('remaster tag variant matches', () {
      final m = idx.findBestMatch('Metallica', 'Enter Sandman (2017 Remaster)');
      expect(m, isNotNull);
      expect(m!.score, greaterThan(0.85));
    });

    test('case insensitive match', () {
      final m = idx.findBestMatch('METALLICA', 'enter sandman');
      expect(m, isNotNull);
      expect(m!.score, greaterThan(0.9));
    });

    test('returns null for no match above threshold', () {
      final m = idx.findBestMatch('Metallica', 'Creep');
      expect(m, isNull);
    });

    test('artist prefilter skips non-matching artists', () {
      final m = idx.findBestMatch('Adele', 'Creep');
      expect(m, isNull);
    });

    test('empty query returns null', () {
      expect(idx.findBestMatch('', ''), isNull);
    });

    test('minScore threshold', () {
      final m = idx.findBestMatch('Metallica', 'Enter Sandman', minScore: 1.5);
      expect(m, isNull);
    });

    test('fuzzy accent match', () {
      final m = idx.findBestMatch('Drake', "God's Plan");
      expect(m, isNotNull);
      expect(m!.track.url, '/drake');
    });
  });

  group('NasMatch.key', () {
    test('generates stable normalized key', () {
      final idx = NasIndex.fromJson([
        {'base_name': 'Metallica - Enter Sandman.mp3', 'url': '/x'},
      ]);
      final m = idx.findBestMatch('Metallica', 'Enter Sandman');
      expect(m, isNotNull);
      expect(m!.key, contains('\x00'));
      expect(m.key.split('\x00').length, 2);
    });
  });
}
