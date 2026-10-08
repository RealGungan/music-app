import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/now_playing.dart' show durationLabel;
import 'package:nasmusic/playback_engine.dart';
import 'package:nasmusic/queue_player.dart' show QueuePlayer, skinShowsPlaying;

String _fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = (d.inSeconds.remainder(60)).toString().padLeft(2, '0');
  return '$m:$s';
}

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

  group('player-screen duration label (late stream metadata)', () {
    test('unknown duration shows –:––, not 00:00', () {
      expect(durationLabel(Duration.zero, _fmt), '–:––');
      expect(durationLabel(const Duration(milliseconds: -1), _fmt), '–:––');
    });
    test('known duration formats normally', () {
      expect(durationLabel(const Duration(minutes: 3, seconds: 7), _fmt),
          '03:07');
      expect(
          durationLabel(const Duration(seconds: 1), _fmt), '00:01');
    });
  });

  group('skin truth: native state-stream is sole truth', () {
    test('any start -> playing; any stoppage -> paused', () {
      expect(skinShowsPlaying(PlayerState.playing, lastPlaying: false), true);
      for (final s in [
        PlayerState.paused,
        PlayerState.stopped,
        PlayerState.completed,
        PlayerState.disposed,
      ]) {
        expect(skinShowsPlaying(s, lastPlaying: true), false,
            reason: '${s.name} must show paused icon');
      }
    });

    test('buffering (null) keeps last icon', () {
      expect(skinShowsPlaying(null, lastPlaying: true), true);
      expect(skinShowsPlaying(null, lastPlaying: false), false);
    });

    test('delayed spinner past 800ms only', () {
      expect(QueuePlayer.kSpinnerDelay, const Duration(milliseconds: 800));
    });

    test('native-pause => skin paused with no Dart event', () async {
      final e = RemoteEngine();
      addTearDown(e.dispose);
      final seen = <PlayerState>[];
      final sub = e.onPlayerStateChanged.listen(seen.add);
      // Native start (no Dart play() call): skin shows playing.
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      await Future<void>.delayed(Duration.zero);
      expect(e.isPlaying, isTrue);
      expect(skinShowsPlaying(seen.last, lastPlaying: false), true);
      // Native stoppage by any means (e.g. MediaPlayer-JNI pause on focus
      // loss fires outside Dart): no Dart pause() call here, yet the skin
      // must flip to paused from the stream event alone.
      e.feedRemoteEvent({'ev': 'state', 's': 'paused'});
      await Future<void>.delayed(Duration.zero);
      expect(e.isPlaying, isFalse);
      expect(seen.last, PlayerState.paused);
      expect(skinShowsPlaying(seen.last, lastPlaying: true), false);
      await sub.cancel();
    });
  });
}
