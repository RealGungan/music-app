import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/auth_store.dart';
import 'package:nasmusic/offline_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The phone-downloads index is per-user: one user's "Downloaded" badge
/// rows must never render for the next login on the same device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const docs = '/tmp/opencode/offline-scope-test-docs';

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') return docs;
        return null;
      },
    );
    SharedPreferences.setMockInitialValues({});
    AuthStore.instance.username = 'alice';
    await OfflineStore.resetForTest();
    await Directory('$docs/offline').create(recursive: true);
  });

  tearDown(() async {
    AuthStore.instance.username = null;
    await OfflineStore.resetForTest();
    final dir = Directory(docs);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> seedUserIndex(String user, Map<String, dynamic> rows) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('offline.index.v1.$user', jsonEncode(rows));
  }

  Map<String, dynamic> row(String file, [int size = 10]) => {
        'size': size,
        'playlist': '',
        'file': file,
        'at': 0,
      };

  test('downloaded badge does not leak across users', () async {
    const base = 'Alice - Alice Song';
    await File('$docs/offline/song.mp3').writeAsBytes([1, 2, 3]);
    await seedUserIndex('alice', {base: row('song.mp3')});

    await OfflineStore.init();
    expect(OfflineStore.isDownloaded(base), isTrue);

    AuthStore.instance.username = 'bob';
    await OfflineStore.reloadForUserSwitch();
    expect(OfflineStore.isDownloaded(base), isFalse);
    expect(OfflineStore.count, 0);
  });

  test('legacy global index is adopted once, then dropped', () async {
    const base = 'Carol - Carol Song';
    await File('$docs/offline/song.mp3').writeAsBytes([1, 2, 3]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('offline.index.v1', jsonEncode({base: row('song.mp3')}));

    AuthStore.instance.username = 'carol';
    await OfflineStore.init();
    expect(OfflineStore.isDownloaded(base), isTrue);
    expect(prefs.getString('offline.index.v1'), isNull);
    expect(prefs.getString('offline.index.v1.carol'), isNotNull);

    AuthStore.instance.username = 'dave';
    await OfflineStore.reloadForUserSwitch();
    expect(OfflineStore.isDownloaded(base), isFalse);
  });
}
