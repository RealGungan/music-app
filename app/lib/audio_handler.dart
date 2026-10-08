import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show IsolateNameServer;

import 'package:audioplayers/audioplayers.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart' as audio_session;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart' show getExternalStorageDirectory;

/// Name of the [IsolateNameServer] port owned by the MAIN isolate. The
/// handler uses it to send state/position/error events back to the app.
const kAudioBridgePort = 'nasmusic_audio_cmds';

/// Name of the port registered by THIS handler isolate. The main isolate uses
/// it to push media metadata (title/art) here, and the playback engine uses it
/// to send play/pause/seek/volume commands to the player that lives HERE.
const kAudioStatePort = 'nasmusic_audio_state';

/// Phone downloads arrive as file:// URIs — they MUST play as
/// DeviceFileSource (isLocal=true, plain path). Fed to UrlSource they go
/// through the network stack: a few seconds play, then a silent stall the
/// heal loop restarts forever.
Source sourceForUrl(String url) {
  if (url.startsWith('file://')) {
    return DeviceFileSource(Uri.parse(url).toFilePath());
  }
  return UrlSource(url);
}

/// What the car/head-unit focus event means. Pure (no player) so unit tests
/// can pin it: nav prompts arrive as LOSS_TRANSIENT_CAN_DUCK -> duck, calls
/// as LOSS_TRANSIENT -> pause.
enum CarFocusAction { duck, restoreDuck, pause, resume }

CarFocusAction carFocusAction(
    {required bool begin,
    required audio_session.AudioInterruptionType type}) {
  if (type == audio_session.AudioInterruptionType.duck) {
    return begin ? CarFocusAction.duck : CarFocusAction.restoreDuck;
  }
  return begin ? CarFocusAction.pause : CarFocusAction.resume;
}

/// Stable MediaSession id: strip the re-resolving ?token= query so head
/// units keyed on id don't flicker one song as many tracks.
String stableMediaId(String? url, String fallback) {
  final id = (url == null || url.isEmpty) ? fallback : url;
  final cut = id.split('?').first;
  return cut.isNotEmpty ? cut : fallback;
}

/// Media-session handler that OWNS the real audioplayers player on Android.
///
/// audio_service runs this class in a SEPARATE isolate. Keeping the
/// [AudioPlayer] in this isolate means playback never dies when Android
/// suspends the UI isolate in the background: the lock-screen / notification
/// controls and the media session all talk to the player directly.
class NASMusicAudioHandler extends BaseAudioHandler {
  final _statePort = ReceivePort();
  final AudioPlayer _player = AudioPlayer();

  // Media metadata (pushed from the main isolate).
  String _title = '';
  String _artist = '';
  String _album = '';
  String? _art;
  String? _artRemote;
  bool _artIsFile = false;
  bool _hasMedia = false;

  // Playback state (derived from our OWN player).
  bool _loading = false;
  bool _playing = false;
  bool _paused = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _currentUrl;
  // Last published metadata signature (dedupe; head units choke on
  // identical metadata pushed several times a second).
  String _lastPubSig = '';
  // Pre-pushed "up next" for the gapless handoff: the main isolate sends
  // the upcoming track ahead of time; on natural completion the handler
  // starts it itself (the UI isolate may be asleep with the screen off).
  String? _nextUrl;
  String? _nextTitle;
  String? _nextArtist;
  String? _nextAlbum;
  // Serializes incoming engine commands: _onIncoming fires them without
  // awaiting, so two rapid taps ran overlapping stop/play sequences and
  // one's stop() killed the other's prepare (instant player-error, dur 0).
  // Chaining makes rapid taps strictly sequential (tiny added latency).
  Future<void> _cmdGate = Future.value();
  DateTime _lastPlaybackPublish = DateTime.fromMillisecondsSinceEpoch(0);

