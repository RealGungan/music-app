import 'dart:convert';
import 'dart:isolate' show ReceivePort;
import 'dart:ui' show IsolateNameServer;

import 'package:audio_session/audio_session.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/audio_handler.dart';
import 'package:nasmusic/playback_engine.dart';

/// Pins the interruption contract: external music/video apps steal focus
/// (permanent loss, type `unknown`) and must stay stolen — no auto-resume
/// fighting the user's app, no frozen play icon on return.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // AudioPlayer() creates its platform player in the constructor; swallow
    // it so RemoteEngine/LocalEngine construct with no device.
    m.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'), (c) async => null);
    m.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'),
        (c) async => null);
  });

  group('carFocusAction mapping', () {
    test('nav duck/restoreDuck round-trip', () {
      expect(
          carFocusAction(
              begin: true, type: AudioInterruptionType.duck),
          CarFocusAction.duck);
      expect(
          carFocusAction(
              begin: false, type: AudioInterruptionType.duck),
          CarFocusAction.restoreDuck);
    });

    test('permanent takeover pauses; regain reports resume (handler holds it)', () {
      // Android AUDIOFOCUS_LOSS arrives as type unknown: pause now, and the
      // handler's _focusLostPermanent gate turns the regain into stay-paused.
      expect(
          carFocusAction(
              begin: true, type: AudioInterruptionType.unknown),
          CarFocusAction.pause);
      expect(
          carFocusAction(
              begin: false, type: AudioInterruptionType.unknown),
          CarFocusAction.resume);
    });

    test('transient call pause/resume round-trip', () {
      expect(
          carFocusAction(
              begin: true, type: AudioInterruptionType.pause),
          CarFocusAction.pause);
      expect(
          carFocusAction(
              begin: false, type: AudioInterruptionType.pause),
          CarFocusAction.resume);
    });
  });

  group('RemoteEngine state sync', () {
    test('state events drive isPlaying', () async {
      final e = RemoteEngine();
      final seen = <PlayerState>[];
      final sub = e.onPlayerStateChanged.listen(seen.add);
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      expect(e.isPlaying, isTrue);
      e.feedRemoteEvent({'ev': 'state', 's': 'paused'});
      expect(e.isPlaying, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [PlayerState.playing, PlayerState.paused]);
      await sub.cancel();
      e.dispose();
    });

    test('honored focus loss pauses even when the state event is missed', () async {
      final e = RemoteEngine();
      final seen = <PlayerState>[];
      final sub = e.onPlayerStateChanged.listen(seen.add);
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      expect(e.isPlaying, isTrue);
      // External app took over while the UI isolate slept: the handler
      // paused + reported focus, the player-state event never arrived.
      // The focus report alone must sync the icon.
      e.feedRemoteEvent({
        'ev': 'focus',
        'phase': 'lost-honored',
        'type': 'AudioInterruptionType.unknown',
      });
      expect(e.isPlaying, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(seen.last, PlayerState.paused);
      await sub.cancel();
      e.dispose();
    });

    test('ignored self-echo leaves state untouched', () {
      final e = RemoteEngine();
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      e.feedRemoteEvent({
        'ev': 'focus',
        'phase': 'lost-ignored',
        'type': 'AudioInterruptionType.pause',
      });
      expect(e.isPlaying, isTrue);
      e.dispose();
    });

    test('pause/resume across app switches', () {
      final e = RemoteEngine();
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      // Switch to a video app: honored loss (+ the state event this time).
      e.feedRemoteEvent({
        'ev': 'focus',
        'phase': 'lost-honored',
        'type': 'AudioInterruptionType.unknown',
      });
      e.feedRemoteEvent({'ev': 'state', 's': 'paused'});
      expect(e.isPlaying, isFalse);
      // Back in our app, user taps play: truth follows the handler again.
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      expect(e.isPlaying, isTrue);
      e.dispose();
    });

    test('resync asks the handler and adopts its truth', () async {
      // Fake handler isolate inbox on the shared port name.
      final inbox = ReceivePort();
      IsolateNameServer.removePortNameMapping(kAudioStatePort);
      IsolateNameServer.registerPortWithName(inbox.sendPort, kAudioStatePort);
      addTearDown(() {
        IsolateNameServer.removePortNameMapping(kAudioStatePort);
        inbox.close();
      });
      final e = RemoteEngine();
      addTearDown(e.dispose);
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      expect(e.isPlaying, isTrue);
      final syncing = e.resync(timeout: const Duration(seconds: 2));
      final cmd = jsonDecode(await inbox.first.timeout(
        const Duration(seconds: 2),
      ) as String) as Map<String, dynamic>;
      expect(cmd['cmd'], 'getState');
      // Handler answers paused (external app owns focus now) via the same
      // bridge main.dart feeds — stale playing must clear.
      e.feedRemoteEvent({'ev': 'state', 's': 'paused'});
      await syncing;
      expect(e.isPlaying, isFalse);
    });

    test('resync with a dead handler falls back instead of freezing', () async {
      IsolateNameServer.removePortNameMapping(kAudioStatePort);
      final e = RemoteEngine();
      addTearDown(e.dispose);
      // Stale playing flag from before the handler was killed.
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      expect(e.isPlaying, isTrue);
      await e.resync(); // no port: correct from the idle local player.
      expect(e.isPlaying, isFalse);
    });

    test('suspended-event-loss: resync awaits truth so repaint lands first',
        () async {
      final inbox = ReceivePort();
      IsolateNameServer.removePortNameMapping(kAudioStatePort);
      IsolateNameServer.registerPortWithName(inbox.sendPort, kAudioStatePort);
      addTearDown(() {
        IsolateNameServer.removePortNameMapping(kAudioStatePort);
        inbox.close();
      });
      final e = RemoteEngine();
      addTearDown(e.dispose);
      final seen = <PlayerState>[];
      final sub = e.onPlayerStateChanged.listen(seen.add);
      // YT Music stole focus while the UI isolate slept: the pause state
      // event died, the cached flag still says playing (ghost icon).
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      expect(e.isPlaying, isTrue);
      // Resume: getState goes out, handler answers paused via the bridge.
      final syncing = e.resync(timeout: const Duration(seconds: 2));
      final cmd = jsonDecode(await inbox.first.timeout(
        const Duration(seconds: 2),
      ) as String) as Map<String, dynamic>;
      expect(cmd['cmd'], 'getState');
      e.feedRemoteEvent({'ev': 'state', 's': 'paused'});
      await syncing; // returns only AFTER the repaint event landed.
      expect(e.isPlaying, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(seen.last, PlayerState.paused);
      await sub.cancel();
    });

    test('single-tap-recover: stale playing + handler paused -> resume',
        () async {
      final inbox = ReceivePort();
      IsolateNameServer.removePortNameMapping(kAudioStatePort);
      IsolateNameServer.registerPortWithName(inbox.sendPort, kAudioStatePort);
      addTearDown(() {
        IsolateNameServer.removePortNameMapping(kAudioStatePort);
        inbox.close();
      });
      final e = RemoteEngine();
      addTearDown(e.dispose);
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      // One tap: truth first, then act on FRESH state. Answer the getState
      // with paused (external app owns focus) before the toggle resolves.
      // Single listener: ReceivePort is single-subscription, so collect.
      final got = <Map<String, dynamic>>[];
      Future<void> waitFor(int n) async {
        final t0 = DateTime.now();
        while (got.length < n) {
          if (DateTime.now().difference(t0) > const Duration(seconds: 2)) {
            fail('timed out waiting for handler cmd #$n (got ${got.length})');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      final tapped = e.toggleRecover(timeout: const Duration(seconds: 2));
      // getState goes out first; drain it via the collector below.
      final cmdSub = inbox.listen((m) {
        got.add(jsonDecode(m as String) as Map<String, dynamic>);
      });
      await waitFor(1); // getState
      expect(got[0]['cmd'], 'getState');
      e.feedRemoteEvent({'ev': 'state', 's': 'paused'});
      await tapped;
      await waitFor(2); // the toggle's decision
      await cmdSub.cancel();
      // Fresh state is paused -> the single tap RESUMES (never pauses
      // a ghost, which was the old double-tap).
      expect(got[1]['cmd'], 'resume');
      expect(e.isPlaying, isFalse); // resume cmd sent; state event pending.
    });
  });
}
