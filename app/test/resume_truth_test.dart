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

  group('getState answers from the REAL player, not a tracked flag', () {
    // audioplayers has NO native playback-state feedback: `AudioEventType` is
    // log/duration/seekComplete/complete/prepared, and `_player.state` is
    // written at exactly one place (the `set state` setter our own
    // play/pause/stop/resume call). So `_playing` AND `player.state` both just
    // mirror our last command — when another app takes the audio the native
    // player pauses with no Dart call in between and they keep answering
    // "playing" over dead audio. The native position clock is the only truth.
    test('an advancing clock outranks a stale "playing" flag', () {
      expect(
        realStateAnswer(
            firstMs: 12000, secondMs: 12300, trackedPlaying: true, trackedPaused: false),
        'playing',
      );
    });

    test('a frozen clock outranks a stale "playing" flag (the takeover)',
        () {
      // Another app took focus: the native player is paused, `_playing` is
      // still true from our last play() — the flag-based answer said
      // 'playing' over silence. The clock is frozen, so it is not playing.
      expect(
        realStateAnswer(
            firstMs: 12000, secondMs: 12000, trackedPlaying: true, trackedPaused: false),
        'paused',
        reason: 'a frozen native clock is the only proof an external app '
            'paused us — no flag and no player.state records it',
      );
    });

    test('a rewound clock (seek to 0) still reads as not-moving', () {
      expect(
        realStateAnswer(
            firstMs: 500, secondMs: 0, trackedPlaying: true, trackedPaused: false),
        'paused',
      );
    });

    test('a failed probe falls back to the tracked flags, never invents', () {
      // Nothing loaded / the platform query threw: don't manufacture a state.
      expect(
        realStateAnswer(
            firstMs: null, secondMs: null, trackedPlaying: true, trackedPaused: false),
        'playing',
      );
      expect(
        realStateAnswer(
            firstMs: null, secondMs: null, trackedPlaying: false, trackedPaused: true),
        'paused',
      );
      expect(
        realStateAnswer(
            firstMs: null, secondMs: null, trackedPlaying: false, trackedPaused: false),
        'stopped',
      );
      // One-sided failure is still a failure — no half-trusted answer.
      expect(
        realStateAnswer(
            firstMs: 900, secondMs: null, trackedPlaying: true, trackedPaused: false),
        'playing',
      );
    });

    // Source-level: the query can't run a real player in a unit test, so pin
    // the two facts that make it honest — it READS the real native clock, and
    // an honored focus loss forces the paused answer immediately.
    final src = File('lib/audio_handler.dart').readAsStringSync();
    final getState = src.substring(
      src.indexOf("case 'getState':"),
      src.indexOf("case 'seek':"),
    );
    final focusLoss = src.substring(
      src.indexOf('_focusLostPermanent ='),
      src.indexOf('focus-pause failed'),
    );

    test('the getState answer probes the native player, not the flags', () {
      // Comments explain WHY `_player.state`/`_playing` are wrong, so match
      // the CODE only — strip the line comments before the assertions.
      final code = getState
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code, contains('_realStateAnswer()'),
          reason: 'the real player is read through the native position probe');
      expect(code, isNot(contains(r"'s': _playing")),
          reason: "answering from the tracked _playing flag is the stale-flag "
              'lie — an external focus pause never reaches it');
      expect(code, isNot(contains('_player.state')),
          reason: '_player.state is assigned only by our own play/pause/stop/'
              'resume (audioplayers feeds no native playback state back), so it '
              'knows nothing the tracked flag does not — the bug stays fixed');
    });

    test('the probe actually reads the native clock twice', () {
      final probe = src.substring(
        src.indexOf('Future<int?> _probePositionMs()'),
        src.indexOf('Future<String> _realStateAnswer()'),
      );
      expect(probe, contains('getCurrentPosition()'),
          reason: 'a real platform query, not a cached flag');
    });

    test('a forced focus pause wins immediately, without probing', () {
      expect(getState, contains('_focusPaused'));
      expect(focusLoss, contains('_focusPaused = true'),
          reason: 'set _playing=false + the forced pause on AUDIOFOCUS_LOSS so '
              'any query after the takeover answers paused');
      // Cleared by every command that starts sound again, plus the player's
      // own playing event (which is also the audio_service play() path).
      expect(RegExp(r'_focusPaused = false').allMatches(src).length,
          greaterThanOrEqualTo(4));
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