  /// Target + time of the last user seek command, so a genuine seek to 0
  /// while paused still updates state instead of being filtered below.
  Duration? _userSeekTarget;
  DateTime _userSeekAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// A zero tick while paused is never real playback: the platform emits
  /// pos 0 when the main isolate's heal silently swaps the source under a
  /// paused track, which used to publish updatePosition 0 and leave the
  /// notification bar at 0:00 until resume (fixed 2026-09-18).
  bool _isSpuriousZero(Duration d) {
    if (d != Duration.zero) return false;
    if (!_paused) return false;
    final t = _userSeekTarget;
    if (t != null &&
        t <= const Duration(seconds: 2) &&
        DateTime.now().difference(_userSeekAt).inSeconds < 5) {
      return false;
    }
    return true;
  }

  /// Moment of our OWN last play/focus-take. Our play path takes focus AND
  /// the player requests it again internally, so the OS reports a focus loss
  /// back to our own session ~10ms after every tap-to-play — pausing it
  /// instantly (tap plays nothing until manual resume, which doesn't
  /// re-request focus). Ignore our own echo; honor genuine external
  /// interruptions (YouTube, calls) that arrive later in playback. Window is
  /// 1s: the echo lands in ~10ms, so a real takeover in the first second
  /// after tapping play is honored, not swallowed.
  DateTime _lastOwnPlayAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// True while the last focus loss was PERMANENT (another music/video app
  /// took over: Android AUDIOFOCUS_LOSS arrives as type `unknown`). Regaining
  /// focus after that must NOT auto-resume — the user switched away on
  /// purpose, and stealing audio back fights their app (plus the UI shows
  /// playing when they left us paused). Transient ducks (nav prompts:
  /// pause/duck types) still resume as before.
  bool _focusLostPermanent = false;

  /// Last user volume (1.0 default); ducking scales from this, restore
  /// returns to it. Tracks the 'volume' command so a duck-restore never
  /// blasts back to full when the user had lowered it.
  double _userVolume = 1.0;
  bool _ducked = false;

  /// Configure this isolate's audio session (music focus). Fire-and-
  /// forget: a missing session only loses car routing, never playback.
  Future<void> _initAudioSession() async {
    try {
      final session = await audio_session.AudioSession.instance;
      await session.configure(const audio_session.AudioSessionConfiguration.music());
      // Handle audio focus changes from other apps (e.g., WAZE nav instructions).
      // NAV (CAN_DUCK) only lowers volume; calls/transient pauses; regain
      // resumes a paused track or restores ducked volume.
      session.interruptionEventStream.listen((event) {
        switch (carFocusAction(begin: event.begin, type: event.type)) {
          case CarFocusAction.duck:
            debugPrint('[handler] audio focus duck (nav)');
            _ducked = true;
            _player.setVolume(_userVolume * 0.25);
            _sendEvent({'ev': 'focus', 'phase': 'ducked'});
            return;
          case CarFocusAction.restoreDuck:
            debugPrint('[handler] audio focus unduck');
            if (_ducked) {
              _ducked = false;
              _player.setVolume(_userVolume);
            }
            _sendEvent({'ev': 'focus', 'phase': 'unducked'});
            return;
          case CarFocusAction.pause:
          case CarFocusAction.resume:
            break;
        }
        if (event.begin) {
          debugPrint('[handler] audio focus lost: ${event.type}');
          if (DateTime.now().difference(_lastOwnPlayAt) <
              const Duration(seconds: 1)) {
            debugPrint('[handler] ignoring self-induced focus loss');
            _sendEvent({
              'ev': 'focus',
              'phase': 'lost-ignored',
              'type': event.type.toString()
            });
            return;
          }
          _focusLostPermanent =
              event.type == audio_session.AudioInterruptionType.unknown;
          _sendEvent({
            'ev': 'focus',
            'phase': 'lost-honored',
            'type': event.type.toString()
          });
          if (_playing) pause();
        } else {
          debugPrint('[handler] audio focus regained: ${event.type}');
          final resume = !_focusLostPermanent;
          _focusLostPermanent = false;
          if (!resume) {
            debugPrint('[handler] staying paused after permanent loss');
            _sendEvent({
              'ev': 'focus',
              'phase': 'regained-stay-paused',
              'type': event.type.toString()
            });
            return;
          }
          _sendEvent({
            'ev': 'focus',
            'phase': 'regained',
            'type': event.type.toString()
          });
          if (!_playing && _hasMedia && _currentUrl != null) play();
        }
      });
    } catch (e) {
      debugPrint('[handler] audio session setup failed: $e');
    }
  }

