import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/api_client.dart';
import 'package:nasmusic/now_playing.dart' show nowPlayingAlbum;
import 'package:nasmusic/queue_player.dart' show QueueItem;

// Regression: internet search rows (Search tab) must keep the album
// button's backing album from parse -> row -> queue item -> chip.
// Same pattern as the deep-link tests: carry album at creation, engine
// backfill (res.album ?? item.album) wins, never overwrite with null.
void main() {
  QueueItem discoveryItem(DiscoveryTrack t) => QueueItem(
        '${t.artist} - ${t.title}',
        'relay:${t.videoId}',
        videoId: t.videoId.isNotEmpty ? t.videoId : null,
        resolveName: t.videoId.isEmpty
            ? (artist: t.artist, title: t.title)
            : null,
        album: (t.album?.isNotEmpty ?? false) ? t.album : null,
      );

  QueueItem libraryItem(LibraryTrack t) => QueueItem(
        t.baseName,
        'file:${t.url}',
        album: (t.album?.isNotEmpty ?? false) ? t.album : null,
      );

  QueueItem suggestionItem(Suggestion s) {
    final artist = s.artist?.isNotEmpty == true ? s.artist! : '';
    final title = s.title?.isNotEmpty == true ? s.title! : s.baseName;
    return QueueItem(
      title,
      'placeholder',
      resolveName: (artist: artist, title: title),
      album: (s.album?.isNotEmpty ?? false) ? s.album : null,
    );
  }

  // Engine write-back merge (both _resolveItemUrl and _prefetchNext):
  // backfilled album wins, placeholder kept otherwise — never null-clobber.
  String? merge(String? resAlbum, String? itemAlbum) => resAlbum ?? itemAlbum;

  group('search library template carries album', () {
    test('parse->item->chip visible', () {
      final t = LibraryTrack.fromJson({
        'base_name': 'La Polla Records - Ellos Dicen Mierda',
        'folder': 'Punk',
        'url': '/staging/file/x.mp3',
        'album': 'En Tu Recto',
      });
      final item = libraryItem(t);
      expect(item.album, 'En Tu Recto');
      expect(nowPlayingAlbum(null, item.album), 'En Tu Recto');
    });
    test('album-less library row hides honestly', () {
      final t = LibraryTrack.fromJson({
        'base_name': 'A - T',
        'folder': 'F',
        'url': '/staging/file/x.mp3',
      });
      expect(libraryItem(t).album, isNull);
      expect(nowPlayingAlbum(null, libraryItem(t).album), isNull);
    });
  });

  group('search discovery template carries album', () {
    Map<String, dynamic> row({bool withAlbum = true}) => {
          'video_id': 'VID123',
          'artist': 'La Polla Records',
          'title': 'Ellos Dicen Mierda',
          'channel': 'ch',
          'duration_s': 1,
          'score': 1,
          'tier': 1,
          if (withAlbum) 'album': 'En Tu Recto',
        };
    test('parse->item->chip visible (videoId path)', () {
      final item = discoveryItem(DiscoveryTrack.fromJson(row()));
      expect(item.album, 'En Tu Recto');
      expect(nowPlayingAlbum(null, item.album), 'En Tu Recto');
    });
    test('album-less row heals via backfill, never null-clobbers', () {
      final item = discoveryItem(DiscoveryTrack.fromJson(row(withAlbum: false)));
      expect(item.album, isNull);
      expect(nowPlayingAlbum(null, item.album), isNull);
      expect(nowPlayingAlbum(null, merge('En Tu Recto', item.album)),
          'En Tu Recto');
      final keep = discoveryItem(DiscoveryTrack.fromJson(row()));
      expect(nowPlayingAlbum(null, merge(null, keep.album)), 'En Tu Recto');
    });
  });

  group('search suggestion template carries album', () {
    Map<String, dynamic> row({bool withAlbum = true}) => {
          'kind': 'song',
          'artist': 'La Polla Records',
          'title': 'Ellos Dicen Mierda',
          if (withAlbum) 'album': 'En Tu Recto',
        };
    test('parse->item->chip visible (resolveName path)', () {
      final item = suggestionItem(Suggestion.fromJson(row()));
      expect(item.album, 'En Tu Recto');
      expect(item.resolveName, isNotNull);
      expect(nowPlayingAlbum(null, item.album), 'En Tu Recto');
    });
    test('album-less suggestion heals via backfill', () {
      final item =
          suggestionItem(Suggestion.fromJson(row(withAlbum: false)));
      expect(item.album, isNull);
      expect(nowPlayingAlbum(null, merge('En Tu Recto', item.album)),
          'En Tu Recto');
    });
  });
}
