import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nasmusic/prefetch_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bypass flutter_test's mock HTTP (which answers 400 to everything) so
/// the test can talk to a real localhost HttpServer.
class _RealHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealHttp();

  setUp(() async {
    await PrefetchStore.resetForTest();
    // Sandbox the docs dir + prefs so the test never touches real storage.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return '/tmp/opencode/prefetch-store-test-docs';
        }
        return null;
      },
    );
    SharedPreferences.setMockInitialValues({});
    // The store keeps its dir across tests in-process; re-create it here
    // because tearDown wipes it.
    await Directory('/tmp/opencode/prefetch-store-test-docs/prefetch')
        .create(recursive: true);
  });

  tearDown(() async {
    await PrefetchStore.clear();
    final dir = Directory('/tmp/opencode/prefetch-store-test-docs');
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('PrefetchStore.fetch persist + lookup', () {
    test('downloaded file is findable and the index hits disk', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final bytes = List<int>.generate(4096, (i) => i % 256);
      server.listen((req) {
        req.response
          ..statusCode = 200
          ..add(bytes)
          ..close();
      });
      try {
        final path = await PrefetchStore.fetch('Test Artist - Test Title',
            'http://127.0.0.1:${server.port}/song.mp3');
        expect(path, isNotNull);
        expect(await File(path!).exists(), isTrue);
        expect(await File(path).length(), bytes.length);
        // Lookup by the same title hits without re-downloading.
        expect(
            await PrefetchStore.fileFor('Test Artist - Test Title'), path);
        // The index MUST be persisted (survives app restart) — this is
        // the regression: fetch used to only save on prune-over-cap.
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('prefetch.index.v1');
        expect(raw, isNotNull);
        expect(raw!, contains('Test Artist - Test Title'));
      } finally {
        await server.close(force: true);
      }
    });

    test('closing the pass client aborts an in-flight fetch fast', () async {
      // A server that accepts but never responds: without abort this
      // would hang until the 60s fetch timeout.
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) {
        // Intentionally never respond.
      });
      final client = http.Client();
      try {
        final stopwatch = Stopwatch()..start();
        final fut = PrefetchStore.fetch('Abort Artist - Abort Title',
            'http://127.0.0.1:${server.port}/hung.mp3',
            client: client);
        await Future.delayed(const Duration(milliseconds: 500));
        client.close();
        final result = await fut;
        stopwatch.stop();
        expect(result, isNull);
        expect(stopwatch.elapsedMilliseconds, lessThan(15000),
            reason: 'abort must beat the 60s fetch timeout by a mile');
      } finally {
        await server.close(force: true);
      }
    });

    test('second fetch of the same title is a cache hit', () async {
      var hits = 0;
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) {
        hits++;
        req.response
          ..statusCode = 200
          ..add([1, 2, 3, 4])
          ..close();
      });
      try {
        final first = await PrefetchStore.fetch(
            'Hit Artist - Hit Title', 'http://127.0.0.1:${server.port}/a.mp3');
        final second = await PrefetchStore.fetch(
            'Hit Artist - Hit Title', 'http://127.0.0.1:${server.port}/a.mp3');
        expect(first, isNotNull);
        expect(second, first);
        expect(hits, 1);
      } finally {
        await server.close(force: true);
      }
    });
  });
}
