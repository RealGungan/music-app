import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/playback_engine.dart';

/// The lying-button regression: the visible widget used to read a DIFFERENT
/// state object (per-button stream snapshot seeded from a cached bool)
/// than the one the stream/poll/watchdog updated, so mini and full buttons
/// could disagree in the same frame after a native pause. Now every button
/// listens to ONE `ValueNotifier<bool>` owned by the player layer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUpAll(() {
    m.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'), (c) async => null);
    m.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'),
        (c) async => null);
  });

  group('engine bool and stream never split (single truth source)', () {
    test('paused event flips both together, no Dart pause() call', () async {
      final e = RemoteEngine();
      addTearDown(e.dispose);
      final seen = <PlayerState>[];
      final sub = e.onPlayerStateChanged.listen(seen.add);
      // Native start outside Dart, then a native MediaPlayer-JNI pause on
      // focus loss — again with no Dart call in between.
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      e.feedRemoteEvent({'ev': 'state', 's': 'paused'});
      await Future<void>.delayed(Duration.zero);
      expect(e.isPlaying, isFalse);
      expect(seen.last, PlayerState.paused);
      expect(e.isPlaying, seen.last == PlayerState.playing);
      await sub.cancel();
    });

    test('focus-loss report alone syncs both (event lost while asleep)',
        () async {
      final e = RemoteEngine();
      addTearDown(e.dispose);
      final seen = <PlayerState>[];
      final sub = e.onPlayerStateChanged.listen(seen.add);
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      e.feedRemoteEvent({
        'ev': 'focus',
        'phase': 'lost-honored',
        'type': 'AudioInterruptionType.unknown',
      });
      await Future<void>.delayed(Duration.zero);
      expect(e.isPlaying, isFalse);
      expect(seen.last, PlayerState.paused);
      expect(e.isPlaying, seen.last == PlayerState.playing);
      await sub.cancel();
    });
  });

  group('two buttons, one notifier, same frame', () {
    // Mirrors production: mini + full buttons are both
    // ValueListenableBuilder<bool> on the SAME object (QueuePlayer.playingN).
    Widget twoButtons(ValueNotifier<bool> truth) => MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: truth,
                  builder: (ctx, p, w) => Icon(
                      p ? Icons.pause : Icons.play_arrow,
                      key: const Key('mini')),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: truth,
                  builder: (ctx, p, w) => Icon(
                      p ? Icons.pause_circle_filled : Icons.play_circle_fill,
                      key: const Key('full')),
                ),
              ],
            ),
          ),
        );

    IconData iconOf(WidgetTester t, String key) =>
        t.widget<Icon>(find.byKey(Key(key))).icon!;

    testWidgets('agree on pause icon while playing', (t) async {
      final truth = ValueNotifier<bool>(true); // native playing
      addTearDown(truth.dispose);
      await t.pumpWidget(twoButtons(truth));
      expect(iconOf(t, 'mini'), Icons.pause);
      expect(iconOf(t, 'full'), Icons.pause_circle_filled);
    });

    testWidgets('agree on play icon after native pause, one frame',
        (t) async {
      final truth = ValueNotifier<bool>(true); // native playing
      addTearDown(truth.dispose);
      await t.pumpWidget(twoButtons(truth));
      // Native pause lands outside Dart: single write, no stream event,
      // no seed, no per-button snapshot — one pump must flip both.
      truth.value = false;
      await t.pump();
      expect(iconOf(t, 'mini'), Icons.play_arrow);
      expect(iconOf(t, 'full'), Icons.play_circle_fill);
    });
  });
}
