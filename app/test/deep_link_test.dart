import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/api_client.dart';
import 'package:nasmusic/deep_link.dart';

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
}
