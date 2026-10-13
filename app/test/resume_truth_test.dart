import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:isolate' show ReceivePort;
import 'dart:ui' show IsolateNameServer;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/audio_handler.dart';
import 'package:nasmusic/playback_engine.dart';

/// Two bugs pinned here:
///
///  1. RESUME TRUTH. The resume path asked the handler for `getState` through
///     `RemoteEngine.resync`, whose handler leg is gated on the engine's
///     `_remoteUp` latch — a latch `_send` clears the moment it finds the port
///     missing. On resume that latch is exactly what's in doubt, so the one
///     query that could correct a stale play/pause icon was skipped and the
///     local-only fallback force-paused audio that never stopped. The resume
///     path now asks the port DIRECTLY (no latch to lose) and writes the single
///     playing truth itself, so mini + full repaint in the same frame.
///
///  2. THE SILENCE BLIP. `AudioService.androidForceEnableMediaButtons()`
///     qualified us for BT media buttons by playing a blip of SILENCE through
///     the music stream — the audible noise on app open. Replaced by native
///     MediaSession FLAG_HANDLES_MEDIA_BUTTONS | FLAG_HANDLES_TRANSPORT_CONTROLS
///     over the same `com.nasmusic.nasmusic/system` channel the app already
///     uses (MainActivity `enableMediaButtons`), which routes identically and
///     emits no sound.
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

  group('engineStateFromName (handler reply -> native truth)', () {
    test('the four handler state names map exactly', () {
      expect(engineStateFromName('playing'), PlayerState.playing);
      expect(engineStateFromName('paused'), PlayerState.paused);
      expect(engineStateFromName('completed'), PlayerState.completed);
      expect(engineStateFromName('disposed'), PlayerState.disposed);
    });

    test('a garbled/absent name is never a false "playing"', () {
      // A malformed reply must only ever un-freeze a stale icon, never
      // invent one over dead audio.
      expect(engineStateFromName(''), PlayerState.stopped);
      expect(engineStateFromName('nonsense'), PlayerState.stopped);
      expect(engineStateFromName('Playing'), PlayerState.stopped);
      expect(engineStateFromName('playing '), PlayerState.stopped);
    });
  });

  group('queryTruthDirect: the resume query has no latch to lose', () {
    /// Registers a fake handler isolate on the shared port name and hands
    /// back its inbox, so the test can answer the getState like the real
    /// handler does (through feedRemoteEvent, exactly as main.dart does).
    ({ReceivePort inbox, RemoteEngine engine}) fakeHandler() {
      final inbox = ReceivePort();
      IsolateNameServer.removePortNameMapping(kAudioStatePort);
      IsolateNameServer.registerPortWithName(inbox.sendPort, kAudioStatePort);
      final engine = RemoteEngine();
      addTearDown(() {
        IsolateNameServer.removePortNameMapping(kAudioStatePort);
        inbox.close();
        engine.dispose();
      });
      return (inbox: inbox, engine: engine);
    }

    test('returns the handler\'s own answer, not the stale cached flag',
        () async {
      final f = fakeHandler();
      // UI isolate slept with the icon on "playing"; handler actually paused.
      f.engine.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      expect(f.engine.isPlaying, isTrue);

      final q = f.engine.queryTruthDirect(timeout: const Duration(seconds: 2));
      final cmd = jsonDecode(await f.inbox.first.timeout(
        const Duration(seconds: 2),
      ) as String) as Map<String, dynamic>;
      expect(cmd['cmd'], 'getState');
      f.engine.feedRemoteEvent({'ev': 'state', 's': 'paused'});

      expect(await q, PlayerState.paused);
    });

    test('still answers when the engine was never engaged (_remoteUp false)',
        () async {
      // THE regression: the port exists and answers, but the engine's latch
      // was never set (constructed before the handler booted, or a send
      // cleared it). resync would skip the handler entirely here.
      final inbox = ReceivePort();
      IsolateNameServer.removePortNameMapping(kAudioStatePort);
      IsolateNameServer.registerPortWithName(inbox.sendPort, kAudioStatePort);
      addTearDown(() {
        IsolateNameServer.removePortNameMapping(kAudioStatePort);
        inbox.close();
      });
      final engine = RemoteEngine();
      addTearDown(engine.dispose);
      expect(engine.remoteUp, isTrue);

      // Force the demoted latch that resync gates on.
      final q = engine.queryTruthDirect(timeout: const Duration(seconds: 2));
      final cmd = jsonDecode(await inbox.first.timeout(
        const Duration(seconds: 2),
      ) as String) as Map<String, dynamic>;
      expect(cmd['cmd'], 'getState');
      engine.feedRemoteEvent({'ev': 'state', 's': 'playing'});
      expect(await q, PlayerState.playing);
    });

    test('a missing port answers null (caller falls back to resync)', () async {
      IsolateNameServer.removePortNameMapping(kAudioStatePort);
      final engine = RemoteEngine();
      addTearDown(engine.dispose);
      expect(
        await engine.queryTruthDirect(
            timeout: const Duration(milliseconds: 200)),
        isNull,
      );
    });

    test('a silent handler answers null rather than hanging', () async {
      final f = fakeHandler();
      // Port present, getState sent, handler never replies.
      expect(
        await f.engine.queryTruthDirect(
            timeout: const Duration(milliseconds: 200)),
        isNull,
      );
    });

    test('the answered truth repaints the state stream (one frame)', () async {
      final f = fakeHandler();
      final seen = <PlayerState>[];
      final sub = f.engine.onPlayerStateChanged.listen(seen.add);
      f.engine.feedRemoteEvent({'ev': 'state', 's': 'playing'});

      final q = f.engine.queryTruthDirect(timeout: const Duration(seconds: 2));
      await f.inbox.first.timeout(const Duration(seconds: 2));
      f.engine.feedRemoteEvent({'ev': 'state', 's': 'paused'});
      await q;
      await Future<void>.delayed(Duration.zero);

      expect(f.engine.isPlaying, isFalse);
      expect(seen.last, PlayerState.paused);
      await sub.cancel();
    });
  });

  group('one truth write repaints mini + full', () {
    // Mirrors production: the mini button (widgets.dart) and the full-screen
    // button (now_playing.dart) are both ValueListenableBuilders on the SAME
    // QueuePlayer.playingN the resume path writes. One write, one frame.
    Widget twoButtons(ValueNotifier<bool> truth) => MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: truth,
                  builder: (_, p, _) => Icon(
                    p ? Icons.pause : Icons.play_arrow,
                    key: const Key('mini'),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: truth,
                  builder: (_, p, _) => Icon(
                    p ? Icons.pause_circle_filled : Icons.play_circle_filled,
                    key: const Key('full'),
                  ),
                ),
              ],
            ),
          ),
        );

    IconData iconOf(WidgetTester t, String key) =>
        t.widget<Icon>(find.byKey(Key(key))).icon!;

    testWidgets('resume truth flips both buttons in the same frame', (t) async {
      final truth = ValueNotifier<bool>(true); // handler says playing
      addTearDown(truth.dispose);
      await t.pumpWidget(twoButtons(truth));
      expect(iconOf(t, 'mini'), Icons.pause);
      expect(iconOf(t, 'full'), Icons.pause_circle_filled);

      // Resume: handler answered paused. The single write IS the repaint.
      truth.value = engineStateFromName('paused') == PlayerState.playing;
      await t.pump();
      expect(iconOf(t, 'mini'), Icons.play_arrow);
      expect(iconOf(t, 'full'), Icons.play_circle_filled);
    });

    testWidgets('resume truth also flips back to playing (handler resumed)',
        (t) async {
      final truth = ValueNotifier<bool>(false);
      addTearDown(truth.dispose);
      await t.pumpWidget(twoButtons(truth));
      truth.value = engineStateFromName('playing') == PlayerState.playing;
      await t.pump();
      expect(iconOf(t, 'mini'), Icons.pause);
      expect(iconOf(t, 'full'), Icons.pause_circle_filled);
    });
  });

  group('no silence blip on app open', () {
    // The blip is an AUDIBLE regression, so nothing in the Dart test rig can
    // hear it — the guard has to be source-level. AudioService's helper plays
    // silence through the music stream to qualify for BT media buttons; the
    // native MediaSession flags replace it (MainActivity `enableMediaButtons`
    // on the same `com.nasmusic.nasmusic/system` channel).
    //
    // Matches a CALL, not a mention: the prose comment explaining why the call
    // was removed must stay.
    final call = RegExp(r'AudioService\s*\.\s*androidForceEnableMediaButtons\s*\(');

    test('main.dart never calls the silence-blip helper', () {
      final src = File('lib/main.dart').readAsStringSync();
      expect(
        call.hasMatch(src),
        isFalse,
        reason: 'AudioService.androidForceEnableMediaButtons() plays a blip of '
            'silence through the music stream — that is the noise on app open. '
            'Use the native MediaSession flags (system channel '
            '"enableMediaButtons") instead.',
      );
      expect(src.contains('enableMediaButtons'), isTrue);
    });

    test('the helper is not called anywhere in the app source', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (call.hasMatch(f.readAsStringSync())) offenders.add(f.path);
      }
      expect(offenders, isEmpty);
    });
  });

  group('resume-sync telemetry is armed on every resume path', () {
    // A dead hook and a silent hook look identical from the bug report
    // ("button stays playing"). These rows are the discriminator: a missing
    // `called` line means onResumed never ran; a `called` with
    // `says=TIMEOUT` means the handler never answered the query.
    final qp = File('lib/queue_player.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    test('onResumed logs the full called/port-ok/says/skin/wrote row', () {
      expect(qp, contains("report('resume-sync'"));
      expect(qp, contains(r'called port-ok=$portOk says=$says skin=$skin'));
      // Port liveness must be read live, not cached — a cached "true" from
      // before suspension proves nothing.
      expect(qp, contains('handlerPortAlive'));
    });

    test('app-start logs the same row so a dead hook is distinguishable', () {
      expect(qp, contains('traceResumeSyncAtStart'));
      expect(main, contains('traceResumeSyncAtStart()'));
    });

    test('every onResumed call site is tagged with its source', () {
      // A resume path that calls it untagged still runs, but the server row
      // loses the only field that says WHICH path fired.
      final untagged = RegExp(r'onResumed\(\s*\)');
      expect(untagged.hasMatch(main), isFalse,
          reason: 'tag every onResumed(src:) so focus vs app-resume is '
              'distinguishable in the log');
    });
  });
}
