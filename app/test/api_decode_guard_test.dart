import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nasmusic/api_client.dart';

ApiClient _apiWithBody(String body, {int status = 200}) => ApiClient(
      baseUrl: 'https://example.invalid',
      client: MockClient((_) async => http.Response(body, status)),
    );

void main() {
  test('_decode throws on a 2xx body that is not a JSON object', () async {
    // Proxy/interstitial HTML and a bare JSON array must NOT decode to {} —
    // {} reads as "empty result" with no error and no retry.
    for (final body in ['<html><body>proxy</body></html>', '[1,2,3]']) {
      await expectLater(
        _apiWithBody(body).playlists(),
        throwsA(isA<ApiException>()),
        reason: 'body: $body',
      );
    }
  });

  test('imageProxy is idempotent — re-wrapping a proxied URL is byte-identical '
      '(thumbFor falls back to coverUrl, which is already token-wrapped)', () {
    final api = ApiClient(baseUrl: 'https://example.invalid');

    final once = api.imageProxy('https://i.scdn.co/image/ab67616d0000b273');
    expect(once, contains('/staging/api/cover?u='));
    expect(api.imageProxy(once), once, reason: 'u= must not be double-wrapped');

    final byFile = api.imageProxy(
      'https://example.invalid/staging/api/cover?f=Rock%2FAlbum.flac',
    );
    expect(api.imageProxy(byFile), byFile, reason: 'f= must not re-wrap');
  });
}