  /// Take audio focus before sounding. The car routes A2DP to the focus
  /// holder; without this the phone plays into the void.
  Future<void> _takeFocus() async {
    try {
      await audio_session.AudioSession.instance
          .then((s) => s.setActive(true));
    } catch (e) {
      debugPrint('[handler] setActive failed: $e');
    }
  }
  NASMusicAudioHandler() {
    // Same stale-mapping hazard as the main-isolate bridge: a cached
    // process can hold the old state port name.
    IsolateNameServer.removePortNameMapping(kAudioStatePort);
    IsolateNameServer.registerPortWithName(_statePort.sendPort, kAudioStatePort);
    // Audio focus belongs to THIS isolate (it owns the player): without a
    // configured session the car never routes audio to us — silence until
    // some other app takes focus first. Same music() config as main.
    _initAudioSession();
    _statePort.listen(_onIncoming);
    _player.onPlayerComplete.listen((_) async {
      // Gapless handoff: if the main isolate pre-pushed the next track,
      // start it HERE (the UI isolate may be suspended with the screen
      // off) and tell main to adopt it instead of replaying. Otherwise
      // the legacy complete path (main advances when it wakes).
      final nu = _nextUrl;
      if (nu != null && nu.isNotEmpty) {
        _nextUrl = null;
        if (_nextTitle != null) _title = _nextTitle!;
        if (_nextArtist != null) _artist = _nextArtist!;
        if (_nextAlbum != null) _album = _nextAlbum!;
        _nextTitle = _nextArtist = _nextAlbum = null;
        // The item id is the stream URL: adopt it BEFORE publishing so the
        // car never sees the new title under the previous track's id.
        _currentUrl = nu;
        _publishMedia();
        try {
          await _player.stop();
          // Stale-http guard: a dead pre-push must hand back to main (its
          // completion path pings + wraps to cache) instead of hanging here
          // unattended with the UI isolate asleep.
          await _player
              .play(sourceForUrl(nu))
              .timeout(const Duration(seconds: 10));
        } catch (e) {
          _sendEvent({'ev': 'err', 'm': e.toString()});
          // Blind autostart failed (dead pre-push): hand advancement back to
          // main — its completion path pings NAS and wraps to cache offline.
          _sendEvent({'ev': 'complete'});
          _publishPlayback();
          return;
        }
        _sendEvent({'ev': 'advanced', 'url': nu});
        _publishPlayback();
        return;
      }
      _sendEvent({'ev': 'complete'});
      _publishPlayback();
    });
    _player.onPositionChanged.listen((d) {
      if (_isSpuriousZero(d)) return;
      _position = d;
      // Paused bg: drop pos events (state only, throttled below) — the
      // 500ms fg cadence while paused held CPU/wakelock for hours.
      if (!_playing) {
        if (DateTime.now().difference(_lastPlaybackPublish) >
            const Duration(seconds: 5)) {
          _publishPlayback();
        }
        return;
      }
      _sendEvent({'ev': 'pos', 'ms': d.inMilliseconds});
      // Throttle the media-session publishing so the seek bar stays live
      // without flooding the notification on every ~200ms tick.
      if (DateTime.now().difference(_lastPlaybackPublish) >
          const Duration(milliseconds: 500)) {
        _publishPlayback();
      }
    });
    _player.onDurationChanged.listen((d) {
      _duration = d;
      _sendEvent({'ev': 'dur', 'ms': d.inMilliseconds});
      // Some head units stay blank until a non-null duration is published
      // in the metadata itself — re-publish media (not just playback).
      _publishMedia();
      _publishPlayback();
    });
    _player.onPlayerStateChanged.listen((s) {
      _playing = s == PlayerState.playing;
      _paused = s == PlayerState.paused;
      if (_playing) _loading = false;
      _sendEvent({'ev': 'state', 's': s.name});
      _publishPlayback();
    });
    _publishPlayback();
  }

  void _sendEvent(Map<String, dynamic> m) {
    final sp = IsolateNameServer.lookupPortByName(kAudioBridgePort);
    sp?.send(jsonEncode(m));
  }

