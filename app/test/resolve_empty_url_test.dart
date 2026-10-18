import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart' show PlayerState;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/playback_engine.dart';
import 'package:nasmusic/queue_player.dart' show QueueItem, QueuePlayer;
import 'package:shared_preferences/shared_preferences.dart';

/// A resolve that hands back '' is a DEAD row, not a playable URL. It must
/// take the null path (auto-skip / unplayable log) and never reach the engine
/// as play("") — an empty source wedges the queue on a silent track that will
/// not skip.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeEngine engine;
  var resolveUrl = '';
  final docs = Directory.systemTemp.createTempSync('nasmusic-test-');

  setUpAll(() {
    engine = _FakeEngine();
    QueuePlayer.engineOverride = engine;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    engine.plays.clear();
    resolveUrl = '';
    // The cache stores (PrefetchStore/OfflineStore) ask path_provider for the
    // documents dir; stub it so "no cached copy" is a real miss, not a throw.
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => docs.createTempSync().path,
    );
    QueuePlayer.instance
      ..isOffline.value = false
      ..nasLookup = null
      ..nameResolver = null
      ..resolver = (_) async => (url: resolveUrl, preview: false);
  });

  /// Row the lazy resolve must resolve: placeholder relay URL + video id.
  QueueItem cold(String vid) => QueueItem(
        'Artist - $vid',
        'http://nas:8004/staging/resolve/$vid',
        videoId: vid,
      );

  test('resolve returning "" never reaches the engine (no play(""))',
      () async {
    await QueuePlayer.instance.playOne(cold('a'));
    await pump();

    expect(engine.plays, isEmpty,
        reason: 'the dead row must be abandoned, not played as an empty URL');
    // Dead row was noticed: the spinner is released so later taps still work.
    expect(QueuePlayer.instance.loading.value, isFalse);
  });

  test('resolve returning "" auto-skips to the next warm row', () async {
    final warm = QueueItem('Artist - warm', 'https://cdn.example.com/w.mp3');
    await QueuePlayer.instance.playList([cold('a'), warm]);
    await pump();

    expect(QueuePlayer.instance.index, 1, reason: 'skipped the dead row');
    expect(engine.plays, ['https://cdn.example.com/w.mp3']);
  });

  test('a real resolved URL plays', () async {
    resolveUrl = 'https://cdn.example.com/good.mp3';
    await QueuePlayer.instance.playOne(cold('a'));
    await pump();

    expect(engine.plays, ['https://cdn.example.com/good.mp3']);
  });
}

/// Let every fire-and-forget chain in the play path settle.
Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 60));

/// Records exactly which URLs the queue hands to the audio backend.
class _FakeEngine implements PlaybackEngine {
  final plays = <String>[];
  final _states = StreamController<PlayerState>.broadcast();

  @override
  Future<void> play(String url, {int? durMs}) async => plays.add(url);
  @override
  Future<void> setSource(String url) async => plays.add(url);

  @override
  bool get isPlaying => false;
  @override
  Future<void> pause() async {}
  @override
  Future<void> pollTruth() async {}
  @override
  Future<void> queueNext({
    String? url,
    String? title,
    String? artist,
    String? album,
    int? durMs,
  }) async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> seek(Duration d) async {}
  @override
  Future<void> setVolume(double v) async {}
  @override
  Future<void> stop() async {}

  @override
  Stream<Duration> get onDurationChanged => const Stream.empty();
  @override
  Stream<String> get onError => const Stream.empty();
  @override
  Stream<void> get onPlayerComplete => const Stream.empty();
  @override
  Stream<PlayerState> get onPlayerStateChanged => _states.stream;
  @override
  Stream<Duration> get onPositionChanged => const Stream.empty();
  @override
  Stream<String> get onTrackAdvanced => const Stream.empty();
}