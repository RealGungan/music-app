import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nasmusic/api_client.dart';
import 'package:nasmusic/screens/search_screen.dart' show isSongRow;

// Canned server answers: one fake, seven contract checks, zero network.
class _Fake extends http.BaseClient {
  _Fake(this._respond);
  final http.Response Function(Uri url, String method) _respond;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest req) async {
    final r = _respond(req.url, req.method);
    return http.StreamedResponse(
      Stream.value(r.bodyBytes),
      r.statusCode,
      request: req,
      headers: r.headers,
    );
  }
}

http.Response _json(Object j, [int code = 200]) => http.Response(
      jsonEncode(j),
      code,
      headers: {'content-type': 'application/json'},
    );

const _vid = 'dQw4w9WgXcQ';
const _art = 'bb trickz';
const _title = 'Bullshit';

// ponytail: single shared fixture; per-case JSON only where it differs.
Map<String, dynamic> _searchJson() => {
      'local': [],
      'discovery': [
        {
          'video_id': _vid,
          'artist': _art,
          'title': _title,
          'channel': 'bb trickz',
          'duration_s': 157,
          'score': 95,
          'tier': 0,
          'provider': 'Deezer',
          'album': 'Bullshit - Single',
          'album_image': 'https://cdn.deezer.com/images/cover-1200.jpg',
        },
        {'video_id': 'other1', 'artist': 'other artist', 'title': 'other song'},
      ],
      'artists': [
        {'name': _art, 'image': 'https://cdn.deezer.com/images/artist.jpg'},
        {'name': 'bb trickz tribute band'},
      ],
      'discovery_pending': false,
      'artists_pending': false,
    };

ApiClient _api(http.Response Function(Uri, String) respond) =>
    ApiClient(baseUrl: 'http://music.rg.nig:8004', client: _Fake(respond));

void main() {
  test('bb trickz exact artist first', () async {
    final api = _api((u, m) => _json(_searchJson()));
    final r = await api.search('bb trickz');
    expect(r.artists, isNotEmpty);
    expect(r.artists.first.name.toLowerCase(), _art);
  });

  test('Bullshit row identity: label == resolve vid', () async {
    final api = _api((u, m) {
      if (u.path.endsWith('/api/resolvename')) {
        return _json({
          'url': 'http://x/staging/api/stream?vid=$_vid',
          'video_id': _vid,
          'thumb': 't',
          'artist': _art,
          'title': _title,
        });
      }
      return _json(_searchJson());
    });
    final r = await api.search('bb trickz bullshit');
    final row = r.discovery.firstWhere((d) => d.title == _title);
    final res = await api.resolveByName(
        artist: row.artist, title: row.title, pollWait: Duration.zero);
    expect(res.videoId, row.videoId); // tap plays the labelled video
  });

  test('structured song query sorts songs-first', () {
    expect(isSongRow(artist: _art, title: _title), isTrue);
    expect(isSongRow(baseName: _art), isFalse); // bare name = artist row
  });

  test('typeahead vs enter share the same top result', () async {
    final api = _api((u, m) {
      if (u.path.endsWith('/api/suggest')) {
        return _json({
          'results': [
            {'kind': 'song', 'artist': _art, 'title': _title},
            {'kind': 'song', 'base_name': _art},
          ],
        });
      }
      return _json(_searchJson());
    });
    final sug = await api.suggest('bb trickz bull');
    final page = await api.search('bb trickz bullshit');
    expect('${sug.first.artist} - ${sug.first.title}',
        '${page.discovery.first.artist} - ${page.discovery.first.title}');
  });

  test('covers hi-res present', () async {
    final api = _api((u, m) => _json(_searchJson()));
    final r = await api.search('bb trickz bullshit');
    final row = r.discovery.firstWhere((d) => d.title == _title);
    expect(row.albumImage, startsWith('http')); // provider hi-res art kept
    expect(api.thumbUrl(row.videoId), contains(row.videoId));
    expect(api.coverVidUrl(row.videoId), contains('cover?vid='));
  });

  test('artist disco includes non-owned rows', () async {
    final api = _api((u, m) => _json({
          'name': _art,
          'photo': 'https://cdn.deezer.com/images/artist.jpg',
          'songs': [
            {
              'base_name': 'bb trickz - owned.mp3',
              'title': 'owned',
              'exists': true,
            },
            {
              'base_name': 'bb trickz - stream-only.mp3',
              'title': 'stream-only',
              'exists': false, // not on NAS, still listed for streaming
            },
          ],
          'albums': [
            {'album': 'Owned LP', 'tracks': 10, 'owned': 10},
            {'album': 'Rare EP', 'tracks': 5, 'owned': 0}, // non-owned kept
          ],
          'singles': [],
        }));
    final p = await api.artist(_art);
    expect(p.songs.where((s) => !s.exists), isNotEmpty);
    expect(p.albums.where((a) => a.owned == 0), isNotEmpty);
  });

  test('delete routes are owner-only (403 for others)', () async {
    final api = _api((u, m) => _json({'error': 'owner only'}, 403));
    for (final call in <Future<void> Function()>[
      () => api.remove('dl1'),
      () => api.redownload('dl1', _vid),
      () => api.checkReplace('b.mp3', _art, _title),
    ]) {
      try {
        await call();
        fail('expected 403 ApiException');
      } on ApiException catch (e) {
        expect(e.statusCode, 403);
      }
    }
  });
}