  void _sendBridge(String msg) {
    IsolateNameServer.lookupPortByName(kAudioBridgePort)?.send(msg);
  }

  void _onIncoming(dynamic message) {
    if (message is! String) return;
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final cmd = m['cmd'];
    if (cmd != null) {
      debugPrint('[handler] <- main: $m');
      // Awaited in series: concurrent stop/play overlap kills prepares.
      _cmdGate = _cmdGate
          .then((_) => _handleCommand(cmd.toString(), m))
          .catchError((_, __) {});
    } else {
      _hasMedia = m['has_media'] ?? _hasMedia;
      // Track change resets art FIRST: otherwise a no-art track inherits
      // the previous track's file art. (URL-only ticks for the SAME track
      // must NOT reset — that nulled/re-set art every second, flapping
      // null/content publishes that choke head units.)
      final nt = m['title'];
      final na = m['artist'];
      if ((nt is String && nt != _title) ||
          (na is String && na != _artist)) {
        _art = null;
        _artRemote = null;
        _artIsFile = false;
      }
      _title = m['title'] ?? _title;
      _artist = m['artist'] ?? _artist;
      _album = m['album'] ?? _album;
      _loading = m['loading'] ?? _loading;
      _applyArt(m).then((changed) {
        if (changed) {
          // Force SystemUI to drop its cached bitmap: same-URI publishes
          // are ignored, so null first, then the real item with its new
          // unique artUri. Re-push playback too (rebind, not pause/resume).
          _lastPubSig = '';
          mediaItem.add(null);
        }
        _publishMedia();
        if (changed) _publishPlayback();
      });
    }
  }

  /// Takes incoming artwork (either a remote URL, or base64-encoded bytes that
  /// get written to an app-private cache file) and stores a playable artifact.
  ///
  /// Android's media-session artwork loader is unreliable at fetching remote
  /// HTTP URLs (silent failures -> empty art slot), so the main isolate
  /// downloads the cover and hands the handler the bytes here. We write them
  /// to our own cache file and publish a `file://` artUri, which the system
  /// loads dependably. See kAudioStatePort for the message shape.
  /// Returns true when the served art actually changed (new file bytes or
  /// a new remote URL) — the caller null-then-republishes so SystemUI
  /// rebinds instead of showing the previous track's cached bitmap.
  Future<bool> _applyArt(Map<String, dynamic> m) async {
    final art = m['art'];
    final b64 = m['art_bytes'];
    if (b64 is String && b64.isNotEmpty) {
      try {
        final bytes = await _downscaleArt(base64Decode(b64), 256);
        final dir = await _resolveArtCacheDir();
        final file = File('$dir/nasmusic_art.jpg');
        // Only write if the file doesn't already contain these bytes (avoids
        // re-writing on every position tick).
        if (!file.existsSync() || file.lengthSync() != bytes.length) {
          file.writeAsBytesSync(bytes, flush: true);
          debugPrint('[handler] wrote local art ${file.path} (${bytes.length}B)');
          _artRemote = (art is String && art.isNotEmpty) ? art : _artRemote;
          _art = file.path;
          _artIsFile = true;
          return true;
        }
        _artRemote = (art is String && art.isNotEmpty) ? art : _artRemote;
        _art = file.path;
        _artIsFile = true;
        return false;
      } catch (e) {
        debugPrint('[handler] art write failed: $e');
        return false;
      }
    }
    // URL-only tick (the per-second push): keep serving the cached file
    // art when the remote URL is unchanged. Resetting to URL form here
    // flapped null/content publishes every second and choked head units.
    final remote = (art is String && art.isNotEmpty) ? art : null;
    if (remote != null && remote != _artRemote) {
      _artRemote = remote;
      _art = remote;
      _artIsFile = false;
      return true;
    }
    return false;
  }

