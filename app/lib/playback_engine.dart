import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:audioplayers/audioplayers.dart';

import 'audio_handler.dart';

/// Backend that actually produces audio. [QueuePlayer] talks only to this
/// interface, never to a raw audioplayers player, so the app can use either:
///
///  * [LocalEngine] — an audioplayers [AudioPlayer] living in the main UI
///    isolate (Linux desktop, where audio_service does not exist, and the
///    mobile fallback if the media-session service is unavailable).
///  * [RemoteEngine] — the audioplayers player inside the audio_service
///    handler isolate, which keeps playback alive when Android suspends the
///    UI isolate in the background.
///
/// The rest of the app is identical on both: the same 4 streams and the same
/// command methods.
abstract class PlaybackEngine {
  Stream<void> get onPlayerComplete;
  Stream<Duration> get onPositionChanged;
  Stream<Duration> get onDurationChanged;
  Stream<PlayerState> get onPlayerStateChanged;

  /// Async playback errors (e.g. an unreachable URL) surfaced to the queue.
  Stream<String> get onError;

  /// Fires when the handler isolate auto-advanced to a pre-pushed track
  /// on its own (gapless handoff while the UI isolate sleeps). Carries
  /// the URL it started, so the queue can adopt (or reject) it.
  Stream<String> get onTrackAdvanced;

  bool get isPlaying;

  Future<void> play(String url);
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> seek(Duration d);
  Future<void> setVolume(double v);

  /// Load a URL without starting playback (silent source refresh, e.g.
  /// after a network switch while paused — no audio blip).
  Future<void> setSource(String url);

  /// Pre-push the upcoming track for gapless handoff (no-op locally —
  /// the UI isolate never sleeps on desktop, so nothing needs it).
  Future<void> queueNext({
    String? url,
    String? title,
    String? artist,
    String? album,
  });
}

/// Audioplayers player in THIS (main) isolate — nothing remote about it.
class LocalEngine implements PlaybackEngine {
  final AudioPlayer _player;

