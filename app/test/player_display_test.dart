import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/api_client.dart' show ResolvedName;
import 'package:nasmusic/audio_handler.dart' show publishedDurationMs;
import 'package:nasmusic/now_playing.dart' show durationLabel;
import 'package:nasmusic/playback_engine.dart';
import 'package:nasmusic/queue_player.dart'
    show
        QueuePlayer,
        durationMsFor,
        skinMismatch,
        skinMismatchMessage,
        skinShowsPlaying;

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

  group('known-duration seed (never blank while pos advances)', () {
    test('durationMsFor: positive seconds -> ms, else null', () {
      expect(durationMsFor(215), 215000);
      expect(durationMsFor(null), isNull);
      expect(durationMsFor(0), isNull);
      expect(durationMsFor(-5), isNull);
    });
    test('seeded total formats, never –:––', () {
      final seed = durationMsFor(215)!;
      expect(durationLabel(Duration(milliseconds: seed), _fmt), '03:35');
    });
    test('publishedDurationMs: measured wins, hint fills zero, else zero',
        () {
      expect(publishedDurationMs(streamMs: 214000, hintMs: 215000), 214000);
      expect(publishedDurationMs(streamMs: 0, hintMs: 215000), 215000);
      expect(publishedDurationMs(streamMs: 0, hintMs: null), 0);
      expect(publishedDurationMs(streamMs: 0, hintMs: 0), 0);
    });
    test('ResolvedName carries duration_s from the resolve response', () {
      final r = ResolvedName.fromJson({
        'url': 'u',
        'video_id': 'v',
        'duration_s': 215,
      });
      expect(r.durationS, 215);
      expect(durationMsFor(r.durationS), 215000);
      final missing = ResolvedName.fromJson({'url': 'u', 'video_id': 'v'});
      expect(missing.durationS, isNull);
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

    test('watchdog: mismatch fires only on skin vs direct-truth split', () {
      expect(skinMismatch(skinShows: true, nativePlaying: true), false);
      expect(skinMismatch(skinShows: false, nativePlaying: false), false);
      expect(skinMismatch(skinShows: true, nativePlaying: false), true);
      expect(skinMismatch(skinShows: false, nativePlaying: true), true);
    });

    test('watchdog log carries kind/state/expected', () {
      final m = skinMismatchMessage(
        skinShows: true,
        nativePlaying: false,
        engine: 'playing',
        handler: 'paused',
      );
      expect(m, contains('playing'));
      expect(m, contains('paused'));
      expect(m, contains('skin='));
      expect(m, contains('expected='));
    });
  });
}
