import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('offline verdict follows the reachable base', () {
    test('isNasUrl matches either known base, never file://', () {
      expect(ApiClient.isNasUrl('http://100.89.94.101:8004/staging/file/a.mp3'),
          true);
      expect(
          ApiClient.isNasUrl(
              'https://naboo.taildfeb4f.ts.net/staging/api/stream?vid=x'),
          true);
      // Trailing-slash / staging variants normalize to the same base.
      expect(ApiClient.isNasUrl('http://100.89.94.101:8004/staging/'), true);
      expect(ApiClient.isNasUrl('file:///data/a.mp3'), false);
      expect(ApiClient.isNasUrl('https://i.ytimg.com/vi/abc/hqdefault.jpg'),
          false);
      expect(ApiClient.isNasUrl('https://evilspotify.com/staging/file/a'),
          false);
      expect(ApiClient.isNasUrl(''), false);
    });

    test('rebaseUrl swaps a stale base to the current one', () async {
      final api = ApiClient(baseUrl: ApiClient.lanBase);
      await api.pinBase(ApiClient.funnelBase);
      final stale = '${ApiClient.lanBase}/staging/file/a%20b.mp3';
      final live = api.rebaseUrl(stale);
      expect(live.startsWith(api.serverBase), true);
      expect(live.endsWith('/staging/file/a%20b.mp3'), true);
      // Already current: untouched.
      expect(api.rebaseUrl(live), live);
      // Non-server URLs: untouched.
      const foreign = 'https://i.ytimg.com/vi/abc/hqdefault.jpg';
      expect(api.rebaseUrl(foreign), foreign);
      expect(api.rebaseUrl('file:///data/a.mp3'), 'file:///data/a.mp3');
    });

    test('rebaseUrl is a no-op before any base is pinned', () {
      final api = ApiClient(baseUrl: ApiClient.funnelBase);
      const u = 'https://naboo.taildfeb4f.ts.net/staging/file/a.mp3';
      expect(api.rebaseUrl(u), u);
    });
  });
}
