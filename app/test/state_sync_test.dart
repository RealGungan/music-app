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

    test('regained-stay-paused forces paused without a state event', () async {
      final e = RemoteEngine();
      final seen = <PlayerState>[];
      final sub = e.onPlayerStateChanged.listen(seen.add);
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      // User paused mid-interruption: handler stays paused on regain and the
      // player-state event dies while the UI sleeps — the focus report alone
      // must sync the icon.
      e.feedRemoteEvent({
        'ev': 'focus',
        'phase': 'regained-stay-paused',
        'type': 'AudioInterruptionType.unknown',
      });
      expect(e.isPlaying, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(seen.last, PlayerState.paused);
      await sub.cancel();
      e.dispose();
    });

    test('regained forces playing without a state event', () async {
      final e = RemoteEngine();
      final seen = <PlayerState>[];
      final sub = e.onPlayerStateChanged.listen(seen.add);
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      e.feedRemoteEvent({
        'ev': 'focus',
        'phase': 'lost-honored',
        'type': 'AudioInterruptionType.pause',
      });
      expect(e.isPlaying, isFalse);
      // Call ended, handler resumes: force playing from the callback alone.
      e.feedRemoteEvent({
        'ev': 'focus',
        'phase': 'regained',
        'type': 'AudioInterruptionType.pause',
      });
      expect(e.isPlaying, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(seen.last, PlayerState.playing);
      await sub.cancel();
      e.dispose();
    });

    test('duck phases never touch play state', () {
      final e = RemoteEngine();
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      e.feedRemoteEvent({'ev': 'focus', 'phase': 'ducked'});
      expect(e.isPlaying, isTrue);
      e.feedRemoteEvent({'ev': 'focus', 'phase': 'unducked'});
      expect(e.isPlaying, isTrue);
      e.dispose();
    });
  });

  group('pause ack (never-paused guard)', () {
    test('pause-dropped only when no ack after retry', () {
      expect(pauseDropDiagnostic(acked: true), isNull);
      expect(pauseDropDiagnostic(acked: false), 'pause-dropped');
    });

    test('acked pause sends cmd and needs no retry', () async {
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
      final got = <Map<String, dynamic>>[];
      final sub = inbox.listen((m) {
        got.add(jsonDecode(m as String) as Map<String, dynamic>);
      });
      final pausing = e.pause();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(got.isNotEmpty, isTrue);
      expect(got[0]['cmd'], 'pause');
      e.feedRemoteEvent({'ev': 'state', 's': 'paused'});
      await pausing.timeout(const Duration(seconds: 2));
      expect(got.where((c) => c['cmd'] == 'pause').length, 1);
      await sub.cancel();
    });
  });

  group('shouldAutoResumeOnRegain', () {
    test('user pause wins over transient regain', () {
      expect(
          shouldAutoResumeOnRegain(
              userPaused: true,
              hasMedia: true,
              playing: false,
              currentUrl: 'http://x/song'),
          isFalse);
    });

    test('focus-loss auto-pause still resumes', () {
      expect(
          shouldAutoResumeOnRegain(
              userPaused: false,
              hasMedia: true,
              playing: false,
              currentUrl: 'http://x/song'),
          isTrue);
    });

    test('already playing / no media / no url never resume', () {
      const no = false;
      expect(
          shouldAutoResumeOnRegain(
              userPaused: no,
              hasMedia: true,
              playing: true,
              currentUrl: 'http://x/song'),
          isFalse);
      expect(
          shouldAutoResumeOnRegain(
              userPaused: no,
              hasMedia: false,
              playing: false,
              currentUrl: 'http://x/song'),
          isFalse);
      expect(
          shouldAutoResumeOnRegain(
              userPaused: no, hasMedia: true, playing: false, currentUrl: ''),
          isFalse);
      expect(
          shouldAutoResumeOnRegain(
              userPaused: no,
              hasMedia: true,
              playing: false,
              currentUrl: null),
          isFalse);
    });
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

  group('resume ack (backgrounded-toggle guard)', () {
    test('resume-dropped only when no ack after retry', () {
      expect(resumeDropDiagnostic(acked: true), isNull);
      expect(resumeDropDiagnostic(acked: false), 'resume-dropped');
    });

    test('acked resume sends cmd and needs no retry', () async {
      final inbox = ReceivePort();
      IsolateNameServer.removePortNameMapping(kAudioStatePort);
      IsolateNameServer.registerPortWithName(inbox.sendPort, kAudioStatePort);
      addTearDown(() {
        IsolateNameServer.removePortNameMapping(kAudioStatePort);
        inbox.close();
      });
      final e = RemoteEngine();
      addTearDown(e.dispose);
      // Backgrounded paused engine (notification toggle resumes it).
      e.feedRemoteEvent({'ev': 'state', 's': 'paused'});
      expect(e.isPlaying, isFalse);
      final got = <Map<String, dynamic>>[];
      final sub = inbox.listen((m) {
        got.add(jsonDecode(m as String) as Map<String, dynamic>);
      });
      final resuming = e.resume();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(got.isNotEmpty, isTrue);
      expect(got[0]['cmd'], 'resume');
      e.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      await resuming.timeout(const Duration(seconds: 2));
      expect(got.where((c) => c['cmd'] == 'resume').length, 1);
      await sub.cancel();
    });

    test('dropped resume retries once, then logs resume-dropped', () async {
      final inbox = ReceivePort();
      IsolateNameServer.removePortNameMapping(kAudioStatePort);
      IsolateNameServer.registerPortWithName(inbox.sendPort, kAudioStatePort);
      addTearDown(() {
        IsolateNameServer.removePortNameMapping(kAudioStatePort);
        inbox.close();
      });
      final e = RemoteEngine();
      addTearDown(e.dispose);
      e.feedRemoteEvent({'ev': 'state', 's': 'paused'});
      final got = <Map<String, dynamic>>[];
      final sub = inbox.listen((m) {
        got.add(jsonDecode(m as String) as Map<String, dynamic>);
      });
      // No playing ack ever arrives (handler died mid-toggle): exactly two
      // resume cmds (initial + one retry), then the drop is logged.
      await e.resume();
      expect(got.where((c) => c['cmd'] == 'resume').length, 2);
      await sub.cancel();
    });

    test('resume from stopped needs no ack wait (no-op, like before)', () async {
      final inbox = ReceivePort();
      IsolateNameServer.removePortNameMapping(kAudioStatePort);
      IsolateNameServer.registerPortWithName(inbox.sendPort, kAudioStatePort);
      addTearDown(() {
        IsolateNameServer.removePortNameMapping(kAudioStatePort);
        inbox.close();
      });
      final e = RemoteEngine();
      addTearDown(e.dispose);
      e.feedRemoteEvent({'ev': 'state', 's': 'stopped'});
      final got = <Map<String, dynamic>>[];
      final sub = inbox.listen((m) {
        got.add(jsonDecode(m as String) as Map<String, dynamic>);
      });
      await e.resume().timeout(const Duration(seconds: 2));
      // Port delivery is async: pump before reading, else the buffered
      // resume cmd hasn't landed and the count reads 0.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(got.where((c) => c['cmd'] == 'resume').length, 1);
      await sub.cancel();
    });

    test('toggleRecover replays last url from stopped (surface destroyed)',
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
      final got = <Map<String, dynamic>>[];
      final sub = inbox.listen((m) {
        got.add(jsonDecode(m as String) as Map<String, dynamic>);
      });
      await e.play('http://x/song');
      // Surface destroyed / service restarted: player reset to stopped.
      e.feedRemoteEvent({'ev': 'state', 's': 'stopped'});
      // Nobody answers getState: resync times out, truth stays stopped.
      await e.toggleRecover(timeout: const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      // Initial play + the replay; resume() would no-op on a released
      // player, so no resume cmd may be sent.
      expect(
          got
              .where((c) =>
                  c['cmd'] == 'play' && c['url'] == 'http://x/song')
              .length,
          2);
      expect(got.any((c) => c['cmd'] == 'resume'), isFalse);
    });
  });
}
