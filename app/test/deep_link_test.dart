import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/api_client.dart';
import 'package:nasmusic/deep_link.dart';
import 'package:nasmusic/now_playing.dart' show nowPlayingAlbum;
import 'package:nasmusic/queue_player.dart' show spotifyDeepLinkItem;

void main() {
  test('spotify track link classifies spotify', () {
    expect(classifyDeepLink('https://open.spotify.com/track/4uLU6hMCjMI75M1A2tkuQ'), DeepLinkKind.spotify);
  });
  test('youtu.be link classifies youtube', () {
    expect(classifyDeepLink('https://youtu.be/dQw4w9WgXcQ'), DeepLinkKind.youtube);
  });
  test('music.youtube.com link classifies youtube', () {
    expect(classifyDeepLink('https://music.youtube.com/watch?v=dQw4w9WgXcQ'), DeepLinkKind.youtube);
  });
  test('non-music link is other', () {
    expect(classifyDeepLink('https://example.com/foo'), DeepLinkKind.other);
  });
  test('spotify ?si=/utm_ stripped entirely', () {
    expect(
      stripTrackingParams('https://open.spotify.com/track/4uLU6hMCjMI75M1A2tkuQ?si=abc123&utm_source=whatsapp'),
      'https://open.spotify.com/track/4uLU6hMCjMI75M1A2tkuQ',
    );
  });
  test('youtube keeps v, drops si/utm', () {
    expect(
      stripTrackingParams('https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=xyz&utm_source=wa'),
      'https://music.youtube.com/watch?v=dQw4w9WgXcQ',
    );
  });
  test('extractFirstUrl finds link in share text', () {
    expect(
      extractFirstUrl('Listen! https://open.spotify.com/track/ABC?si=x, so good'),
      'https://open.spotify.com/track/ABC?si=x',
    );
    expect(extractFirstUrl('no link here'), isEmpty);
  });
  test('cold+warm duplicate suppressed, later replay allowed', () {
    final t0 = DateTime(2026, 1, 1);
    expect(isDuplicateDeepLink(null, null, 'u', t0), isFalse);
    expect(isDuplicateDeepLink('u', t0, 'u', t0.add(const Duration(seconds: 1))), isTrue);
    expect(isDuplicateDeepLink('u', t0, 'u', t0.add(const Duration(seconds: 10))), isFalse);
    expect(isDuplicateDeepLink('u', t0, 'v', t0.add(const Duration(seconds: 1))), isFalse);
  });
  test('OpenLink parses spotify + youtube + unknown', () {
    final s = OpenLink.fromJson({'kind': 'spotify', 'artist': 'A', 'title': 'T', 'url': 'u'});
    expect(s.kind, 'spotify');
    final y = OpenLink.fromJson({'kind': 'youtube', 'video_id': 'VID', 'artist': 'A', 'title': 'T'});
    expect(y.videoId, 'VID');
    final u = OpenLink.fromJson({'kind': 'unknown', 'url': 'u'});
    expect(u.kind, 'unknown');
  });
  test('OpenLink/ResolvedName carry album when known, null otherwise', () {
    final a = OpenLink.fromJson({'kind': 'spotify', 'artist': 'A', 'title': 'T', 'album': 'ALB', 'url': 'u'});
    expect(a.album, 'ALB');
    final b = OpenLink.fromJson({'kind': 'spotify', 'artist': 'A', 'title': 'T', 'url': 'u'});
    expect(b.album, isNull);
    final c = OpenLink.fromJson({'kind': 'spotify', 'artist': 'A', 'title': 'T', 'album': '', 'url': 'u'});
    expect(c.album, isNull);
    final r = ResolvedName.fromJson({'url': 'u', 'video_id': 'v', 'album': 'ALB'});
    expect(r.album, 'ALB');
    final r2 = ResolvedName.fromJson({'url': 'u', 'video_id': 'v'});
    expect(r2.album, isNull);
  });
  test('DiscoveryTrack/Suggestion carry album when known, null otherwise', () {    final d = DiscoveryTrack.fromJson({
      'video_id': 'v', 'artist': 'A', 'title': 'T', 'channel': 'c',
      'duration_s': 1, 'score': 1, 'tier': 1, 'album': 'ALB',
    });
    expect(d.album, 'ALB');
    final d2 = DiscoveryTrack.fromJson({
      'video_id': 'v', 'artist': 'A', 'title': 'T', 'channel': 'c',
      'duration_s': 1, 'score': 1, 'tier': 1,
    });
    expect(d2.album, isNull);
    final s = Suggestion.fromJson(
        {'kind': 'song', 'artist': 'A', 'title': 'T', 'album': 'ALB'});
    expect(s.album, 'ALB');
    final s2 = Suggestion.fromJson({'kind': 'song', 'artist': 'A', 'title': 'T'});
    expect(s2.album, isNull);
  });
  group('spotify deep link keeps album (La Polla Records repro)', () {
    // open.spotify.com/track/1pQvhzRnObih9msA91xDq7 =
    // La Polla Records - Ellos Dicen Mierda (Deezer album: En Tu Recto).
    Map<String, dynamic> reproJson({bool withAlbum = true}) => {
      'kind': 'spotify',
      'artist': 'La Polla Records',
      'title': 'Ellos Dicen Mierda',
      if (withAlbum) 'album': 'En Tu Recto',
      'image': 'https://i.scdn.co/image/abc',
      'url': 'https://open.spotify.com/track/1pQvhzRnObih9msA91xDq7',
    };
    test('parse->item carries album, chip visible', () {
      final info = OpenLink.fromJson(reproJson());
      final item = spotifyDeepLinkItem(info, art: 'proxied');
      expect(item.title, 'La Polla Records - Ellos Dicen Mierda');
      expect(item.album, 'En Tu Recto');
      // No library metainfo for an internet row: the chip renders iff the
      // threaded item album is non-empty.
      expect(nowPlayingAlbum(null, item.album), 'En Tu Recto');
    });
    test('album-less parse still ends visible via engine backfill', () {
      final info = OpenLink.fromJson(reproJson(withAlbum: false));
      final item = spotifyDeepLinkItem(info);
      expect(item.album, isNull);
      expect(nowPlayingAlbum(null, item.album), isNull);
      // Engine write-back merge (queue_player _resolveItemUrl): resolvname
      // album wins, placeholder kept otherwise.
      String? resAlbum = 'En Tu Recto';
      expect(nowPlayingAlbum(null, resAlbum ?? item.album), 'En Tu Recto');
      resAlbum = null;
      final keep = OpenLink.fromJson(reproJson());
      final keepItem = spotifyDeepLinkItem(keep);
      expect(nowPlayingAlbum(null, resAlbum ?? keepItem.album), 'En Tu Recto');
    });
    test('nowPlayingAlbum prefers metainfo, hides on empty', () {
      expect(nowPlayingAlbum('Meta', 'Item'), 'Meta');
      expect(nowPlayingAlbum('', 'Item'), 'Item');
      expect(nowPlayingAlbum(null, ''), isNull);
      expect(nowPlayingAlbum(null, null), isNull);
    });
  });
}