  LocalEngine({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  AudioPlayer get player => _player;

  @override
  Stream<void> get onPlayerComplete => _player.onPlayerComplete;
  @override
  Stream<Duration> get onPositionChanged => _player.onPositionChanged;
  @override
  Stream<Duration> get onDurationChanged => _player.onDurationChanged;
  @override
  Stream<PlayerState> get onPlayerStateChanged => _player.onPlayerStateChanged;
  @override
  Stream<String> get onError => const Stream<String>.empty();
  @override
  Stream<String> get onTrackAdvanced => const Stream<String>.empty();
  @override
  bool get isPlaying => _player.state == PlayerState.playing;

  @override
  Future<void> play(String url) => _player.play(sourceForUrl(url));
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> resume() => _player.resume();
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> seek(Duration d) => _player.seek(d);
  @override
  Future<void> setSource(String url) =>
      _player.setSource(sourceForUrl(url));
  @override
  Future<void> queueNext({
    String? url,
    String? title,
    String? artist,
    String? album,
  }) async {
    // Local playback runs in the UI isolate, which never sleeps — the
    // normal completion path handles advancement. Nothing to pre-push.
  }
  @override
  Future<void> setVolume(double v) => _player.setVolume(v);

  @override
  void dispose() {
    _player.dispose();
  }
}

/// Mobile playback backend. Prefers the audioplayers player that lives inside
/// the audio_service handler isolate (so audio survives the UI isolate being
/// suspended in the background), and transparently falls back to a local
/// main-isolate player whenever the media-session service is not up (e.g.
/// AudioService.init failed or has not completed yet).
class RemoteEngine implements PlaybackEngine {
  RemoteEngine() {
    _local.onPlayerComplete.listen((_) {
      if (_remoteUp) return;
      _sbComplete.add(null);
    });
    _local.onPositionChanged.listen((d) {
      if (_remoteUp) return;
      _sbPos.add(d);
    });
    _local.onDurationChanged.listen((d) {
      if (_remoteUp) return;
      _sbDur.add(d);
    });
    _local.onPlayerStateChanged.listen((s) {
      _lastState = s;
      if (_remoteUp) return;
      _sbState.add(s);
    });
    // The audio_service handler (which owns the real audioplayers player and
    // registers a global IsolateNameServer port) may take a moment to boot on
    // cold start. Keep polling for its port until it appears, then go remote.
    _tryEngage();
    if (!_remoteUp) {
      _engageTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_remoteUp) {
          _engageTimer?.cancel();
          return;
        }
        _tryEngage();
      });
    }
    // Heartbeat to detect handler isolate death and re-engage.
    // Skipped bg+paused: the port lookup every 10s kept waking the app.
    _healthTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_remoteUp) return;
      if (WidgetsBinding.instance.lifecycleState !=
              AppLifecycleState.resumed &&
          _lastState != PlayerState.playing) return;
      if (IsolateNameServer.lookupPortByName(kAudioStatePort) == null) {
        debugPrint('[RemoteEngine] handler port lost - falling back to local');
        _remoteUp = false;
        _tryEngage();
      }
    });
  }

  /// Main-isolate player used until (and unless) the handler isolate is up.
  final LocalEngine _local = LocalEngine();

  bool _remoteUp = false;
  String? _lastUrl;
  PlayerState _lastState = PlayerState.stopped;
  DateTime _lastEventAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _engageTimer;
  Timer? _healthTimer;

  final _sbComplete = StreamController<void>.broadcast();
  final _sbPos = StreamController<Duration>.broadcast();
  final _sbDur = StreamController<Duration>.broadcast();
  final _sbState = StreamController<PlayerState>.broadcast();
  final _sbError = StreamController<String>.broadcast();
  final _sbAdvanced = StreamController<String>.broadcast();

  SendPort? get _handlerPort =>
      IsolateNameServer.lookupPortByName(kAudioStatePort);

  void _tryEngage() {
    if (_remoteUp || _handlerPort == null) return;
    _remoteUp = true;
    _engageTimer?.cancel();
    // Corner: the user hit play before the handler came up, so the local
    // player is already running. Re-issue the URL to the handler so audio
    // keeps flowing instead of going silent.
    if (_lastUrl != null &&
        (_local.isPlaying || _lastState == PlayerState.playing)) {
      _send({'cmd': 'play', 'url': _lastUrl});
    }
  }

  void _send(Map<String, dynamic> m) {
    final sp = _handlerPort;
    if (sp == null) {
      _remoteUp = false;
      return;
    }
    sp.send(jsonEncode(m));
  }

  /// State/event pushes arriving from the handler isolate.
  void feedRemoteEvent(Map<String, dynamic> m) {
    // Don't gate on _remoteUp - handler might be sending events even before
    // we officially engaged. Process all events to keep streams alive.
    switch (m['ev']) {
      case 'pos':
        _sbPos.add(
            Duration(milliseconds: (m['ms'] as num?)?.toInt() ?? 0));
        break;
      case 'dur':
        _sbDur.add(
            Duration(milliseconds: (m['ms'] as num?)?.toInt() ?? 0));
        break;
      case 'state':
        final s = _parseState(m['s']);
        _lastState = s;
        _lastEventAt = DateTime.now();
        _sbState.add(s);
        break;
      case 'complete':
        _sbComplete.add(null);
        break;
      case 'advanced':
        _sbAdvanced.add(m['url']?.toString() ?? '');
        break;
      case 'err':
        final msg = m['m']?.toString() ?? 'playback error';
        // Auth-tagged (expired ?token= 401) so the queue can bounce to
        // login instead of heal-looping.
        _sbError.add(m['auth'] == true ? 'AUTH401 $msg' : msg);
        break;
      case 'focus':
        // External app took focus and the handler honored it (paused). The
        // follow-up player-state event can be lost while the UI isolate
        // sleeps — force paused from the focus report alone so the icon
        // never freezes on "playing". Echo/ignored + regained phases need
        // nothing (player-state events carry those).
        if (m['phase'] == 'lost-honored') {
          _lastState = PlayerState.paused;
          _lastEventAt = DateTime.now();
          _sbState.add(PlayerState.paused);
        }
        break;
    }
  }

  static PlayerState _parseState(dynamic s) {
    switch (s) {
      case 'playing':
        return PlayerState.playing;
      case 'paused':
        return PlayerState.paused;
      case 'completed':
        return PlayerState.completed;
      case 'disposed':
        return PlayerState.disposed;
      default:
        return PlayerState.stopped;
    }
  }

  @override
  Stream<void> get onPlayerComplete => _sbComplete.stream;
  @override
  Stream<Duration> get onPositionChanged => _sbPos.stream;
  @override
  Stream<Duration> get onDurationChanged => _sbDur.stream;
  @override
  Stream<PlayerState> get onPlayerStateChanged => _sbState.stream;
  @override
  Stream<String> get onError => _sbError.stream;
  @override
  Stream<String> get onTrackAdvanced => _sbAdvanced.stream;
  @override
  bool get isPlaying => _lastState == PlayerState.playing;

  @override
  Future<void> play(String url) async {
    _lastUrl = url;
    _tryEngage();
    if (_remoteUp) {
      _lastState = PlayerState.stopped;
      _send({'cmd': 'play', 'url': url});
      return;
    }
    return _local.play(url);
  }

  @override
  Future<void> pause() async {
    // Re-engage first: a transient port flap demotes to local (see _send),
    // and only play/setSource/queueNext re-engaged — pause/resume/seek
    // would then act locally forever while the tray goes stale. Cheap
    // lookup, no-op when already engaged.
    _tryEngage();
    if (_remoteUp) {
      _send({'cmd': 'pause'});
      return;
    }
    return _local.pause();
  }

  @override
  Future<void> resume() async {
    _tryEngage();
    if (_remoteUp) {
      _send({'cmd': 'resume'});
      return;
    }
    return _local.resume();
  }

  /// Re-query the handler for truth (state/pos/dur) after UI resume. Awaits
  /// the handler's state reply (via [feedRemoteEvent]) so [_lastState] is
  /// forced + listeners repainted BEFORE this returns — the UI gates taps
  /// on that (QueuePlayer.stateSyncing), so no tap lands on a stale icon.
  /// Falls back to the local correction when the handler is gone/timeout.
  Future<void> resync(
      {Duration timeout = const Duration(milliseconds: 1200)}) async {
    _tryEngage();
    if (_remoteUp) {
      Future<PlayerState>? waiter;
      try {
        waiter = _sbState.stream.first.timeout(timeout);
      } catch (_) {
        waiter = null;
      }
      _send({'cmd': 'getState'});
      // The port can die between engage and send (_send demotes on miss):
      // fall through to the local correction below instead of leaving
      // _lastState stale.
      if (_remoteUp && waiter != null) {
        try {
          await waiter;
          return;
        } catch (_) {
          // Timeout: handler didn't answer — fall through to correction.
        }
      }
    }
    // Handler unreachable (killed while backgrounded): the local player is
    // the only truth left. A stale playing flag means dead audio with a
    // live icon — correct to paused and re-feed listeners. Anything else
    // is already non-playing; leave it alone.
    if (_lastState == PlayerState.playing && !_local.isPlaying) {
      _lastState = PlayerState.paused;
      _lastEventAt = DateTime.now();
      _sbState.add(PlayerState.paused);
    }
  }

  /// Single-tap recover: refresh truth first, then act on FRESH state.
  /// A stale cached playing (event died while suspended) becomes a resume,
  /// not a pause of a ghost — no double-tap.
  Future<void> toggleRecover(
      {Duration timeout = const Duration(milliseconds: 700)}) async {
    await resync(timeout: timeout);
    if (isPlaying) {
      await pause();
    } else {
      await resume();
    }
  }

  @override
  Future<void> stop() async {
    if (_remoteUp) {
      _send({'cmd': 'stop'});
      return;
    }
    return _local.stop();
  }

  @override
  Future<void> seek(Duration d) async {
    _tryEngage();
    if (_remoteUp) {
      _send({'cmd': 'seek', 'ms': d.inMilliseconds});
      return;
    }
    return _local.seek(d);
  }

  @override
  Future<void> setSource(String url) async {
    _lastUrl = url;
    _tryEngage();
    if (_remoteUp) {
      _send({'cmd': 'setSource', 'url': url});
      return;
    }
    return _local.setSource(url);
  }

  @override
  Future<void> queueNext({
    String? url,
    String? title,
    String? artist,
    String? album,
  }) async {
    _tryEngage();
    if (!_remoteUp) return;
    if (url == null || url.isEmpty) {
      _send({'cmd': 'setNext'});
      return;
    }
    _send({
      'cmd': 'setNext',
      'url': url,
      'title': title ?? '',
      'artist': artist ?? '',
      'album': album ?? '',
    });
  }

  @override
  Future<void> setVolume(double v) async {
    if (_remoteUp) {
      _send({'cmd': 'volume', 'v': v});
      return;
    }
    return _local.setVolume(v);
  }

  @override
  void dispose() {
    _engageTimer?.cancel();
    _healthTimer?.cancel();
    _local.dispose();
  }
}