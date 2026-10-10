import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/playback_engine.dart';
import 'package:nasmusic/queue_player.dart';

/// Screen-off auto-advance regression: with the UI isolate suspended (no Dart
/// timers, no widget callbacks) the ONLY thing that can start the next track
/// is the handler isolate self-starting the pre-pushed URL on natural
/// completion. These tests pin:
///  1. the pre-push target selector (repeat / next / wrap),
///  2. placeholder next rows resolve instead of being skipped (the stall),
///  3. the handler->queue 'advanced' channel works with no timers/UI.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'), (c) async => null);
    m.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'),
        (c) async => null);
  });

  group('prePushIndex (screen-off advance target)', () {
    test('advances to the next row', () {
      expect(prePushIndex(len: 3, index: 0, repeat: false), 1);
    });
    test('repeat-one replays the current row', () {
      expect(prePushIndex(len: 3, index: 1, repeat: true), 1);
    });
    test('wraps at the queue end (mirrors next())', () {
      expect(prePushIndex(len: 3, index: 2, repeat: false), 0);
    });
    test('single-item queue wraps to itself', () {
      expect(prePushIndex(len: 1, index: 0, repeat: false), 0);
    });
    test('empty/invalid queue cannot advance', () {
      expect(prePushIndex(len: 0, index: 0, repeat: false), -1);
      expect(prePushIndex(len: 3, index: -1, repeat: false), -1);
      expect(prePushIndex(len: 3, index: 3, repeat: false), -1);
    });
  });

  group('needsPushResolve (placeholder next must resolve, never skip)', () {
    test('empty url needs resolve', () {
      expect(needsPushResolve(QueueItem('A - T', '')), isTrue);
    });
    test('resolve placeholder needs resolve', () {
      expect(
          needsPushResolve(
              QueueItem('A - T', '/staging/resolve/xyz', videoId: 'xyz')),
          isTrue);
    });
    test('lazy artist+title row needs resolve', () {
      expect(
          needsPushResolve(QueueItem('A - T', '',
              resolveName: (artist: 'A', title: 'T'))),
          isTrue);
    });
    test('direct NAS / relay / file urls need nothing', () {
      expect(
          needsPushResolve(
              QueueItem('A - T', 'http://nas/staging/file/a.mp3')),
          isFalse);
      expect(
          needsPushResolve(
              QueueItem('A - T', 'http://nas/staging/api/stream?vid=x')),
          isFalse);
      expect(needsPushResolve(QueueItem('A - T', 'file:///a.mp3')), isFalse);
    });
  });

  group('headless advance channel (no timers, no UI)', () {
    test('handler advanced event reaches the queue headless', () async {
      final e = RemoteEngine();
      addTearDown(e.dispose);
      final fut = e.onTrackAdvanced.first;
      // What the handler isolate sends on completion with the UI asleep.
      e.feedRemoteEvent({'ev': 'advanced', 'url': 'http://x/next.mp3'});
      expect(
          await fut.timeout(const Duration(seconds: 2)), 'http://x/next.mp3');
    });
    test('legacy complete still surfaces when nothing was pre-pushed',
        () async {
      final e = RemoteEngine();
      addTearDown(e.dispose);
      final fut = e.onPlayerComplete.first;
      e.feedRemoteEvent({'ev': 'complete'});
      await fut.timeout(const Duration(seconds: 2));
    });
  });
}