  /// Downscales cover-art bytes so the decoded Bitmap stays under the Android
  /// Binder / MediaMetadata size limit (oversized bitmaps are silently dropped
  /// by the system, leaving a gray placeholder on the notification/lock screen).
  /// Returns the original bytes if they are already small enough or can't be
  /// decoded.
  Future<Uint8List> _downscaleArt(Uint8List bytes, int maxDim) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final w = img.width, h = img.height;
      if (w <= maxDim && h <= maxDim) return bytes;
      final longest = w > h ? w : h;
      final scale = maxDim / longest;
      final nw = (w * scale).round(), nh = (h * scale).round();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint()
        ..isAntiAlias = true
        ..filterQuality = ui.FilterQuality.medium;
      canvas.drawImageRect(
        img,
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ui.Rect.fromLTWH(0, 0, nw.toDouble(), nh.toDouble()),
        paint,
      );
      final resized = await recorder.endRecording().toImage(nw, nh);
      final data =
          await resized.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } catch (_) {
      return bytes;
    }
  }

  String _artCacheDir = '';

  Future<String> _resolveArtCacheDir() async {
    if (_artCacheDir.isNotEmpty) return _artCacheDir;
    try {
      // External storage on Android is /sdcard/Android/data/<pkg>/, a shared
      // (FUSE) location that SystemUI's MediaDataManager can open by path even
      // though it is a separate process — unlike the app-private code_cache.
      // This is the same shared location audio_service's cacheManager uses.
      final dir = await getExternalStorageDirectory();
      if (dir != null) {
        _artCacheDir = dir.path;
        return _artCacheDir;
      }
    } catch (_) {}
    _artCacheDir = Directory.systemTemp.path;
    return _artCacheDir;
  }

  Future<void> _handleCommand(String cmd, Map<String, dynamic> m) async {
    switch (cmd) {
      case 'play':
        final url = m['url']?.toString();
        if (url == null || url.isEmpty) break;
        _lastOwnPlayAt = DateTime.now();
        // A user/main-initiated play wins over any pre-pushed next track.
        _nextUrl = null;
        _nextTitle = _nextArtist = _nextAlbum = null;
        _currentUrl = url;
        _loading = true;
        _playing = false;
        // Publish the NEW track's metadata BEFORE the loading/playback state:
        // cars (AVRCP) latch onto the first MediaItem they see for a URL.
        // The metadata message for this track normally precedes the play cmd
        // on the same receive port, so _title/_artist/_album are already the
        // new song's values here. Emitting it now guarantees the car sees the
        // correct song + plays it, not the previous track's leftovers.
        _publishMedia();
        _publishPlayback();
        // Focus BEFORE sound: the car routes A2DP to the focus holder.
        await _takeFocus();
        try {
          await _player.stop();
          debugPrint('[handler] playing <$url>');
          await _player.play(sourceForUrl(url));
          debugPrint('[handler] play() returned OK');
        } catch (e, st) {
          debugPrint('[handler] play FAILED: $e\n$st');
          _loading = false;
          _playing = false;
          final msg = e.toString();
          // An expired fileUrl ?token= fails as HTTP 401 — tag it so the UI
          // bounces to login instead of heal-looping a dead URL silently.
          _sendEvent({'ev': 'err', 'm': msg, 'auth': msg.contains('401')});
          _publishPlayback();
        }
        break;
      case 'pause':
        await _player.pause();
        break;
      case 'resume':
        await _player.resume();
        break;
      case 'stop':
        _currentUrl = null;
        await _player.stop();
        break;
      case 'getState':
        // Truth query after UI-isolate resume: reply via the existing
        // bridge; main feeds it to RemoteEngine.feedRemoteEvent, fixing
        // stale _lastState / frozen position without touching audio.
        // Derived from tracked flags (never query the player: its getter
        // may suspend and serialize behind a play command).
        _sendEvent({
          'ev': 'state',
          's': _playing
              ? 'playing'
              : _paused
                  ? 'paused'
                  : 'stopped'
        });
        _sendEvent({'ev': 'pos', 'ms': _position.inMilliseconds});
        _sendEvent({'ev': 'dur', 'ms': _duration.inMilliseconds});
        break;
      case 'seek':
        final ms = (m['ms'] as num?)?.toInt() ?? 0;
        _userSeekTarget = Duration(milliseconds: ms);
        _userSeekAt = DateTime.now();
        await _player.seek(Duration(milliseconds: ms));
        break;
      case 'setSource':
        // Silent source swap (network-switch heal while paused): load the
        // URL without starting playback and without touching car/notification
        // state — only the position moves on the following seek.
        final surl = m['url']?.toString();
        if (surl == null || surl.isEmpty) break;
        _currentUrl = surl;
        try {
          await _player.setSource(sourceForUrl(surl));
        } catch (e) {
          _sendEvent({'ev': 'err', 'm': e.toString()});
        }
        break;
      case 'volume':
        _userVolume = (m['v'] as num?)?.toDouble() ?? 1.0;
        await _player.setVolume(_ducked ? _userVolume * 0.25 : _userVolume);
        break;
      case 'setNext':
        // Pre-push (or clear, when url is missing) the upcoming track for
        // gapless handoff. Never starts playback by itself.
        final nurl = m['url']?.toString();
        if (nurl == null || nurl.isEmpty) {
          _nextUrl = null;
          _nextTitle = _nextArtist = _nextAlbum = null;
        } else {
          _nextUrl = nurl;
          _nextTitle = m['title']?.toString();
          _nextArtist = m['artist']?.toString();
          _nextAlbum = m['album']?.toString();
        }
        break;
    }
  }

  void _publishMedia() {
    if (!_hasMedia) {
      // Clear the session when idle: otherwise the car keeps showing the
      // last song forever (and its buttons act on a dead track).
      mediaItem.add(null);
      queue.add([]);
      _lastPubSig = '';
      return;
    }
    // Deterministic art delivery. We write the cover to a local cache file and
    // hand audio_service BOTH a `content://` artUri (served by our exported
    // ArtFileProvider) AND the `artCacheFile` absolute path extra.
    //  - Java setMetadata() takes the artCacheFile branch: decodes the file IN
    //    OUR process and calls setLargeIcon() + sets the ALBUM_ART/ART/
    //    DISPLAY_ICON bitmaps in MediaMetadata (so the metadata has real art).
    //  - Because artUri is a content:// URI, SystemUI's MediaDataManager can
    //    ALSO open it through our exported provider (a plain ContentProvider may
    //    be exported, unlike androidx FileProvider) and load the bitmap itself.
    // Provided artUri as content:// so DISPLAY_ICON_URI is published and
    // SystemUI's loadBitmapFromUri() succeeds instead of falling back to the
    // gray placeholder.
    // HEAD-UNIT RULE: never publish a transient placeholder title. Cars
    // (AVRCP) cache the FIRST title they see for a track and many refuse to
    // refresh it — a "Loading…" item permanently locks the display on that
    // text. Publish the real title even mid-load. The id is the stream URL
    // (stable + unique per track), so two different songs that happen to share
    // a title still register as a new track on the car.
    // ONE item instance shared by mediaItem + queue: AVRCP resolves the
    // active queue item id to its metadata, so the two must be identical
    // (two separate objects with the same fields confused some head units).
    // Stable, token-free id: the full stream URL re-resolves (new token)
    // per tap, and head units keyed on id flicker it as a "new" track.
    // The player keeps using the full URL — only the published id is cut.
    final stableId = stableMediaId(_currentUrl, '$_artist - $_title');
    // Unique artUri per track: SystemUI caches bitmaps BY URI, so a fixed
    // filename keeps showing the previous song's art. The file stays one
    // (nasmusic_art.jpg); only the query busts the cache.
    final artUri = _artIsFile && _art != null
        ? Uri.parse(
            'content://com.nasmusic.nasmusic.art/nasmusic_art.jpg'
            '?v=${stableId.hashCode.toUnsigned(32)}')
        : null;
    final item = MediaItem(
      id: stableId.isNotEmpty ? stableId : '$_artist - $_title',
      album: _album.isNotEmpty ? _album : null,
      artist: _artist.isNotEmpty ? _artist : null,
      title: _title.isNotEmpty ? _title : '',
      artUri: artUri,
      extras: _artIsFile && _art != null ? {'artCacheFile': _art} : null,
      duration: _duration,
    );
    // Dedupe BEFORE touching the platform: identical consecutive metadata
    // (the loader re-publishes on every art/duration tick) chokes head
    // units at several pushes per second. Real changes still go out.
    final sig =
        '${item.id}|$_title|$_artist|$_album|${_duration.inMilliseconds}|$artUri';
    if (sig == _lastPubSig) return;
    _lastPubSig = sig;
    mediaItem.add(item);
    // Publish the same item as the session QUEUE (index 0) and reference it
    // from PlaybackState.queueIndex. Android's Bluetooth AVRCP stack reads
    // PlaybackStateCompat.getActiveQueueItemId() to pick which queue item's
    // metadata to send to the head unit; with NO active item id (UNKNOWN_ID),
    // many car stereos (Opel/Astra known finicky) show a blank screen and
    // ignore transport buttons even though the phone works fine. Spotify sets
    // a real active item id — this is the exact difference that was killing
    // the car display.
    queue.add([item]);
    debugPrint('[handler] publish uri=${artUri} cache=${_artIsFile ? _art : null}');
    _sendEvent({
      'ev': 'pub',
      'title': _title,
      'artist': _artist,
      'album': _album,
      'id': item.id,
      'dur_ms': _duration.inMilliseconds,
      'art': artUri.toString(),
    });
  }

  void _publishPlayback() {
    _lastPlaybackPublish = DateTime.now();
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      // MUST reference the session queue when playing (see _publishMedia's
      // queue.add): AVRCP computes the active queue item id from this index and
      // a missing one (UNKNOWN_ID) makes many head units show a blank
      // now-playing screen. Left null while idle (no queue item exists yet).
      queueIndex: _hasMedia ? 0 : null,
      processingState:
          _loading ? AudioProcessingState.loading : AudioProcessingState.ready,
      playing: _playing,
      // Head units / Android Auto gate play/pause icons + seek on this:
      // 1.0 while sounding, 0.0 otherwise.
      speed: _playing ? 1.0 : 0.0,
      updatePosition: _position,
    ));
  }

  /// Lock-screen / notification transport. Play/pause/seek go straight to OUR
  /// player; next/prev are queue decisions, so they bounce to the app.
  @override
  Future<void> play() async {
    if (!_hasMedia || _currentUrl == null) {
      // Resume race / service restart lost the metadata push but the URL
      // is ground truth: re-publish + play instead of dropping (drop =
      // frozen play icon, 0:00, taps no-op).
      final url = _currentUrl;
      if (url == null || url.isEmpty) {
        debugPrint('[handler] play() dropped: hasMedia=$_hasMedia url set=false');
        return;
      }
      debugPrint('[handler] play() recovering media for <$url>');
      _hasMedia = true;
      _publishMedia();
      _lastOwnPlayAt = DateTime.now();
      await _takeFocus();
      try {
        await _player.play(sourceForUrl(url));
      } catch (e) {
        final msg = e.toString();
        _sendEvent({'ev': 'err', 'm': msg, 'auth': msg.contains('401')});
        _publishPlayback();
      }
      return;
    }
    _lastOwnPlayAt = DateTime.now();
    await _takeFocus();
    await _player.resume();
  }

  @override
  Future<void> pause() async => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    _currentUrl = null;
    // super.stop() sets processingState to idle, which makes audio_service
    // hide/dismiss the media notification. Without this, the notification
    // stays up after the app is closed.
    if (!kIsWeb) await super.stop();
  }

  /// Fired by audio_service when the native task is removed (app swiped from
  /// recents). Stop playback and dismiss the media notification.
  @override
  Future<void> onTaskRemoved() async {
    await stop();
  }

  @override
  Future<void> seek(Duration position) async => _player.seek(position);

  @override
  Future<void> skipToNext() async => _sendBridge('next');

  @override
  Future<void> skipToPrevious() async => _sendBridge('prev');

  /// Android Auto browse: the head unit lists the session queue through the
  /// native onLoadChildren, which audio_service forwards here. Serve the
  /// live media item so the car shows the queue instead of an empty tree.
  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
      [Map<String, dynamic>? options]) async {
    final m = mediaItem.value;
    return m == null ? [] : [m];
  }
}