import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nasmusic/api_client.dart';
import 'package:nasmusic/meta_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Always-offline transport: every request fails like a dead route.
class _OfflineClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw const SocketException('offline');
}

PlaylistEntry _e(String base, {String? url}) => PlaylistEntry(
      baseName: base,
      path: '/p/$base',
      exists: true,
      url: url,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('MetaCache.searchEntries (offline search filter)', () {
    final entries = [
      _e('Metallica - Enter Sandman'),
      _e('Metallica - Nothing Else Matters'),
      _e('Jinjer - Pisces'),
    ];

    test('matches case-insensitive substring', () {
      final hits = MetaCache.searchEntries(entries, 'metallica');
      expect(hits.map((e) => e.baseName), hasLength(2));
    });

    test('matches title fragment', () {
      final hits = MetaCache.searchEntries(entries, 'PISCES');
      expect(hits.single.baseName, 'Jinjer - Pisces');
    });

    test('no match returns empty, blank query returns empty', () {
      expect(MetaCache.searchEntries(entries, 'madonna'), isEmpty);
      expect(MetaCache.searchEntries(entries, '  '), isEmpty);
    });
  });

  group('MetaCache playlists round-trip (library offline rows)', () {
    test('save then load returns the same lists', () async {
      const user = 'u1';
      await MetaCache.savePlaylists(user, [
        PlaylistInfo(name: 'Rock', tracks: 2),
      ]);
      await MetaCache.saveEntries(user, 'Rock', [
        _e('A - B', url: '/f/1.mp3'),
      ]);
      final pls = await MetaCache.loadPlaylists(user);
      expect(pls.single.name, 'Rock');
      final rows = await MetaCache.loadEntries(user, 'Rock');
      expect(rows.single.url, '/f/1.mp3');
    });
  });

  group('logClientError offline queue', () {
    test('failed sends queue instead of dropping', () async {
      final api = ApiClient(
          baseUrl: 'http://127.0.0.1:9', client: _OfflineClient());
      await api.logClientError('heal-cache-hit', 'A - B at=3s');
      final prefs = await SharedPreferences.getInstance();
      final q = prefs.getStringList('clientlog.queue.v1') ?? [];
      expect(q, hasLength(1));
      expect(q.single, contains('heal-cache-hit'));
    });

    test('queue caps at 50 (oldest dropped)', () async {
      final api = ApiClient(
          baseUrl: 'http://127.0.0.1:9', client: _OfflineClient());
      for (var i = 0; i < 55; i++) {
        await api.logClientError('k', 'm$i');
      }
      final prefs = await SharedPreferences.getInstance();
      final q = prefs.getStringList('clientlog.queue.v1') ?? [];
      expect(q, hasLength(50));
      expect(q.first, contains('m5'));
      expect(q.last, contains('m54'));
    });
    test('long exception bodies survive (2000, not 500)', () async {
      final api = ApiClient(
          baseUrl: 'http://127.0.0.1:9', client: _OfflineClient());
      final long = 'e' * 1500;
      await api.logClientError('playback', long);
      final prefs = await SharedPreferences.getInstance();
      final q = prefs.getStringList('clientlog.queue.v1') ?? [];
      expect(q, hasLength(1));
      expect(q.single, contains(long));
    });
  });
}
