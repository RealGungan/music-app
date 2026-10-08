import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'audio_session_state.dart';
import 'debug_overlay.dart';
import 'diag_log.dart';
import 'history.dart';
import 'lang.dart';
import 'offline_store.dart';
import 'play_log.dart';
import 'prefetch_store.dart';
import 'playback_engine.dart';
import 'queue/queue_planner.dart';
import 'queue/text_norm.dart';

class QueueItem {
  final String title;
  final String url;
  final String? thumbUrl;

  /// File identity (NAS baseName "Artist - Title"). [title] is display text
  /// and can drift from the stored cache key; lookups must try title first,
  /// then this. Null/absent = title already is the identity (NAS rows).
  final String? baseName;

  /// Cache identity: file baseName when known, else the display title.
  String get identity => (baseName?.isNotEmpty ?? false) ? baseName! : title;

  /// True when the user manually moved this item to "play next".
  bool manuallyPlaced = false;

  /// True for autoplay-related items pulled from the internet (Spotify /
  /// YouTube-Music radio style). Shown labeled "from internet" in the queue.
  bool fromInternet = false;

  /// Non-null for discovery tracks whose [url] is a `/staging/resolve/<vid>`
  /// placeholder that must be resolved to a direct audio URL before playing.
  final String? videoId;

  /// For tracks that have no video id yet (online album/artist rows): resolve
  /// artist+title to a streamable URL lazily, right before that track plays,
  /// instead of blocking the whole queue on lookups up front.
  final ({String artist, String title})? resolveName;

  /// Optional album + art threaded from the radio/discovery metadata (and
  /// from the NAS copy when a local file replaces an internet row), shown in
  /// Now Playing + queue rows when the server's metainfo has no album.
  final String? album;
  final String? albumImage;

  /// The ACTUAL resolved identity of the audio that will play (the YouTube
  /// video resolvename picked). Lyrics are looked up against this — not the
  /// discovery identity — so they match the real recording.
  final String? lyricsArtist;
  final String? lyricsTitle;

  /// Liked flag threaded from the single playlist payload (no per-row
  /// likedStatus roundtrip in the prefetch wave).
  final bool? liked;
  QueueItem(
    this.title,
    this.url, {
    this.thumbUrl,
    this.baseName,
    this.videoId,
    this.resolveName,
    this.manuallyPlaced = false,
    this.fromInternet = false,
    this.album,
    this.albumImage,
    this.lyricsArtist,
    this.lyricsTitle,
    this.liked,
  });
}

/// Turns a discovery [videoId] into a direct streamable audio URL.
typedef UrlResolver = Future<String> Function(String videoId);

/// Turns an [artist]+[title] pair into a direct streamable audio URL (for
/// online album/artist rows that have no video id yet).
typedef NameResolver = Future<String> Function(String artist, String title);

/// Turns an [artist]+[title] pair into a NAS file URL (or null when the NAS
/// has no exact copy). Bounded by callers — the engine caps it at 2s so a
/// slow NAS check can never stall first audio.
typedef NasLookup = Future<String?> Function(String artist, String title);

/// Stale-tick gate for the position stream (pure, unit-tested): drop a tick
/// that still belongs to the PREVIOUS track load. New audio always starts
/// near 0, so any tick jumping far past everything accepted for this load
/// ([maxAccepted]) with no matching recent user seek is the old engine's
/// tail arriving late — accepting it flashes the previous song's timestamp.
/// Normal advance, small rewinds, and heal seek-backs (all within
/// maxAccepted + 3s) pass; genuine user seeks pass via the seek match.
bool dropStalePositionTick({
  required Duration tick,
  required Duration maxAccepted,
  required Duration? seekTarget,
  required DateTime seekAt,
  required DateTime now,
}) {
  if (tick <= maxAccepted + const Duration(seconds: 3)) return false;
  if (seekTarget != null &&
      now.difference(seekAt).inSeconds < 5 &&
      (tick - seekTarget).abs() <= const Duration(seconds: 2)) {
    return false;
  }
  return true;
}

/// Stamp gate for the position/duration readout (pure, unit-tested): hide
/// both labels until the FIRST accepted position tick of the NEW track's
/// play generation arrives. Deterministic (identity-based, never a timer),
/// so no stale or zero stamp can flash on a track switch.
bool stampHidden({required int posGen, required int playGen}) =>
    posGen != playGen;

/// Pause-token gate for EVERY deferred resume (nudge/heal/autoplay refill/
/// completion advance/_boundLoading/RemoteEngine toggle): a delayed resume
/// may only fire when its track generation still wins, no pause (or newer
/// heal) landed since it was scheduled, audio isn't already flowing, AND no
/// explicit pause intent is latched (covers heals STARTED after the pause,
/// which own a fresh token but must still never resume a paused track).
/// pause() bumps [_healGen] (see [QueuePlayer.pause]), so any play+
/// instant-pause auto-resume dies here — no exceptions, no call-site
/// shortcuts. Pure so unit tests pin the matrix.
bool resumeFireAllowed({
  required int gen,
  required int playGen,
  required int healToken,
  required int currentHeal,
  required bool isPlaying,
  bool pauseIntent = false,
}) =>
    gen == playGen &&
    healToken == currentHeal &&
    !isPlaying &&
    !pauseIntent;

/// Heal-end resume gate (pure, unit-tested): a heal may resume audio only
/// when it was playing AND no user pause intent is latched. pause() sets
/// the latch synchronously (before the async engine ack), so even a heal
/// that starts mid-pause-ack — when stale `isPlaying` still reads true —
/// stays paused.
bool healResumeAllowed({
  required bool wasPlaying,
  required bool pauseIntent,
}) =>
    wasPlaying && !pauseIntent;

/// Skin truth mapping (pure, unit-tested): the play/pause skin reads the
/// NATIVE player state-stream as sole truth. Any start (playing) shows the
/// pause icon; ANY stoppage by any means (paused/stopped/completed/disposed)
/// shows the play icon; buffering/null keeps the last icon (spinner covers
/// the wait, delayed past 800ms only).
bool skinShowsPlaying(PlayerState? state, {required bool lastPlaying}) {
  if (state == null) return lastPlaying;
  return state == PlayerState.playing;
}

/// Watchdog comparator (pure, unit-tested): true when the rendered skin
/// disagrees with direct native truth — catches stream-subscription death,
/// dual-engine divergence, stale selector, whatever the cause.
bool skinMismatch({required bool skinShows, required bool nativePlaying}) =>
    skinShows != nativePlaying;

/// skin-mismatch log line: kind/state/expected for logClientError.
String skinMismatchMessage({
  required bool skinShows,
  required bool nativePlaying,
  required String engine,
  required String handler,
}) =>
    'skin=${skinShows ? 'playing' : 'paused'} '
    'expected=${nativePlaying ? 'playing' : 'paused'} '
    'engine=$engine handler=$handler';

/// Stall-detector verdict (pure, unit-tested): compares the engine's CLAIM
/// against NATIVE position movement. Either direction of lie is corrected —
/// playing-with-frozen-clock paints paused, paused-with-moving-clock paints
/// playing — so the skin can never strand on the wrong icon by construction.
enum StallFix { none, toPaused, toPlaying }

StallFix stallAudit({
  required bool enginePlaying,
  required bool posAdvanced,
  required bool loading,
}) {
  if (loading) return StallFix.none;
  if (enginePlaying && !posAdvanced) return StallFix.toPaused;
  if (!enginePlaying && posAdvanced) return StallFix.toPlaying;
  return StallFix.none;
}

/// App-wide playback queue with shuffle — the "streaming engine".
class QueuePlayer {
  QueuePlayer._() {
    _player.onPlayerComplete.listen((_) async {
      // Paused audio never completes: a late event after pause-intent must
      // not advance (or replay) the queue unattended.
      if (_pausedIntent) return;
      // Dropout guard: a completion with most of the track unplayed is a
      // dead network stream, not a finished song — heal it in place
      // instead of skipping to the next track. Completions landing within
      // moments of a fresh play() belong to the PREVIOUS track (in-flight
      // when we switched) — ignore them entirely.
      if (DateTime.now().difference(_lastPlayStartAt).inSeconds < 3) return;
      final dur = trackDuration.value;
      if (dur > Duration.zero &&
          currentPosition < dur - const Duration(seconds: 5)) {
        debugPrint('[queue] completion far before end — treating as dropout');
        DiagLog.restart.log(
          'complete-dropout pos=${currentPosition.inSeconds}s '
          'dur=${dur.inSeconds}s',
        );
        _healCurrent(reason: 'completed-early');
        return;
      }
      // If duration is zero, the duration event may not have arrived yet
      // (race condition). Don't hold — advance to next track. The "no
      // duration" hold was meant for truly unplayable rows, but those
      // surface as playback errors anyway. Advancing is safer than
      // getting stuck on a valid track whose duration event arrived late.
      // Natural completion = the whole song played. The UI clock can be
      // stale (screen off: no position events while the handler kept
      // playing), so seal the full duration — otherwise finished songs
      // bank ~0s and Wrapped only ever records skips.
      final fullSec = max(
        currentPosition.inSeconds,
        trackDuration.value.inSeconds,
      );
      if (repeatEnabled.value) {
        _playCurrent(completedSecs: fullSec);
      } else {
        if (items.length < 2) {
          // Single-item queue: next() no-ops, so nothing would seal this.
          PlayLog.switched(currentTitle.value, fullSec, currentTitle.value);
        }
        await next(completedSecs: fullSec);
        await _maybeAutoplay(force: true);
      }
    });
    _player.onPositionChanged.listen((d) {
      // A zero tick while PAUSED is never real playback: the platform
      // emits pos 0 when a heal swaps the source under a paused track,
      // and the seek-back often emits nothing until resume — without
      // this guard the bar stuck at 0:00 (fixed 2026-09-18).
      if (_isSpuriousZero(d)) return;
      // Stale-tick gate: the old engine's tail position (e.g. 1:23) can
      // arrive AFTER the synchronous zero reset — even after legit small
      // ticks already landed, when the exact-zero check no longer holds.
      // The per-load max gates on track identity, so only a real seek
      // (or normal advance) moves the stamp forward.
      final now = DateTime.now();
      if (dropStalePositionTick(
        tick: d,
        maxAccepted: _posMax,
        seekTarget: _userSeekTarget,
        seekAt: _userSeekAt,
        now: now,
      )) {
        return;
      }
      // Bookkeeping BEFORE notify: listeners (stamp gate) must see the new
      // generation in the same tick, not one event late.
      if (d > _posMax) _posMax = d;
      _posGen = _playGen;
      position.value = d;
      _onTick();
    });
    _player.onDurationChanged.listen((d) {
      trackDuration.value = d;
      _onTick();
    });
    _player.onPlayerStateChanged.listen((s) {
      _lastPlayerState = s;
      // Sole writer of the skin truth: bool and stream can never split.
      playingN.value = s == PlayerState.playing;
      // Any settled native state clears the buffering spinner; playing also
      // confirms audio so the deferred autoplay top-up re-arms now.
      _setLoading(false);
      if (s == PlayerState.playing) {
        // Single-item starts defer their refill until audio is confirmed —
        // this IS the confirmation, so re-arm the top-up now.
        unawaited(_maybeAutoplay());
      }
    });
    _player.onError.listen((e) {
      lastError.value = e;
      // Log playback error for debugging
      _api?.logClientError(
        'playback-error',
        'title=${currentTitle.value} err=$e',
      );
      // Expired ?token= surfaces as a 401 here — heal would retry the same
      // dead URL forever, so bounce to login instead (no heal, no loop).
      if (e.contains('401')) {
        _api?.onAuthFailure?.call();
        return;
      }
      // A playback error usually means a dead stream (network switch,
      // expired URL) — try to heal before the user even notices. Skipped
      // when a heal just ran: its own failures report back here, and the
      // retry loop below already covers them.
      if (DateTime.now().difference(_lastHealAt).inSeconds >= 60 &&
          DateTime.now().difference(_lastHealEnd).inSeconds >= 60) {
        _healCurrent(reason: 'player-error');
      }
    });
    // Network-switch heal: re-resolve + resume the current track instead
    // of going silent. The first emission is just the initial snapshot.
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      // First emission is the state at subscribe time, not a change:
      // record it (a cold start into airplane mode must signal offline),
      // but don't heal (nothing is playing yet).
      final first = _connFirst;
      _connFirst = false;
      _connDebounce?.cancel();
      _connDebounce = Timer(const Duration(milliseconds: 1500), () async {
        debugPrint('[queue] connectivity changed: $results');
        final off = results.every((r) => r == ConnectivityResult.none);
        // Update on every debounced emission (not just transitions) so a
        // cold start into airplane mode still signals.
        isOffline.value = off;
        // Network change = re-probe tailnet-vs-funnel, then decide by ping.
        if (!off) await _api?.selectBestBase();
        // Radio-up ≠ reachable (stall/VPN/funnel): ping decides before heal.
        if (!off && await _nasDown()) isOffline.value = true;
        if (!off) _api?.flushQueuedLogs();
        if (!first) _healCurrent(reason: 'network-change');
      });
    });
    // Stall watchdog: a dead socket doesn't always complete or error —
    // sometimes the position just freezes. If we're supposed to be playing
    // but the clock hasn't moved for a while (and didn't jump back, which
    // means seek/replay), heal.
    _watchTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      // Screen off (or any background state): position events stop
      // arriving in the UI isolate while the handler isolate keeps
      // playing fine. Judging that frozen clock a stall restarts the
      // song every ~12s with the screen off. Skip judging entirely —
      // on return the jump resets the baseline below.
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        _watchPos = position.value;
        _watchSince = DateTime.now();
        return;
      }
      if (!_player.isPlaying ||
          items.isEmpty ||
          index < 0 ||
          index >= items.length) {
        _watchPos = position.value;
        _watchSince = DateTime.now();
        return;
      }
      final pos = position.value;
      if ((pos - _watchPos).abs() > const Duration(seconds: 1)) {
        _watchPos = pos;
        _watchSince = DateTime.now();
        return;
      }
      if (DateTime.now().difference(_watchSince).inSeconds >= 12) {
        _watchSince = DateTime.now();
        // Slow-start guard: streaming URLs buffer in the first seconds
        // (relay re-resolve, ExoPlayer probe). A frozen clock <20s after
        // play() started is buffering, not a stall — healing then replays
        // the song from ~0 ("restarts at ~15s").
        if (DateTime.now().difference(_lastPlayStartAt).inSeconds < 20) {
          return;
        }
        _healCurrent(reason: 'stall');
      }
    });
    // Stall detector: the engine CLAIM vs NATIVE clock, sampled every 3s.
    // A frozen clock under a playing claim (dead socket with no complete/
    // error) — or a moving clock under a paused claim (lost resume event) —
    // re-feeds the native truth through the state stream, which is the
    // skin's sole source, so the lie corrects itself within one tick.
    // Repaint-only: the handler keeps actual audio state, so a false
    // positive self-reverses on the next tick instead of killing sound.
    _auditTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        _auditPos = position.value;
        return;
      }
      if (items.isEmpty || index < 0 || index >= items.length) {
        _auditPos = position.value;
        return;
      }
      final pos = position.value;
      final advanced = pos != _auditPos;
      _auditPos = pos;
      final fix = stallAudit(
        enginePlaying: _player.isPlaying,
        posAdvanced: advanced,
        loading: loading.value,
      );
      if (fix == StallFix.none) return;
      // Slow-start guard (mirrors the watchdog): a frozen clock <20s after
      // play() is buffering, not a stall.
      if (fix == StallFix.toPaused &&
          DateTime.now().difference(_lastPlayStartAt).inSeconds < 20) {
        return;
      }
      final p = _player;
      if (p is! RemoteEngine) return;
      p.feedRemoteEvent({
        'ev': 'state',
        's': fix == StallFix.toPaused ? 'paused' : 'playing',
      });
      final msg =
          'stall-corrected -> ${fix == StallFix.toPaused ? 'paused' : 'playing'} '
          'pos=${pos.inSeconds}s idx=$index "${items[index].title}"';
      debugPrint('[queue] $msg');
      DiagLog.restart.log(msg);
      report('stall-corrected', msg);
    });
    // Background auto-advance: the handler isolate starts the pre-pushed
    // next track on its own when this isolate sleeps (screen off). Adopt
    // it here — move state, never touch playback (it's already playing).
    _player.onTrackAdvanced.listen((url) => _onHandlerAdvanced(url));
  }

  static final QueuePlayer instance = QueuePlayer._();

  /// Mobile plays through the audio_service handler isolate (survives the UI
  /// isolate being suspended); desktop uses a local player. Both expose the
  /// same interface, so the queue logic doesn't care which is live.
  static PlaybackEngine _createEngine() {
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return RemoteEngine();
    }
    return LocalEngine();
  }

  final PlaybackEngine _player = _createEngine();

  List<QueueItem> items = [];
  int index = -1;

  /// Visual queue scroll target position. Kept in sync with [index] on jump,
  /// so opening the queue (or tapping a row) scrolls to the playing item
  /// WITHOUT reordering or truncating the list.
  int playPos = 0;

  /// The queue item currently playing (or null when the queue is empty).
  QueueItem? get current =>
      (index >= 0 && index < items.length) ? items[index] : null;

  /// Monotonic token bumped on every play request. A stale [playList]/[next]/
  /// [jumpTo]/[_playCurrent] operation (e.g. one still awaiting a slow
  /// `/staging/resolve` when a newer request arrives) checks it and bails, so
  /// an outdated song can never clobber the one the user actually picked (L).
  int _playGen = 0;

  /// [_playGen] value seen by the most recent position event. A heal uses
  /// it to tell a stale position (belongs to the previous track load)
  /// from a live one.
  int _posGen = -1;

  /// Largest position accepted for the current track load. The stale-tick
  /// gate keys on this (reset per load), so a late tail from the previous
  /// track can never flash its timestamp — even after small live ticks
  /// already moved the clock off exact zero.
  Duration _posMax = Duration.zero;

  /// Last engine state. Paused-vs-stopped matters for [_isSpuriousZero]:
  /// only while truly paused is a zero tick guaranteed spurious.
  PlayerState _lastPlayerState = PlayerState.stopped;

  /// Target + time of the last user-initiated seek, so a genuine seek to
  /// 0 while paused still updates the bar instead of being filtered.
  Duration? _userSeekTarget;
  DateTime _userSeekAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// True for a zero position tick that cannot be real playback: the
  /// player is paused (real position only changes via user seek then),
  /// and this zero doesn't match a recent user seek to ~0.
  bool _isSpuriousZero(Duration d) {
    if (d != Duration.zero) return false;
    if (_lastPlayerState != PlayerState.paused) return false;
    final t = _userSeekTarget;
    if (t != null &&
        t <= const Duration(seconds: 2) &&
        DateTime.now().difference(_userSeekAt).inSeconds < 5) {
      return false;
    }
    return true;
  }

  /// Generation bumped on every heal start AND on deliberate pause, so a
  /// user pause (or a newer heal) cancels in-flight auto-resume attempts.
  /// Track changes are covered separately: every _playCurrent bumps
  /// [_playGen], and heals also verify index + item identity.
  int _healGen = 0;
  /// Synchronous pause-intent latch: pause() sets it BEFORE the async engine
  /// ack, resume()/new-play clears it. Heals started after a pause own a
  /// fresh hid but must still never resume — they check this, not just hid.
  bool _pausedIntent = false;
  DateTime _lastHealAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastHealEnd = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPlayStartAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Per-track heal budget: the retry loop inside one _healCurrent is
  /// bounded, but nothing stopped the watchdog firing a FRESH heal every
  /// 12s forever (each restarting the song near 0). After this many
  /// restarts of the same track, give up visibly instead of looping.
  static const int kMaxHealsPerTrack = 3;
  int _healStrikes = 0;
  Object? _healTrackId;
  // URL bytes currently loaded in the engine. Heals resuming the SAME song
  // skip the setSource teardown (decoder reset = keyframe snapback).
  String? _loadedUrl;
  // True after a give-up: the next play tap retries fresh instead of
  // resuming a dead source.
  bool _gaveUp = false;

  /// Network-switch detection (WiFi/mobile/dropout kills the active socket,
  /// and Tailscale itself needs seconds to re-establish — the music must
  /// survive that, not go silent).
  // App-lifetime subscription (singleton player); never cancelled.
  // ignore: unused_field
  // ignore: unused_field — held so the subscription lives as long as the app.
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _connDebounce;
  bool _connFirst = true;

  /// True while the phone has no route to the server. main.dart listens to
  /// offer swapping the queue for phone downloads.
  final ValueNotifier<bool> isOffline = ValueNotifier(false);

  /// Fresh one-shot connectivity probe (no listener dependency): true
  /// when the OS reports no route OR the NAS doesn't answer a ping.
  /// Radio-up ≠ reachable (funnel stall, VPN drop, captive portal), so a
  /// radio-only check false-negatives — ping decides. 3s cap, never blocks.
  static Future<bool> probeOffline({ApiClient? api}) async {
    try {
      final res = await Connectivity().checkConnectivity().timeout(
        const Duration(milliseconds: 1500),
      );
      if (res.every((r) => r == ConnectivityResult.none)) return true;
    } catch (_) {
      return false;
    }
    final a = api;
    if (a == null) return false;
    try {
      return !await a.ping().timeout(const Duration(seconds: 3));
    } catch (_) {
      return true;
    }
  }

  /// NAS ping: true when the server answers (TCP connect, 1.5s cap).
  /// Radio-up ≠ reachable — call before heal so a stall/VPN/funnel drop
  /// reads offline (cache) instead of burning resolve attempts. On a miss
  /// flips to the other reachable base once (tailnet ↔ funnel) and re-pings,
  /// so prefetch/covers/streams on the new base just work.
  Future<bool> _nasDown() async {
    final a = _api;
    if (a == null) return false;
    try {
      if (await a.ping().timeout(const Duration(seconds: 3))) return false;
    } catch (_) {}
    try {
      await a.handleBaseFailure().timeout(const Duration(seconds: 5));
    } catch (_) {
      return true;
    }
    try {
      return !await a.ping().timeout(const Duration(seconds: 3));
    } catch (_) {
      return true;
    }
  }

  /// Single choke point for the "radio up, NAS dead?" question: pings when
  /// the flag still says online and flips it when the NAS doesn't answer.
  /// Offline-confirmed = wrap to cached, never blind +1.
  Future<void> _ensureOfflineFlag() async {
    if (!isOffline.value && await _nasDown()) isOffline.value = true;
  }

  /// Stall watchdog baseline (a dead socket doesn't always complete or
  /// error — sometimes the position just freezes).
  // App-lifetime watchdog (singleton player); never cancelled.
  // ignore: unused_field
  // ignore: unused_field — held so the watchdog lives as long as the app.
  Timer? _watchTimer;
  Duration _watchPos = Duration.zero;
  DateTime _watchSince = DateTime.now();

  /// Stall-detector baseline: native position at the last 3s audit tick.
  // App-lifetime audit (singleton player); never cancelled.
  // ignore: unused_field
  // ignore: unused_field — held so the audit lives as long as the app.
  Timer? _auditTimer;
  Duration _auditPos = Duration.zero;

  bool _shuffle = false;

  /// Set by discovery UI so resolve placeholders can be resolved lazily.
  UrlResolver? resolver;

  /// For online album/artist rows that have no video id: resolves an
  /// artist+title pair to a direct audio URL right before that track plays.
  NameResolver? nameResolver;

  /// NAS-first hook for placeholder rows: exact-match NAS file URL, or null.
  /// Runs inside _resolveItemUrl with a 2s cap — never blocks first audio.
  NasLookup? nasLookup;

  /// Wire the standard tap hooks: bounded exact-match NAS-first + lazy name
  /// resolve. ONE call per tap path — keeps all entry points consistent.
  /// NAS hits require an EXACT normCore match (the tolerant server check
  /// used to hand back same-artist different songs).
  void wireTapResolvers(ApiClient api) {
    nameResolver = (artist, title) async =>
        (await api.resolveByName(artist: artist, title: title)).url;
    nasLookup = (artist, title) async {
      try {
        final nas = await api
            .inNas(artist: artist, title: title)
            .timeout(const Duration(seconds: 2));
        final base = nas.baseName ?? '';
        if (!(nas.found && (nas.url?.isNotEmpty ?? false)) || base.isEmpty) {
          return null;
        }
        if (normCore(base) != normCore('$artist - $title')) return null;
        return api.fileUrl(nas.url!);
      } catch (_) {
        return null;
      }
    };
  }

  /// Optional hook to warm the server-side resolve cache for a video ID in
  /// the background (faster next-track start).
  void Function(String videoId)? warm;

  /// Spot/YT-Music autoplay: when set, the player asks this hook for related
  /// internet tracks for [current] and appends them when the queue is short.
  /// Returns online QueueItem rows (title 'Artist - Title', [] if none).
  /// [limit] asks for a bigger batch (keep-ahead); [excludeTitles] are the
  /// raw "Artist - Title" strings the session already has/played, so a refill
  /// for the SAME seed returns FRESH rows instead of the same 15 (endless
  /// scroll — never a fixed "+6").
  Future<List<QueueItem>> Function(
    QueueItem current, {
    int limit,
    List<String> excludeTitles,
  })?
  relatedSource;

  bool _autoplaying = false;
  int _autoplayForIndex = -1;
  DateTime? _lastAddMoreAt;

  /// The keep-ahead engine (spotify/yt-music style "up next").
  ///
  /// `refillWhen == keepAhead` makes the queue **continuous**: it tops back up
  /// to the horizon after EVERY track advance, so the tail never visibly
  /// drains down to a "refill line" and then jumps in a batch — the playback
  /// feed always has rows ahead (endless, never "+N when you reach the Nth").
  final QueuePlanner planner = QueuePlanner(keepAhead: 30, refillWhen: 30);

  /// Pathological-growth guard: the queue only ever grows (nothing is
  /// ever deleted), so this caps runaway appends. Rows are tiny; 150 is
  /// far beyond any real session.
  static const int _hardCap = 150;

  /// Resolve-failure auto-skip budget: how many rows forward _playCurrent
  /// may jump looking for a warm (cached/direct) row before parking with
  /// a visible error. Bounded so a run of dead rows can't spin the queue.
  static const int kMaxResolveSkips = 3;

  /// How many rows the refill asks the server for per request. Larger than the
  /// real deficit on purpose: `pick()` randomizes from a bigger candidate pool
  /// so repeated refills for the same seed diverge instead of returning the
  /// same few closest tracks.
  static const int _requestBatch = 20;

  /// Session-scoped keys of every row ever appended to the queue (normalized
  /// `artist\x00title`), so autoplay never re-suggests the same song twice in
  /// one listening session — the infinite-scroll guarantee.
  final Set<String> _seenKeys = {};

  /// Circular buffer of recently played titles (raw 'Artist - Title').
  /// Used by [_fillRelated] to exclude tracks the listener just heard from
  /// autoplay suggestions — mirrors Spotify/YT-Music behaviour.
  final List<String> _recentlyPlayed = [];
  static const int _maxRecent = 50;

  final ValueNotifier<String> currentTitle = ValueNotifier('');
  final ValueNotifier<bool> shuffleEnabled = ValueNotifier(false);
  final ValueNotifier<bool> repeatEnabled = ValueNotifier(false);
  final ValueNotifier<bool> autoplayEnabled = ValueNotifier(true);
  static const _autoplayKey = 'autoplay';

  Future<void> loadAutoplay() async {
    final prefs = await SharedPreferences.getInstance();
    autoplayEnabled.value = prefs.getBool(_autoplayKey) ?? true;
  }

  Future<void> _persistAutoplay() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoplayKey, autoplayEnabled.value);
  }

  final ValueNotifier<String> currentThumb = ValueNotifier('');
  final ValueNotifier<bool> loading = ValueNotifier(false);
  /// Spinner only after a real stall: fast loads (<800ms) never flash the
  /// wheel — the pause/play icon stays optimistically. Armed via
  /// [_setLoading]; every clear cancels the pending arm.
  static const kSpinnerDelay = Duration(milliseconds: 800);
  Timer? _loadingTimer;

  /// Single choke point for the spinner: `true` arms it delayed (gen-guarded,
  /// cancelled by playing/pause/track-change), `false` clears it now.
  void _setLoading(bool v) {
    _loadingTimer?.cancel();
    if (!v) {
      loading.value = false; // direct: this IS the choke point, no recurse
      return;
    }
    final g = _playGen;
    _loadingTimer = Timer(kSpinnerDelay, () {
      if (g == _playGen && _lastPlayerState != PlayerState.playing) {
        loading.value = true;
      }
    });
  }
  final ValueNotifier<String?> lastError = ValueNotifier(null);
  final ValueNotifier<double> volume = ValueNotifier(1.0);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> trackDuration = ValueNotifier(Duration.zero);
  final ValueNotifier<double> progressFractionNotifier = ValueNotifier(0);
  final ValueNotifier<int> queueLength = ValueNotifier(0);
  /// THE play/pause skin truth. One object, owned here: every play button
  /// (full, mini) listens to this and nothing else. Written only by the
  /// native state-stream listener below (+ the handler-advanced adoption,
  /// which is an implicit playing event) — never seeded from a cached bool,
  /// never snapshotted per-button, so two buttons can never disagree.
  final ValueNotifier<bool> playingN = ValueNotifier(false);
  // True while onResumed/toggle re-queries handler truth. Play buttons
  // gate on this (spinner/disabled) so no tap lands on a stale icon.
  final ValueNotifier<bool> stateSyncing = ValueNotifier(false);

  // keep progress notifier in sync as the player moves
  void _onTick() {
    final d = trackDuration.value;
    progressFractionNotifier.value = d <= Duration.zero
        ? 0
        : (position.value.inMilliseconds / d.inMilliseconds);
  }

  Stream<PlayerState> get stateStream => _player.onPlayerStateChanged;
  bool get playing => _player.isPlaying;

  /// True after the heal budget is exhausted for the current track
  /// (terminal failure — surfaced for server-side error logging).
  bool get gaveUp => _gaveUp;

  /// The active playback backend, so the bridge in main.dart can deliver
  /// handler-isolate events back into the engine.
  PlaybackEngine get engine => _player;
  bool get hasNext => items.isNotEmpty && index < items.length - 1;
  bool get hasPrev => items.isNotEmpty && index > 0;
  Duration get currentPosition => position.value;

  /// Track generation of the latest _playCurrent (bumped per track switch).
  /// The stamp gate compares it against [positionGeneration]: hidden until
  /// the first accepted tick of THIS generation arrives.
  int get playGeneration => _playGen;

  /// Generation the last accepted position tick belongs to (-1 until the
  /// first tick of the current load). Stale/dropped ticks never touch it.
  int get positionGeneration => _posGen;

  /// Set the API client for error logging. Called from main.dart after login.
  void setApiClient(ApiClient api) => _api = api;

  /// Filled fraction (0..1) for progress indicators.
  double get progressFraction {
    final d = trackDuration.value;
    if (d <= Duration.zero) return 0;
    return position.value.inMilliseconds / d.inMilliseconds;
  }

  /// Name of the playlist the current queue came from (null for non-playlist
  /// queues). Used to persist per-playlist shuffle state.
  String? playlistName;

  /// API client for error logging. Set by main.dart after login.
  ApiClient? _api;

  /// Fire-and-forget diagnostic row (interrupt/pause/resume/resync/stamp
  /// evidence). logClientError never throws and carries ?av= itself, so this
  /// is safe on every hot path — no try/catch needed around it.
  void report(String kind, String message) {
    unawaited(_api?.logClientError(kind, message));
  }

  Future<void> playList(
    List<QueueItem> q, {
    int startIndex = 0,
    bool startShuffled = false,
    bool playFromPlaylist = false,
    String? playlistName,
  }) async {
    if (q.isEmpty) return;
    items = List.of(q);
    queueLength.value = items.length;
    fromPlaylist.value = playFromPlaylist;
    this.playlistName = playlistName;
    _shuffle = startShuffled;
    shuffleEnabled.value = _shuffle;
    index = startIndex.clamp(0, items.length - 1);
    playPos = index;
    // Fresh queue: make sure autoplay can top up the new list (the per-index
    // guard from a previous queue must not block the new one).
    _autoplayForIndex = -1;
    // A brand-new queue starts a fresh discovery session: the seen-key set is
    // scoped to ONE queue so a new list can surface tracks the previous one
    // already used.
    _seenKeys.clear();
    // Same for the recently-played repeat-decay window: it must be scoped to
    // THIS queue, not the whole app session. Otherwise a long same-artist
    // session grows it to 50 titles that are then excluded TWICE (server
    // `exclude` param + planner `recent` filter) and the refill pool for a
    // fresh search-tap queue collapses to ~2-4 rows ("only like four more
    // songs"). Within one queue, _seenKeys + the growing window still block
    // repeats; a new queue starts clean like Spotify starting a new radio.
    _recentlyPlayed.clear();
    // Cold engine init runs IN PARALLEL — never before first audio.
    unawaited(_warmEngineForColdStart());
    await _playCurrent();
  }

  /// Cold start: the first play must not race AudioService.init / the handler
  /// port (RemoteEngine's 1s poll). Wait briefly for the session, then play
  /// either way (local fallback still works) — with timeout + log.
  Future<void> _warmEngineForColdStart() async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    if (audioSessionReady.value) return;
    final sw = Stopwatch()..start();
    while (!audioSessionReady.value &&
        sw.elapsed < const Duration(seconds: 4)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    debugPrint(
      '[queue] cold engine warm waited ${sw.elapsedMilliseconds}ms '
      'ready=${audioSessionReady.value}',
    );
  }

  /// True when the current queue came from opening a playlist, so the
  /// full-screen shuffle control only applies to playlist mode (and is
  /// ignored when the song was searched/selected directly from the NAS).
  final ValueNotifier<bool> fromPlaylist = ValueNotifier(false);

  Future<void> playOne(QueueItem it) => playList([it]);

  Future<void> toggleShuffle() async {
    if (items.isEmpty || !fromPlaylist.value) return;
    _shuffle = !_shuffle;
    shuffleEnabled.value = _shuffle;
    final cur = index >= 0 && index < items.length ? items[index] : null;
    if (_shuffle) {
      items.shuffle(Random());
      if (cur != null) {
        items
          ..remove(cur)
          ..insert(index, cur);
      }
    }
    await _persistShuffle();
    _refreshEngineNext();
  }

  Future<void> _persistShuffle() async {
    final name = playlistName;
    if (name == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pl.shuffle.$name', _shuffle);
  }

  Future<void> toggleRepeat() {
    repeatEnabled.value = !repeatEnabled.value;
    // Repeat-one changes the auto-advance target (current vs next row).
    _refreshEngineNext();
    return Future.value();
  }

  Future<void> toggleAutoplay() async {
    autoplayEnabled.value = !autoplayEnabled.value;
    _persistAutoplay();
    if (autoplayEnabled.value) {
      _autoplayForIndex = -1;
      _autoplaying = false;
      await _maybeAutoplay(force: true);
    }
  }

  Future<void> next({int? completedSecs}) async {
    if (items.isEmpty) return;
    // Single-item queue: next would replay the same row from 0 ("swipe
    // restarts the song"). Snap back instead — nothing to advance to.
    if (items.length < 2) {
      DiagLog.restart.log('next ignored (single-item queue)');
      return;
    }
    // Offline/NAS-dead: the queue past the cached window (current+10) is
    // unplayable — a plain +1 lands on a dead row and spins forever.
    // Wrap to the nearest cached row forward (last cached -> first
    // cached). Index jump only, queue order untouched.
    // Flag may be stale-false (radio up, NAS dead): ping regardless so a
    // dead NAS wraps to cache instead of landing +1 on a dead row.
    await _ensureOfflineFlag();
    if (isOffline.value) {
      final n = await _nextCachedIndex(index);
      if (n < 0) {
        _setLoading(false);
        lastError.value = 'No connection — tap play to retry.';
        return;
      }
      index = n;
      playPos = n;
      DiagLog.restart.log('next (offline) -> idx=$n "${items[n].title}"');
      await _playCurrent(completedSecs: completedSecs);
      return;
    }
    index = (index + 1) % items.length;
    playPos = index;
    DiagLog.restart.log('next -> idx=$index "${items[index].title}"');
    await _playCurrent(completedSecs: completedSecs);
  }

  Future<void> previous({bool force = false}) async {
    if (items.isEmpty) return;
    // Swipe-to-previous at the very head: nothing to go back to — no-op
    // (no restart, no wrap to the tail). Explicitly requested for the
    // art-swipe gesture, which passes force:true.
    if (force && index <= 0) {
      DiagLog.restart.log('previous ignored (head of queue)');
      return;
    }
    // Standard transport: when the song is already started (>3s in),
    // PREV restarts it to 0:00; otherwise it goes to the previous track.
    // (Car wheel, notification and the button funnel through here, so they
    // stay consistent.) The art-swipe gesture passes force:true: a swipe
    // is an explicit track-change intent, never a restart.
    if (!force && currentPosition > const Duration(seconds: 3)) {
      DiagLog.restart.log(
        'previous -> restart to 0 (pos=${currentPosition.inSeconds}s)',
      );
      await seek(Duration.zero);
      return;
    }
    // Single-item queue: nothing to go back to, so ignore instead of
    // replaying (which reads as a restart).
    if (items.length < 2) {
      DiagLog.restart.log('previous ignored (single-item queue)');
      return;
    }
    // Offline/NAS-dead: mirror next() — ping regardless of the flag, then
    // jump to the nearest cached row backward (first cached -> last cached).
    await _ensureOfflineFlag();
    if (isOffline.value) {
      final p = await _prevCachedIndex(index);
      if (p < 0) {
        _setLoading(false);
        lastError.value = 'No connection — tap play to retry.';
        return;
      }
      index = p;
      playPos = p;
      DiagLog.restart.log('previous (offline) -> idx=$p "${items[p].title}"');
      await _playCurrent();
      return;
    }
    index = (index - 1 + items.length) % items.length;
    playPos = index;
    DiagLog.restart.log('previous -> idx=$index "${items[index].title}"');
    await _playCurrent();
  }

  /// Play the item at [i] without touching the queue order.
  ///
  /// This does NOT rotate or delete the queue: it simply jumps playback to
  /// item [i]. The visual queue follows along with [playPos] so it scrolls
  /// to that song (previous items remain visible if you scroll up), instead
  /// of re-anchoring the list to [i] and shifting the others out of view.
  Future<void> jumpTo(int i) async {
    if (i < 0 || i >= items.length) return;
    // Same-index jump is a no-op: replaying would read as a restart.
    if (i == index) {
      DiagLog.restart.log('jumpTo($i) ignored (already playing)');
      return;
    }
    // Offline/NAS-dead: an uncached tap target can never resolve —
    // redirect to the nearest cached row forward (wrap), else one toast.
    // Ping regardless of the flag: radio-up-but-NAS-dead reads online.
    await _ensureOfflineFlag();
    if (isOffline.value && await _cachedUriFor(items[i]) == null) {
      final n = await _nextCachedIndex(i - 1);
      if (n < 0) {
        _setLoading(false);
        lastError.value = 'No connection — tap play to retry.';
        return;
      }
      i = n;
      if (i == index) {
        DiagLog.restart.log('jumpTo($i) ignored (already playing)');
        return;
      }
    }
    // Explicit tap = fresh intent: re-arm heal (the 60s error-suppression
    // gate would otherwise swallow retries of a failing row silently).
    // Bounded by the per-track strike budget, so flapping still ends.
    _lastHealAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastHealEnd = DateTime.fromMillisecondsSinceEpoch(0);
    index = i;
    playPos = i;
    DiagLog.restart.log('jumpTo -> idx=$i "${items[i].title}"');
    await _playCurrent();
  }

  /// Play the queue item at [fromIndex] right after the currently playing
  /// song. Swipes append to the "play next" chain in the order you swiped:
  /// current -> A, then current -> A -> B, current -> A -> B -> C, ...
  /// Swiping a song that is already in the chain pushes it to the end.
  /// Returns false if nothing moved (e.g. it's the playing track).
  bool moveToPlayNext(int fromIndex) {
    if (fromIndex < 0 || fromIndex >= items.length) return false;
    if (fromIndex == index) return false;
    final it = items[fromIndex];
    items.removeAt(fromIndex);
    if (fromIndex < index) index -= 1;
    var end = index;
    while (end + 1 < items.length && items[end + 1].manuallyPlaced) {
      end += 1;
    }
    final target = (end + 1).clamp(0, items.length);
    items.insert(target, it);
    it.manuallyPlaced = true;
    queueLength.value = items.length;
    _refreshEngineNext();
    return true;
  }

  /// Insert a brand-new [item] right after the currently playing song
  /// ("play next in queue"). The item is marked [manuallyPlaced] so
  /// autoplay respects it.
  bool playNextNewItem(QueueItem item) {
    if (items.isEmpty) {
      items.add(item);
      item.manuallyPlaced = true;
      queueLength.value = items.length;
      index = 0;
      playPos = 0;
      _playCurrent();
      return true;
    }
    var end = index;
    while (end + 1 < items.length && items[end + 1].manuallyPlaced) {
      end += 1;
    }
    final target = (end + 1).clamp(0, items.length);
    items.insert(target, item);
    item.manuallyPlaced = true;
    queueLength.value = items.length;
    _refreshEngineNext();
    return true;
  }

  /// Remove a non-playing item from the queue (left swipe).
  bool removeFromQueue(int fromIndex) {
    if (fromIndex < 0 || fromIndex >= items.length) return false;
    if (fromIndex == index) return false;
    items.removeAt(fromIndex);
    if (fromIndex < index) index -= 1;
    queueLength.value = items.length;
    _refreshEngineNext();
    return true;
  }

  /// Re-insert a previously removed item (queue-delete Undo). Mirrors
  /// [removeFromQueue] bookkeeping in reverse.
  bool insertAt(int atIndex, QueueItem item) {
    final at = atIndex.clamp(0, items.length);
    items.insert(at, item);
    if (at <= index) index += 1;
    queueLength.value = items.length;
    _refreshEngineNext();
    return true;
  }

  /// Drag-to-reorder within the queue. Moves the item at [oldIndex] to
  /// [newIndex] (already adjusted for the removal, per ReorderableListView's
  /// onReorderItem convention), keeping the "playing" index in sync. [lock]
  /// (when true) prevents the currently playing item from being moved.
  bool reorder(int oldIndex, int newIndex, {bool lock = true}) {
    if (oldIndex < 0 || oldIndex >= items.length) return false;
    if (lock && oldIndex == index) return false; // can't move the playing row
    if (newIndex < 0 || newIndex >= items.length) return false;
    final it = items.removeAt(oldIndex);
    items.insert(newIndex, it);
    // Keep the playing index pointing at the same song after the move.
    if (oldIndex < index && newIndex >= index)
      index -= 1;
    else if (oldIndex > index && newIndex <= index)
      index += 1;
    queueLength.value = items.length;
    _refreshEngineNext();
    return true;
  }

  Future<void> seek(Duration d) {
    _userSeekTarget = d;
    _userSeekAt = DateTime.now();
    DiagLog.restart.log('seek -> ${d.inSeconds}s');
    return _player.seek(d);
  }

  Future<void> setVolume(double v) async {
    volume.value = v.clamp(0.0, 1.0);
    await _player.setVolume(volume.value);
  }

  Future<void> pause() {
    // A deliberate pause cancels any in-flight auto-resume: the user's
    // intent wins over the heal loop. Latched synchronously (before the
    // async engine ack) so heals starting mid-ack still see it.
    _pausedIntent = true;
    _healGen++;
    DebugInfo.pause('tap');
    return _player.pause().then((_) => DebugInfo.pause('ok')).catchError((e) {
      DebugInfo.pause('err $e');
      throw e;
    });
  }

  Future<void> resume() {
    _pausedIntent = false;
    DebugInfo.resume('tap');
    return _player.resume().then((_) => DebugInfo.resume('ok')).catchError((e) {
      DebugInfo.resume('err $e');
      throw e;
    });
  }
  Future<void> stop() => _player.stop();

  /// Ground-truth HUD: engine + handler (getState) state names.
  String get engineStateName => _lastPlayerState.name;
  String get handlerStateName {
    final p = _player;
    return p is RemoteEngine ? p.lastStateName : _lastPlayerState.name;
  }

  Future<void> resumeOrPause() {
    if (!playing && _gaveUp) return retryCurrent();
    final p = _player;
    // Single-tap recover: cached playing may be stale (state event died
    // while suspended). toggleRecover re-queries first, so one tap acts
    // on fresh truth instead of pausing a ghost.
    if (p is RemoteEngine) {
      stateSyncing.value = true;
      return p.toggleRecover().whenComplete(() {
        // toggleRecover flips: outcome IS the intent (playing→play latch
        // clear, paused→fresh pause latch) so later heals obey this tap.
        _pausedIntent = !p.isPlaying;
        stateSyncing.value = false;
      });
    }
    return playing ? pause() : resume();
  }

  /// Called on app resume (UI isolate may have slept while the handler
  /// kept playing/paused). Awaits handler truth via
  /// [RemoteEngine.resync]: state/pos/dur events re-feed the existing
  /// broadcast listeners (attached once in the constructor — never
  /// detached, so nothing to re-attach), correcting a stale [playing]
  /// that froze the play button. [stateSyncing] stays true until the
  /// repaint lands, so the UI blocks taps on the stale icon meanwhile.
  /// Position is restored from the handler's clock, never zeroed.
  /// No-op on desktop (local engine).
  Future<void> onResumed() {
    final p = _player;
    if (p is RemoteEngine) {
      // Interrupt-resync hook: this IS the live path (app resume +
      // focus regain both land here — main.dart), so the row proves the
      // resync fired instead of vanishing into a swallowed catch.
      report('resync', 'fired playing=$playing items=${items.length}');
      stateSyncing.value = true;
      return p.resync().whenComplete(() => stateSyncing.value = false);
    }
    return Future.value();
  }

  /// Visible-screen truth poll (500ms, fire-and-forget): re-asks the
  /// handler for native truth without the stateSyncing gate, so a native
  /// MediaPlayer-JNI pause that fired outside Dart repaints the icon via
  /// the state stream. No-op when backgrounded (lifecycle guard by caller).
  void pollVisibleTruth() {
    final p = _player;
    if (p is RemoteEngine) unawaited(p.pollTruth());
  }

  /// Clear a stuck loading spinner: if this op is still the winner and
  /// playback never reached `playing` within 12s (dropped remote command
  /// on cold start, dead URL), heal once (re-resolve + replay) instead
  /// of spinning until the app is killed. The heal budget bounds retries;
  /// if it also stalls, a tappable error remains.
  void _boundLoading(int gen, int hid) {
    Future.delayed(const Duration(seconds: 12), () {
      if (gen == _playGen &&
          hid == _healGen &&
          loading.value &&
          _lastPlayerState != PlayerState.playing) {
        _setLoading(false);
        lastError.value = 'Playback did not start — retrying…';
        _healCurrent(reason: 'cold-start-timeout');
      }
    });
  }

  Future<void> _playCurrent({int? completedSecs, int skipDepth = 0}) async {
    final gen = ++_playGen;
    // New play = intent to hear audio (clears any pause latch).
    _pausedIntent = false;
    // Pause-intent token for this play: any delayed resume/nudge/fallback
    // checks it at FIRE time (pause() bumps _healGen), so play+instant-pause
    // never auto-resumes.
    final playHeal = _healGen;
    final sw = Stopwatch()..start();
    if (index < 0 || index >= items.length) {
      currentTitle.value = '';
      _setLoading(false);
      return;
    }
    // New track = fresh heal budget.
    _healStrikes = 0;
    _healTrackId = items[index];
    _gaveUp = false;
    // Track-switch stamp: zero the clock SYNCHRONOUSLY with the new title
    // (before any async resolve/audio), and reset the per-load max so stale
    // position ticks from the PREVIOUS track can't flash its timestamp.
    // Wrapped log: seal the outgoing track with its listened seconds
    // (fire-and-forget — never slow down playback). Read BEFORE the clock
    // reset below, or prevSec is always 0.
    final prevTitle = currentTitle.value;
    // Completed tracks seal the full duration: the UI position clock is
    // frozen while backgrounded, so a natural finish would bank ~0s.
    final prevSec = completedSecs ?? position.value.inSeconds;
    // Stamp-switch hook: log ONLY when a stale clock could actually flash —
    // the bar holds a non-trivial previous-track timestamp while that track
    // never produced ticks of its own (failed load: no ticks to correct it).
    // Healthy advances stay silent (server 60/h cap must stay free for real
    // errors). Reads position BEFORE the zeroing below.
    if (position.value > const Duration(seconds: 1) &&
        _posMax <= const Duration(seconds: 1)) {
      report('stamp-switch',
          '"$prevTitle" clock=${position.value.inSeconds}s max=${_posMax.inSeconds}s -> "${items[index].title}"');
    }
    // New track = fresh clock: the old position/duration belong to the
    // previous song. Without this reset a failed internet load (which
    // emits no ticks) freezes the bar at the old song's timestamp, and
    // the NEXT song visibly "starts at X". The stale user-seek target is
    // cleared too: otherwise it whitelists the previous track's tail tick
    // into the new load (seek-match in the stale gate) and flashes it.
    position.value = Duration.zero;
    _posMax = Duration.zero;
    _userSeekTarget = null;
    trackDuration.value = Duration.zero;
    currentTitle.value = items[index].title;
    PlayLog.switched(prevTitle, prevSec, items[index].title);
    currentThumb.value = items[index].thumbUrl ?? '';
    _setLoading(true);
    AppHistory.recordListen(items[index].title);
    final recentKey = items[index].title.toLowerCase();
    _recentlyPlayed.remove(recentKey);
    _recentlyPlayed.add(recentKey);
    if (_recentlyPlayed.length > _maxRecent) {
      _recentlyPlayed.removeAt(0);
    }
    try {
      final item = items[index];
      // A hung resolve (dead socket, stalled /staging/resolve) must never
      // wedge the spinner: 10s cap, then fail loud so later taps still work.
      var resolveTimedOut = false;
      final resolved = await _resolveItemUrl(item, gen).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          resolveTimedOut = true;
          return null;
        },
      );
      if (gen != _playGen) return;
      if (resolved == null) {
        // Hung online resolve (NAS dead, radio up): cached file now at 0,
        // regardless of the offline flag — same as heal failover.
        if (resolveTimedOut && gen == _playGen) {
          if (await _failoverCached(
            item,
            Duration.zero,
            playing,
            hid: playHeal,
            gen: gen,
          )) {
            return;
          }
        }
        // Offline/NAS-dead safety net (auto-advance, heal, race where the
        // flag flipped after next()/jumpTo ran online): never dead-resolve
        // an uncached row — jump to the nearest cached row forward (wrap).
        // Redirects only when offline-confirmed (flag or fresh ping): an
        // online-healthy NAS means a slow resolve, not a dead row — no
        // hijack to cache. Single redirect only (target is cached);
        // all-uncached falls through to the one toast below.
        if ((isOffline.value || resolveTimedOut) && gen == _playGen) {
          await _ensureOfflineFlag();
          if (isOffline.value) {
            final n = await _nextCachedIndex(index);
            if (n >= 0 && n != index) {
              index = n;
              playPos = n;
              DiagLog.restart.log(
                'offline redirect -> idx=$n "${items[n].title}"',
              );
              await _playCurrent(skipDepth: skipDepth);
              return;
            }
          }
        }
        // Bounded auto-skip: an unresolvable row must never park the queue
        // dead (spinner off, same dead index). Jump to the first warm row
        // ahead (cached file / direct URL — no resolve needed); cold
        // placeholders keep resolving in the background via the prefetch
        // wave. Max kMaxResolveSkips hops, then the loud toast+log below.
        if (gen == _playGen &&
            skipDepth < kMaxResolveSkips &&
            items.length > 1) {
          final n = await _nextWarmIndex(index, kMaxResolveSkips);
          if (n >= 0 && n != index && gen == _playGen) {
            lastError.value = tr('Play failed');
            _api?.logClientError(
              'unplayable-skip',
              '${item.title} -> ${items[n].title} (depth=$skipDepth)',
            );
            DiagLog.restart.log(
              'resolve-skip depth=$skipDepth -> idx=$n "${items[n].title}"',
            );
            index = n;
            playPos = n;
            await _playCurrent(skipDepth: skipDepth + 1);
            return;
          }
        }
        // Stale winner or unresolvable: never leave the spinner stuck.
        // Offline with nothing cached says so explicitly (a reconnect
        // heals automatically via the network-change listener).
        if (gen == _playGen) {
          _setLoading(false);
          if (resolveTimedOut) {
            lastError.value = tr('Play failed');
            // Unstick the engine; the hung future can't block later taps
            // (every await below is gen-guarded + bounded).
            unawaited(_player.stop());
          } else if (isOffline.value) {
            lastError.value = 'No connection — tap play to retry.';
          }
          // Report it: an unplayable row is otherwise silent (only the
          // spinner/snackbar shows), and the owner can't see it without
          // the device in hand. Fire-and-forget, capped server-side.
          // Slow-resolve (>3s) and hung-resolve auto-log as timeout with
          // track + elapsed straight into server user_errors.
          final elapsedMs = sw.elapsedMilliseconds;
          _api?.logClientError(
            resolveTimedOut ? 'timeout' : 'unplayable',
            '${item.title} (offline=${isOffline.value},'
            ' elapsed=${elapsedMs}ms)',
          );
        }
        return;
      }
      var url = resolved;
      // Dead-but-returned NAS URL (resolved with no timeout, NAS died
      // since): never play a doomed NAS http — cached file now, else the
      // nearest cached row (same redirect as the null branch above).
      if (!url.startsWith('file://') &&
          _api != null &&
          url.startsWith(_api!.serverBase)) {
        if (!isOffline.value && await _nasDown()) isOffline.value = true;
        if (isOffline.value && gen == _playGen) {
          if (await _failoverCached(
            item,
            Duration.zero,
            playing,
            hid: playHeal,
            gen: gen,
          )) {
            return;
          }
          final n = await _nextCachedIndex(index);
          if (n >= 0 && n != index) {
            index = n;
            playPos = n;
            DiagLog.restart.log(
              'offline redirect -> idx=$n "${items[n].title}"',
            );
            await _playCurrent();
            return;
          }
        }
      }
      // Single player instance reuse: play() swaps the source on the same
      // native player (setDataSource only). An explicit stop() here tears
      // down + rebuilds it (stop/reset/release + prepareAsync ≈300ms).
      if (gen != _playGen) return;
      debugPrint('[queue] play url: $url');
      final src = url.startsWith('file://')
          ? 'file'
          : (url.contains('/staging/api/stream') ||
                url.contains('/staging/resolve/'))
          ? 'relay'
          : 'nas';
      DiagLog.restart.log(
        'play idx=$index src=$src title="${items[index].title}" url=$url',
      );
      // just_audio #1598: awaiting play() can hang forever (it waits for
      // completion on some backends) — fire-and-forget; errors surface via
      // onError/playerStateStream, and _boundLoading heals a silent stall.
      _lastPlayStartAt = DateTime.now();
      // Cold-start guard: a dropped remote command (handler not engaged
      // yet) emits no event ever, leaving loading=true forever. Bound it.
      _boundLoading(gen, playHeal);
      if (gen != _playGen) return;
      unawaited(
        _player.play(url).catchError((Object e) async {
          // Only surface errors for the winning operation. Fire-time
          // pause-intent check: play+instant-pause must NOT resume via
          // the cached fallback.
          if (gen != _playGen || playHeal != _healGen) return;
          // Dead relay/network URL on explicit tap: cached file now at 0
          // instead of a stuck error (not only when isOffline is set).
          final fb = await _cachedUriFor(items[index]);
          if (fb != null &&
              fb != url &&
              gen == _playGen &&
              playHeal == _healGen) {
            try {
              await _player.play(fb);
              _loadedUrl = fb;
              return;
            } catch (_) {}
          }
          if (gen != _playGen) return;
          _setLoading(false);
          lastError.value = e.toString();
          _api?.logClientError(
            'playback',
            '${items[index].title}: $e (elapsed=${sw.elapsedMilliseconds}ms)',
          );
          if (e.toString().contains('401')) _api?.onAuthFailure?.call();
        }),
      );
      // First-tap autoplay: the remote command can land before the handler
      // has media (cold start) and emit no event, sitting paused with the
      // spinner on. One gen-guarded resume nudge fires the handler's
      // _hasMedia recover path; the playing event then clears loading.
      final tapTitle = item.title;
      final tapHeal = _healGen;
      Future.delayed(const Duration(seconds: 2), () {
        // Fire-time pause-token gate (no exceptions): play+instant-pause
        // must never auto-resume via this nudge.
        if (!resumeFireAllowed(
          gen: gen,
          playGen: _playGen,
          healToken: tapHeal,
          currentHeal: _healGen,
          isPlaying: _player.isPlaying,
          pauseIntent: _pausedIntent,
        )) {
          DebugInfo.nudge('gated');
          return;
        }
        DebugInfo.nudge('fired');
        _player.resume();
      });
      // Slow-start auto-log: tap-to-audio >3s with no audio is a silent
      // stall otherwise — log playback/timeout with track + elapsed.
      Future.delayed(const Duration(seconds: 4), () {
        if (gen != _playGen || tapHeal != _healGen || _player.isPlaying) {
          return;
        }
        _setLoading(false);
        lastError.value = tr('Play failed');
        _api?.logClientError(
          'timeout',
          '$tapTitle (slow-start, no audio after ${sw.elapsedMilliseconds}ms)',
        );
      });
      _prefetchNext();
      // Look-ahead covers NEXT songs only — the playing URL streams live
      // and is never fetched (no double-GET with the engine).
      _loadedUrl = url;
      _prefetchAheadFiles(gen);
      _maybeAutoplay();
      _refreshEngineNext();
    } catch (e) {
      // Only surface errors for the winning operation.
      if (gen == _playGen) {
        _setLoading(false);
        lastError.value = e is TimeoutException
            ? tr('Play failed')
            : e.toString();
        _api?.logClientError(
          e is TimeoutException ? 'timeout' : 'playback',
          '${items[index].title}: $e (elapsed=${sw.elapsedMilliseconds}ms)',
        );
      }
    }
  }

  /// Resolve a fresh streamable URL for [item] (direct URLs expire, and die
  /// on network switches). Writes the resolved copy back into the queue
  /// exactly like _playCurrent does. Returns null when a newer play
  /// operation won meanwhile (or the row moved away).
  /// Artist/title identity for NAS-first lookup of a placeholder row.
  /// Prefers explicit resolveName/lyrics keys; falls back to splitting the
  /// display title on ' - '. Null = no usable identity.
  ({String artist, String title})? _nasIdentity(QueueItem item) {
    if (item.resolveName != null) return item.resolveName;
    final la = item.lyricsArtist?.trim() ?? '';
    final lt = item.lyricsTitle?.trim() ?? '';
    if (lt.isNotEmpty) return (artist: la, title: lt);
    final t = item.title.trim();
    if (t.isEmpty) return null;
    final i = t.indexOf(' - ');
    if (i > 0) {
      return (
        artist: t.substring(0, i).trim(),
        title: t.substring(i + 3).trim(),
      );
    }
    return (artist: '', title: t);
  }

  Future<String?> _resolveItemUrl(QueueItem item, int gen) async {
    // Phone-first: a downloaded copy beats NAS and internet alike (and is
    // the only thing playable offline). file:// URIs play in UrlSource.
    final local = OfflineStore.localUriFor(item.title, item.baseName);
    if (local != null) {
      if (isOffline.value) {
        DiagLog.restart.log('offline-cache-hit download "${item.title}"');
      }
      return local;
    }
    // Cache-first: cheap local check before any network. Skip/back play
    // the cached file instantly when present (radio-up-but-NAS-dead would
    // otherwise resolve a dead URL then hang to timeout).
    final cached = await _cachedUriFor(item);
    if (cached != null) {
      DiagLog.restart.log('cache-hit prefetch "${item.title}"');
      return cached;
    }
    // NAS-first for placeholder/relay rows (bounded 2s, typically ~0.2s):
    // the NAS copy beats any stream. Skipped when the row already IS a
    // direct NAS file URL or a resolved googlevideo URL — those play with
    // zero network waits.
    var url = item.url;
    final isDirect =
        url.startsWith('file://') ||
        url.contains('/staging/file/') ||
        url.contains('/staging/pl/') ||
        url.contains('/staging/u/') ||
        (url.startsWith('http') && !url.contains('/staging/'));
    final needsResolve =
        url.isEmpty ||
        url.contains('/staging/resolve/') ||
        item.resolveName != null;
    if (!isDirect && nasLookup != null) {
      final id = _nasIdentity(item);
      if (id != null && (id.artist.isNotEmpty || id.title.isNotEmpty)) {
        try {
          final nasUrl = await nasLookup!(
            id.artist,
            id.title,
          ).timeout(const Duration(seconds: 2));
          if (nasUrl != null && nasUrl.isNotEmpty && gen == _playGen) {
            DiagLog.restart.log('nas-first hit "${item.title}"');
            return nasUrl;
          }
        } catch (_) {}
      }
      if (gen != _playGen) return null;
    }
    // Direct URLs play with NO ping: the pre-play _nasDown() round-trip(s)
    // were the ~2s on every tap. Only rows needing a network resolve ping.
    if (!needsResolve && url.isNotEmpty) return url;
    // Radio-up ≠ reachable: ping before burning resolve attempts on dead URLs.
    if (!isOffline.value && await _nasDown()) isOffline.value = true;
    if (isOffline.value) {
      DiagLog.restart.log('offline-cache-miss "${item.title}"');
      _api?.logClientError('offline-cache-miss', item.title);
      return null;
    }
    try {
      final vid = item.videoId;
      if (vid != null &&
          url.contains('/staging/resolve/') &&
          resolver != null) {
        url = await resolver!(vid).timeout(const Duration(seconds: 10));
        // A newer play request won while we resolved; never overwrite the
        // old item's URL nor start playback for it.
        if (gen != _playGen) return null;
        final idx = items.indexOf(item);
        if (idx < 0 || !identical(items[idx], item)) return null;
        items[idx] = QueueItem(
          item.title,
          url,
          thumbUrl: item.thumbUrl,
          baseName: item.baseName,
          videoId: vid,
          // Preserve re-resolve keys: without them a replay (previous/next
          // back, URL expiry) uses the stored URL verbatim with no way to
          // fetch a fresh one.
          resolveName: item.resolveName,
          manuallyPlaced: item.manuallyPlaced,
          fromInternet: item.fromInternet,
          album: item.album,
          albumImage: item.albumImage,
          lyricsArtist: item.lyricsArtist,
          lyricsTitle: item.lyricsTitle,
        );
      } else if (item.resolveName != null && nameResolver != null) {
        var rn = item.resolveName!;
        // The tapped song is resolved by the caller, so it already has a real
        // URL; only rows further down the album need the lazy lookup.
        url = await nameResolver!(
          rn.artist,
          rn.title,
        ).timeout(const Duration(seconds: 10));
        if (gen != _playGen) return null;
        final idx = items.indexOf(item);
        if (idx < 0 || !identical(items[idx], item)) return null;
        items[idx] = QueueItem(
          item.title,
          url,
          thumbUrl: item.thumbUrl,
          baseName: item.baseName,
          videoId: item.videoId,
          // Preserve re-resolve keys (see above): replay must be able to
          // fetch a fresh URL instead of reusing a dead stored one.
          resolveName: item.resolveName,
          manuallyPlaced: item.manuallyPlaced,
          fromInternet: item.fromInternet,
          album: item.album,
          albumImage: item.albumImage,
          lyricsArtist: item.lyricsArtist,
          lyricsTitle: item.lyricsTitle,
        );
      }
      return url;
    } catch (_) {
      // Network fail/timeout on resolve: cached file now regardless of the
      // offline flag (same as heal failover), else let the caller handle it.
      final fb = await _cachedUriFor(item);
      if (fb != null) {
        DiagLog.restart.log('resolve-failover cached "${item.title}"');
        return fb;
      }
      rethrow;
    }
  }

  /// Freshest resume point at swap time. The heal target goes stale while
  /// resolving (backoff loop), so re-read the live clock just before the
  /// source swap — never seek backward on a frozen (stalled) clock.
  Duration _swapTarget(Duration target, bool wasPlaying) {
    if (!wasPlaying) return target;
    final now = currentPosition;
    return now > target ? now : target;
  }

  /// Seek awaited before resume (+ pos-before/after log). Callers skip the
  /// setSource teardown first when resuming the same bytes (no snapback).
  /// Fire-time pause-intent guard: a user pause (or newer heal/track) that
  /// lands during the seek await must NOT auto-resume — check [hid]/[gen]
  /// AFTER the await, not just at schedule time.
  Future<void> _healSeekResume(
    Duration target,
    bool wasPlaying,
    String why, {
    required int hid,
    required int gen,
  }) async {
    final before = position.value;
    await _player.seek(target);
    // Fire-time check: pause bumps _healGen, track change bumps _playGen.
    if (hid != _healGen || gen != _playGen) return;
    if (healResumeAllowed(wasPlaying: wasPlaying, pauseIntent: _pausedIntent)) {
      await _player.resume();
    }
    DiagLog.restart.log(
      'heal($why) seek-resume at=${target.inSeconds}s '
      'pos-before=${before.inSeconds}s pos-after=${target.inSeconds}s',
    );
  }

  /// Play the cached file:// copy at [target] (dead relay/network-URL
  /// failover — tried regardless of [isOffline], not only when the flag
  /// says so). True = recovered, caller returns.
  Future<bool> _failoverCached(
    QueueItem item,
    Duration target,
    bool wasPlaying, {
    required int hid,
    required int gen,
  }) async {
    final cur = await _cachedUriFor(item);
    if (cur == null) return false;
    if (hid != _healGen || gen != _playGen) return false;
    try {
      // Seek BEFORE resume: play-then-seek replays ~0.5s from 0 first
      // (audible jumpback). Same-bytes resume skips the setSource
      // teardown (decoder reset = keyframe snapback).
      if (cur != _loadedUrl) {
        await _player.setSource(cur);
        _loadedUrl = cur;
      }
      if (hid != _healGen || gen != _playGen) return false;
      await _healSeekResume(target, wasPlaying, 'failover', hid: hid, gen: gen);
      _setLoading(false);
      _lastHealEnd = DateTime.now();
      _lastPlayStartAt = DateTime.now();
      DiagLog.restart.log(
        'heal failover cached at=${target.inSeconds}s (net url dead)',
      );
      // Queued when offline, sent when back online — the release-visible
      // record (debugPrint is stripped in release builds).
      _api?.logClientError(
        'heal-cache-hit',
        '${item.title} at=${target.inSeconds}s',
      );
      _refreshEngineNext();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Re-establish the current track after a network dropout: re-resolve a
  /// fresh URL (old sockets/URLs are dead), reload it, seek back to where
  /// we were, and resume if we were playing. Retries with backoff because
  /// Tailscale itself needs seconds to reconnect; gives up quietly (with
  /// the error surfaced) if the network never comes back. A deliberate
  /// user pause, a track change, or a newer heal aborts the loop.
  Future<void> _healCurrent({required String reason}) async {
    if (items.isEmpty || index < 0 || index >= items.length) return;
    // Bg + paused: no radio/network work — the fg-service is gone and the
    // paused source needs nothing. Bg + playing still heals (screen-off).
    if (!_player.isPlaying &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    // Per-track budget: each watchdog firing must not restart the same
    // track forever. New track (or manual retry) resets the count.
    if (!identical(items[index], _healTrackId)) {
      _healTrackId = items[index];
      _healStrikes = 0;
    }
    // LAZY network-change while playing: never touch the source (decoder
    // teardown + keyframe snap = audible cut even at exact pos). Mark
    // offline, keep the stream buffer; cached failover happens only on a
    // real error/stall at last pos. Paused/stopped fall through unchanged.
    if (reason == 'network-change' && playing) {
      if (!isOffline.value && await _nasDown()) isOffline.value = true;
      DiagLog.restart.log(
        'heal($reason) lazy keep-buffer idx=$index offline=${isOffline.value}',
      );
      _refreshEngineNext();
      return;
    }
    if (_healStrikes >= kMaxHealsPerTrack) {
      // Gave up: the track is dead and nothing else will say so. Report
      // it (fire-and-forget, capped) so it shows in Settings → User errors.
      _api?.logClientError(
        'heal-gave-up',
        '${items[index].title} (reason=$reason, strikes=$_healStrikes)',
      );
      DebugInfo.heal('$reason gave-up');
      return; // gave up; wait for retry
      // ponytail: heal result recorded at give-up/ignore/resume only.

    }
    _healStrikes++;
    final hid = ++_healGen;
    final gen = _playGen;
    final idx = index;
    final item = items[idx];
    // Latch read synchronously: a pause ack still in flight leaves stale
    // `playing == true` — the latch is the truth, never the cached flag.
    final wasPlaying = playing && !_pausedIntent;
    // Stopped = user intent: never autoplay, refill, or rewrite the queue
    // on heal. Stay stopped.
    if (!wasPlaying && _lastPlayerState == PlayerState.stopped) {
      DiagLog.restart.log('heal($reason) ignored (stopped, idx=$idx)');
      DebugInfo.heal('$reason ignored-stopped');
      return;
    }
    _lastHealAt = DateTime.now();
    DebugInfo.heal('$reason start');
    // Stale-position guard: if no position event has arrived for THIS
    // track load yet, currentPosition still holds the previous track's
    // timestamp — healing to it would start the new song mid-way (the
    // "next song starts at the old time" bug). Start at zero instead.
    var target = _posGen == gen ? currentPosition : Duration.zero;
    if (target < Duration.zero) target = Duration.zero;
    // UI truth to fall back to: a failed heal must not leave the bar at
    // 0:00 (the source swap emits pos 0; while paused nothing restores it
    // until resume — fixed 2026-09-18).
    final posBefore = position.value;
    debugPrint('[queue] heal($reason) wasPlaying=$wasPlaying at=$target');
    DiagLog.restart.log(
      'heal($reason) strike=$_healStrikes/$kMaxHealsPerTrack idx=$idx '
      'wasPlaying=$wasPlaying at=${target.inSeconds}s '
      'pos=${position.value.inSeconds}s dur=${trackDuration.value.inSeconds}s '
      'state=${_lastPlayerState.name}',
    );
    _setLoading(true);
    // Radio-up ≠ reachable: a stall/VPN/funnel drop reads online but the
    // NAS is gone — ping first so we read cache instead of burning
    // resolve attempts on dead network URLs.
    if (!isOffline.value && await _nasDown()) isOffline.value = true;
    const waits = [0, 1, 2, 4, 8, 15];
    for (var attempt = 0; attempt < waits.length; attempt++) {
      if (hid != _healGen || gen != _playGen) return;
      if (idx != index || idx >= items.length || !identical(items[idx], item)) {
        return; // queue moved on
      }
      if (attempt > 0) {
        await Future.delayed(Duration(seconds: waits[attempt]));
        if (hid != _healGen || gen != _playGen) return;
        if (idx != index ||
            idx >= items.length ||
            !identical(items[idx], item)) {
          return;
        }
      }
      final errBefore = lastError.value;
      String? url;
      try {
        url = await _resolveItemUrl(item, gen);
      } catch (e) {
        // offline (DNS/Tailscale down) or resolve failed — log the kind,
        // back off and retry
        DiagLog.restart.log('heal($reason) resolve failed: ${e.runtimeType}');
        url = null;
      }
      if (url == null) {
        // Offline + cache miss: current's bytes may still be cached under
        // the alt identity — play them at the current position before
        // skipping/giving up.
        if (isOffline.value && hid == _healGen && gen == _playGen) {
          final cur = await _cachedUriFor(item);
          if (cur != null) {
            try {
              if (hid != _healGen || gen != _playGen) return;
              // Seek BEFORE resume (no play-then-seek jumpback); same-bytes
              // resume skips the setSource teardown (keyframe snapback).
              if (cur != _loadedUrl) {
                await _player.setSource(cur);
                _loadedUrl = cur;
              }
              await _healSeekResume(
                target,
                wasPlaying,
                reason,
                hid: hid,
                gen: gen,
              );
              if (hid != _healGen) {
                try {
                  await _player.pause();
                } catch (_) {}
                return;
              }
              _setLoading(false);
              _lastHealEnd = DateTime.now();
              _lastPlayStartAt = DateTime.now();
              DiagLog.restart.log(
                'heal($reason) cached-current at=${target.inSeconds}s',
              );
              _refreshEngineNext();
              return;
            } catch (_) {}
          }
          final n = await _nextCachedIndex(idx);
          // Skip only when playing AND current has no cache AND next does.
          // Paused/stopped never rewrite the queue — stay put.
          if (n >= 0 && wasPlaying) {
            index = n;
            playPos = n;
            _setLoading(false);
            DiagLog.restart.log(
              'heal($reason) offline skip (no cached-current) -> idx=$n',
            );
            unawaited(_playCurrent());
            return;
          }
          if (n >= 0 && !wasPlaying) {
            DiagLog.restart.log(
              'heal($reason) offline next-cached idx=$n ignored (paused)',
            );
          }
          _setLoading(false);
          lastError.value = 'No connection — tap play to retry.';
        }
        if (isOffline.value) return;
        continue; // blank attempt — back off and retry
      }
      if (hid != _healGen || gen != _playGen) return;
      try {
        if (hid != _healGen || gen != _playGen) return;
        // Seek BEFORE resume: play-then-seek replays ~0.5s from 0 first.
        // Same-song reheal skips the re-source teardown (keyframe snapback).
        if (url != _loadedUrl) {
          await _player.setSource(url);
          _loadedUrl = url;
        }
        await _healSeekResume(target, wasPlaying, reason, hid: hid, gen: gen);
        // User paused mid-heal: never leave it playing — re-pause.
        if (hid != _healGen) {
          try {
            await _player.pause();
          } catch (_) {}
          return;
        }
      } catch (e) {
        DiagLog.restart.log('heal($reason) engine rejected: ${e.runtimeType}');
        // Dead network URL (relay expired/killed): cached file now,
        // same position — don't just back off on a corpse.
        if (hid == _healGen &&
            gen == _playGen &&
            await _failoverCached(
              item,
              target,
              wasPlaying,
              hid: hid,
              gen: gen,
            )) {
          return;
        }
        continue; // engine rejected it — back off and retry
      }
      if (!wasPlaying) {
        debugPrint('[queue] heal($reason) refreshed paused source OK');
        // Restore the UI truth synchronously: the platform often emits
        // nothing more while paused, which left the bar at 0:00.
        position.value = target;
        _lastHealEnd = DateTime.now();
        _setLoading(false);
        return;
      }
      // Playing path: confirm audio actually flows (position advances)
      // instead of assuming the fire-and-forget play() worked.
      final base = position.value;
      var flowed = false;
      for (var i = 0; i < 12; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (hid != _healGen || gen != _playGen) return;
        if (idx != index || !identical(items[idx], item)) return;
        if (lastError.value != errBefore) break; // engine reported failure
        if (position.value > base + const Duration(milliseconds: 800)) {
          flowed = true;
          break;
        }
      }
      if (flowed) {
        debugPrint('[queue] heal($reason) resumed at $target');
        DiagLog.restart.log('heal($reason) resumed at=${target.inSeconds}s');
        DebugInfo.heal('$reason ok @${target.inSeconds}s');
        _lastHealEnd = DateTime.now();
        // Re-arm the slow-start grace: a just-resumed stream needs time to
        // buffer before the watchdog may judge it again.
        _lastPlayStartAt = DateTime.now();
        _refreshEngineNext();
        return;
      }
      // Network URL loads but no audio flows (dead relay): cached file
      // now instead of another backoff on the same corpse.
      if (hid == _healGen &&
          gen == _playGen &&
          await _failoverCached(item, target, wasPlaying, hid: hid, gen: gen)) {
        return;
      }
      // else: fall through to the next backoff attempt
    }
    if (hid == _healGen && gen == _playGen) {
      _setLoading(false);
      if (!wasPlaying) position.value = posBefore;
      final gaveUp = _healStrikes >= kMaxHealsPerTrack;
      lastError.value = gaveUp
          ? 'Stopped after $kMaxHealsPerTrack restarts — tap play to retry.'
          : 'Could not reconnect — check your network.';
      if (gaveUp) _gaveUp = true;
      DiagLog.restart.log(
        'heal($reason) ${gaveUp ? 'GIVE UP' : 'exhausted'} '
        'strikes=$_healStrikes idx=$idx',
      );
      _lastHealEnd = DateTime.now();
    }
  }

  /// file:// URI for a cached copy, trying title, identity alt key, then
  /// explicit downloads. Null = nothing playable offline.
  Future<String?> _cachedUriFor(QueueItem it) async {
    final pre =
        await PrefetchStore.fileFor(it.title, it.baseName) ??
        await PrefetchStore.fileFor(it.identity, it.title);
    if (pre != null) return Uri.file(pre).toString();
    return OfflineStore.localUriFor(it.title, it.baseName) ??
        OfflineStore.localUriFor(it.identity, it.title);
  }

  /// Next queue row (forward wrap) with a playable local copy.
  /// Offline-only path: covers downloads + prefetch under both identities.
  Future<int> _nextCachedIndex(int from) async {
    for (var j = 1; j <= items.length; j++) {
      final n = (from + j) % items.length;
      if (await _cachedUriFor(items[n]) != null) return n;
    }
    return -1;
  }

  /// Prev queue row (backward wrap) with a playable local copy.
  Future<int> _prevCachedIndex(int from) async {
    for (var j = 1; j <= items.length; j++) {
      final n = (from - j % items.length + items.length) % items.length;
      if (await _cachedUriFor(items[n]) != null) return n;
    }
    return -1;
  }

  /// Direct URL needing no resolve (NAS/relay http, file://): playable
  /// without network resolution. Placeholders (/staging/resolve/,
  /// resolveName) are cold — they need a resolve first.
  bool _isDirectWarm(QueueItem it) =>
      it.url.isNotEmpty &&
      !it.url.contains('/staging/resolve/') &&
      it.resolveName == null;

  /// First warm row forward (wrap) within [budget] rows: direct URL wins
  /// sync (no IO); otherwise a cached/downloaded copy; offline only the
  /// cached copy counts (a direct NAS http can never play NAS-dead).
  /// Cold placeholders get a server warm nudge so they resolve in the
  /// background. Pure lookup — no pings, no resolves (battery-cheap).
  Future<int> _nextWarmIndex(int from, int budget) async {
    for (var j = 1; j <= budget && j < items.length; j++) {
      final n = (from + j) % items.length;
      final it = items[n];
      if (_isDirectWarm(it)) {
        if (!isOffline.value) return n;
      } else if (it.videoId != null) {
        try {
          warm?.call(it.videoId!);
        } catch (_) {}
      }
      if (await _cachedUriFor(it) != null) return n;
    }
    return -1;
  }

  /// Manual retry after a give-up (or any stall): fresh budget, fresh play.
  Future<void> retryCurrent() async {
    _healStrikes = 0;
    _gaveUp = false;
    lastError.value = null;
    await _playCurrent();
  }

  /// Spotify/YT-Music autoplay: when the rest of the queue has dropped below
  /// the planner's keep-ahead refill line, ask [relatedSource] for related
  /// internet tracks and append them after the current song, labeled "from
  /// internet". It tops up behind ANY song — including "from internet" rows —
  /// so the "up next" discovery feed keeps growing as you listen (infinite
  /// scroll). The per-index guard prevents re-filling while a song is still
  /// playing, so we don't loop.
  Future<void> _maybeAutoplay({bool force = false}) async {
    // Gate snapshot: one line that discriminates EVERY early-out below.
    // Visible via Settings > Diagnostics > restart log (user-toggleable).
    final gateRemaining = items.length - index - 1;
    DiagLog.restart.log(
      'autoplay-gate enabled=${autoplayEnabled.value} '
      'srcNull=${relatedSource == null} busy=$_autoplaying '
      'idx=$index len=${items.length} rem=$gateRemaining '
      'refill=${planner.shouldRefill(gateRemaining)} '
      'doneIdx=$_autoplayForIndex force=$force playGen=$_playGen '
      'seed="${index >= 0 && index < items.length ? items[index].title : ''}"',
    );
    if (!autoplayEnabled.value) {
      debugPrint('[autoplay] disabled via toggle');
      return;
    }
    if (items.isEmpty) {
      debugPrint('[autoplay] empty queue');
      return;
    }
    if (relatedSource == null) {
      debugPrint('[autoplay] relatedSource is NULL — _wireAutoplay not run?');
      return;
    }
    if (index < 0 || index >= items.length) {
      debugPrint('[autoplay] invalid index=$index len=${items.length}');
      return;
    }
    // The queue only grows: refills append, nothing is ever deleted.
    // Skip logs fire only when remaining is low (healthy "plenty ahead"
    // stays silent so the log isn't noise on every advance).
    final remaining = items.length - index - 1;
    if (_autoplaying) {
      if (planner.shouldRefill(remaining)) {
        DiagLog.restart.log(
          'fill skip: concurrent flight idx=$index remaining=$remaining',
        );
      }
      return;
    }
    if (!force && !planner.shouldRefill(remaining)) {
      debugPrint(
        '[autoplay] shouldRefill=false remaining=$remaining refillWhen=${planner.refillWhen}',
      );
      return;
    }
    // Single-item start: the optimistic head hasn't produced audio yet and
    // the real tail (playlist rows / jump target) hasn't landed — a refill
    // now appends internet rows the tail then fights (len=1 rem=0 race).
    // Defer until playing is confirmed (the state listener re-arms); the
    // completion path (force:true) still tops up a truly single queue.
    if (!force &&
        items.length <= 1 &&
        _lastPlayerState != PlayerState.playing) {
      DiagLog.restart.log(
        'fill skip: single-item starting (audio unconfirmed)',
      );
      return;
    }
    if (_autoplayForIndex == index) {
      DiagLog.restart.log(
        'fill skip: already filled for idx=$index remaining=$remaining',
      );
      return;
    }
    debugPrint(
      '[autoplay] triggering fill idx=$index remaining=$remaining force=$force',
    );
    _autoplayForIndex = index;
    await _fillRelated();
  }

  /// The queue only ever grows (played rows stay for previous()/history).
  /// Refills are demand-driven against a high safety cap, so nothing is
  /// ever deleted out from under the listener.

  /// Manually fetch the next batch of related ("from internet") tracks for the
  /// current song and append them to the queue (planner-ranked + deduped by
  /// NORMALIZED identity). Used by the "Add more" button + the queue sheet's
  /// near-bottom scroll listener for on-demand infinite discovery.
  Future<void> addMore() async {
    if (!autoplayEnabled.value ||
        items.isEmpty ||
        relatedSource == null ||
        index < 0 ||
        index >= items.length ||
        _autoplaying) {
      return;
    }
    // Cooldown so an aggressive scroll/resize listener doesn't fire a new
    // batch every frame while stuck near the bottom.
    if (_lastAddMoreAt != null &&
        DateTime.now().difference(_lastAddMoreAt!) <
            const Duration(seconds: 2)) {
      return;
    }
    _lastAddMoreAt = DateTime.now();
    // Explicit user ask → top up a full keep-ahead batch (never a "+6" trickle).
    await _fillRelated(maxRows: planner.keepAhead);
  }

  /// Fetch + plan the next autoplay batch.
  ///
  /// Pipeline: ask the hook for raw related rows (server already excludes the
  /// titles this session has, via [excludeTitles]), then run the planner
  /// (similarity-first ranking, normalized-key dedup, artist-run cooldown) on
  /// the FULL returned set and append only what makes the queue reach the
  /// keep-ahead horizon. Never a fixed "+N".
  Future<void> _fillRelated({int? maxRows}) async {
    if (relatedSource == null) {
      debugPrint('[autoplay] _fillRelated: relatedSource is NULL');
      return;
    }
    _autoplaying = true;
    // Identity (not raw index): a head-trim mid-flight shifts indices but
    // keeps the same song at the adjusted index — a jump changes the song.
    final requestKey = (index >= 0 && index < items.length)
        ? _itemKey(items[index])
        : '';
    try {
      final remaining = items.length - index - 1;
      debugPrint(
        '[autoplay] _fillRelated start idx=$index remaining=$remaining maxRows=$maxRows',
      );
      // Continuous refill: when called as the per-song top-up (maxRows null),
      // bail out if the queue is ALREADY at the keep-ahead horizon — nothing
      // to add. The explicit maxRows path (Add more / scroll) always fetches.
      final deficit = planner.needed(remaining);
      // Safety cap only (pathological growth guard): the old 30-row hard
      // ceiling wedged the queue permanently, so refills are deficit-driven
      // now and the rolling trim bounds steady-state size instead.
      final headroom = _hardCap - items.length;
      if (headroom <= 0) return;
      if (maxRows == null && deficit <= 0) return;
      final int need = (maxRows ?? deficit).clamp(
        1,
        min(planner.keepAhead * 2, headroom),
      );
      // Everything this session already queued/played, so a refill for the
      // SAME seed returns FRESH rows from the server (endless scroll — not
      // the same 15 recycled and then deduped to nothing). Sent as
      // title-only server norms: the server compares norm(title), so raw
      // "Artist - Title" strings (or space-keeping local norms) never
      // match and exclusion silently did nothing.
      final excludeAll = <String>[
        ..._recentlyPlayed.map(excludeNorm),
        for (final it in items) excludeNorm(it.title),
      ];
      final excludeTitles = excludeAll.length > 150
          ? excludeAll.sublist(excludeAll.length - 150)
          : excludeAll;
      // Ask for a bigger pool than we'll append so pick() can randomize
      // instead of always taking the same closest tracks.
      final int batch = max(need, _requestBatch);
      debugPrint(
        '[autoplay] calling relatedSource batch=$batch seed="${items[index].title}"',
      );
      final rel = await relatedSource!(
        items[index],
        limit: batch,
        excludeTitles: excludeTitles,
      );
      debugPrint('[autoplay] relatedSource returned ${rel.length} rows');
      if (rel.isEmpty) {
        DiagLog.restart.log(
          'fill empty: server returned 0 rows (seed="${items[index].title}")',
        );
        // A starving refill (deficit>0, zero rows back) used to vanish
        // silently. At most one row per seed index (guarded above), capped
        // server-side — and it answers "autoplay just stops" for good.
        _api?.logClientError(
          'autoplay-empty',
          'seed="${items[index].title}" (remaining=$remaining)',
        );
        return;
      }
      // Recheck after the await so a response that lands AFTER the user turned
      // autoplay OFF can't append stale rows. A jump mid-flight only makes
      // the SEED stale — the rows are still fresh, deduped songs, so they
      // land at the tail anyway instead of being dropped (dropping them is
      // what starved the queue while tapping). Re-arm so the next trigger
      // still tops up for the new position.
      if (!autoplayEnabled.value || index < 0 || index >= items.length) {
        return;
      }
      if (_itemKey(items[index]) != requestKey) {
        if (items.length <= 1) {
          // Single-item start moved on mid-flight: stale-seed rows must not
          // land on the fresh single queue (tail fight). Drop; the re-armed
          // trigger refills for the new position once it plays.
          DiagLog.restart.log('fill drop: landed late on single-item start');
          _autoplayForIndex = -1;
          return;
        }
        DiagLog.restart.log('fill landed late (idx=$index) — appending anyway');
        _autoplayForIndex = -1;
      }

      // Planner: rank by closeness to the current track, dedup by normalized
      // identity (NOT raw title), apply the artist-run cooldown.
      final seed = _toCandidate(items[index]);
      final candMap = <String, QueueItem>{};
      for (final it in rel) {
        if (it.title.isEmpty) continue;
        // First occurrence wins on key collisions (planner emits unique keys).
        candMap.putIfAbsent(_itemKey(it), () => it);
      }
      if (candMap.isEmpty) return;
      final seenKeys = <String>{
        for (final it in items) _itemKey(it),
        ..._seenKeys,
      };
      final recentKeys = <String>{
        for (final t in _recentlyPlayed) _keyOfTitle(t),
      };
      final tail = <String>[
        for (var i = index + 1; i < items.length; i++)
          _artistOf(items[i].title),
      ];
      final picked = planner.pick(
        candidates: [for (final it in candMap.values) _toCandidate(it)],
        seed: seed,
        seen: seenKeys,
        recent: recentKeys,
        queueTail: tail,
        maxRows: need,
      );
      if (picked.isEmpty) {
        DiagLog.restart.log(
          'fill picked=0 rel=${rel.length} (all seen/recent — pool exhausted)',
        );
        return;
      }

      // Map picked candidates back to their (already-resolved) QueueItems.
      final fresh = <QueueItem>[];
      for (final c in picked) {
        final it = candMap[c.key];
        if (it == null) continue;
        fresh.add(it);
        // No-repeat memory is bounded: an unbounded set eventually dedups
        // every fresh candidate to nothing (silent refill "stall").
        _seenKeys.add(c.key);
        if (_seenKeys.length > 300) _seenKeys.remove(_seenKeys.first);
      }
      if (fresh.isEmpty) return;
      // "from internet" autoplay is strictly an END-OF-QUEUE top-up.
      // Safety cap at the append point (see [_hardCap]).
      final roomLeft = _hardCap - items.length;
      if (roomLeft <= 0) return;
      final added = fresh.take(roomLeft).toList();
      items.addAll(added);
      queueLength.value = items.length;
      DiagLog.restart.log(
        'fill +${added.length} rows (seed="${seed.artist} - ${seed.title}")',
      );
      _refreshEngineNext();
    } catch (e, st) {
      debugPrint('[autoplay] ERROR in _fillRelated: $e');
      debugPrintStack(stackTrace: st);
      // Autoplay is best-effort; never break playback over it. Still
      // report it — a fill that always throws reads as "autoplay dead".
      _api?.logClientError(
        'autoplay-error',
        'seed="${items[index].title}" err=$e',
      );
    } finally {
      _autoplaying = false;
      _autoplayForIndex = -1;
    }
  }

  /// Planner seed identity for a queue row (lyrics identity when the row
  /// resolved one, else split the 'Artist - Title' display string).
  RelatedCandidate _toCandidate(QueueItem it) {
    final artist = it.lyricsArtist?.isNotEmpty == true
        ? it.lyricsArtist!
        : _artistOf(it.title);
    final title = it.lyricsTitle?.isNotEmpty == true
        ? it.lyricsTitle!
        : _titleOf(it.title);
    return RelatedCandidate(
      artist: artist,
      title: title,
      album: it.album,
      albumImage: it.albumImage,
    );
  }

  /// Normalized dedup key of a queue row.
  String _itemKey(QueueItem it) => _toCandidate(it).key;

  /// Normalized dedup key of a raw 'Artist - Title' string.
  String _keyOfTitle(String t) {
    final split = t.indexOf(' - ');
    if (split > 0) {
      return '${normArtist(t.substring(0, split).trim())}\x00'
          '${normCore(t.substring(split + 3).trim())}';
    }
    return '\x00${normCore(t)}';
  }

  static String _artistOf(String title) {
    final split = title.indexOf(' - ');
    return split > 0 ? title.substring(0, split).trim() : '';
  }

  static String _titleOf(String title) {
    final split = title.indexOf(' - ');
    return split > 0 ? title.substring(split + 3).trim() : title;
  }

  /// Warm the next track's URL in the background so next() starts instantly.
  /// Push the upcoming track to the background handler so it can start it
  /// itself when the current one ends while the UI isolate sleeps with the
  /// screen off (gapless handoff). Recomputed on every track start, resolve,
  /// refill and queue mutation — a stale push would play the wrong song
  /// unattended, so this never caches: it derives from the live queue.
  /// Prefers the repeat-one target when repeat is on; mirrors next()'s
  /// wrap-around at the queue end. Unresolvable placeholders are skipped —
  /// _prefetchNext pushes again once they resolve.
  void _refreshEngineNext() async {
    if (items.isEmpty || index < 0 || index >= items.length) {
      _player.queueNext();
      return;
    }
    // Radio-up ≠ reachable: await the ping BEFORE pushing — a sync http
    // push with a fire-and-forget ping lets the handler autostart a stale
    // http URL unattended. NAS-dead-known pushes cached file:// instead.
    if (!isOffline.value && await _nasDown()) isOffline.value = true;
    // Offline: the handler autostarts this push unattended — a NAS http URL
    // would fail blind. Push the cached file:// instead (or clear).
    if (isOffline.value) {
      await _refreshEngineNextOffline();
      return;
    }
    final QueueItem it;
    if (repeatEnabled.value) {
      it = items[index];
    } else if (index + 1 < items.length) {
      it = items[index + 1];
    } else {
      it = items[0];
    }
    final u = it.url;
    if (u.isEmpty ||
        u.contains('/staging/resolve/') ||
        it.resolveName != null) {
      return;
    }
    final t = it.lyricsTitle?.isNotEmpty == true
        ? '${it.lyricsArtist ?? ''} - ${it.lyricsTitle}'
        : it.title;
    final split = t.indexOf(' - ');
    _player.queueNext(
      url: u,
      title: split > 0 ? t.substring(split + 3).trim() : t,
      artist: split > 0 ? t.substring(0, split).trim() : '',
      album: it.album,
    );
  }

  /// Offline half of [_refreshEngineNext]: push a cached file:// URL the
  /// handler can autostart with no network, else clear the pre-push (the
  /// next natural completion then reroutes through offline-aware next()).
  Future<void> _refreshEngineNextOffline() async {
    if (items.isEmpty || index < 0 || index >= items.length) {
      _player.queueNext();
      return;
    }
    QueueItem it = items[index];
    if (!repeatEnabled.value) {
      final n = await _nextCachedIndex(index);
      if (n < 0) {
        _player.queueNext();
        return;
      }
      it = items[n];
    }
    final cu = await _cachedUriFor(it);
    if (cu == null) {
      _player.queueNext();
      return;
    }
    final t = it.lyricsTitle?.isNotEmpty == true
        ? '${it.lyricsArtist ?? ''} - ${it.lyricsTitle}'
        : it.title;
    final split = t.indexOf(' - ');
    _player.queueNext(
      url: cu,
      title: split > 0 ? t.substring(split + 3).trim() : t,
      artist: split > 0 ? t.substring(0, split).trim() : '',
      album: it.album,
    );
  }

  /// The handler isolate started the pre-pushed track on its own (it fired
  /// while this isolate slept). Adopt it: advance the playhead and refresh
  /// all per-track state — but never touch the player, it's already playing.
  /// Anything unexpected (queue mutated mid-flight) falls back to ignoring
  /// the event; the next natural completion re-syncs.
  Future<void> _onHandlerAdvanced(String url) async {
    if (url.isEmpty || items.isEmpty) return;
    int n = -1;
    if (repeatEnabled.value &&
        index >= 0 &&
        index < items.length &&
        items[index].url == url) {
      n = index;
    } else {
      n = items.indexWhere((e) => e.url == url);
      if (n < 0) {
        // Offline pushes carry file:// cache URIs, not queue urls.
        for (var i = 0; i < items.length; i++) {
          if (await _cachedUriFor(items[i]) == url) {
            n = i;
            break;
          }
        }
      }
    }
    if (n < 0 || n >= items.length) return;
    // Radio-up ≠ reachable: ping (not flag-only) before adopting — a stale
    // blind push's http URL can never have played with the NAS dead.
    if (!isOffline.value && await _nasDown()) isOffline.value = true;
    // Clamp: offline, adopt only cached rows. A stale blind push's http URL
    // can never have played with the NAS dead (its failure reroutes via
    // complete), so ignoring it here never desyncs real audio.
    if (isOffline.value && await _cachedUriFor(items[n]) == null) return;
    // Natural completion advances outside _playCurrent — seal the finished
    // track here or Wrapped only ever records skips, never listens.
    // Full duration: the UI clock is frozen while backgrounded, so the
    // stale position would bank ~0s for a fully-played song.
    final prevTitle = currentTitle.value;
    final prevSec = max(
      position.value.inSeconds,
      trackDuration.value.inSeconds,
    );
    index = n;
    playPos = n;
    final it = items[index];
    // Track-switch stamp: zero the clock BEFORE publishing the new title
    // (same order as _playCurrent) — listeners rebuild off the title, so a
    // title-first order flashes the previous song's timestamp for a frame.
    // Full per-load parity with _playCurrent: stamp hidden until the new
    // id's first tick (_posGen invalidated), stale seek cleared (must not
    // whitelist the old tail), fresh heal budget + play-start baseline.
    position.value = Duration.zero;
    _posMax = Duration.zero;
    _posGen = -1;
    _userSeekTarget = null;
    _healStrikes = 0;
    _healTrackId = it;
    _lastPlayStartAt = DateTime.now();
    trackDuration.value = Duration.zero;
    currentTitle.value = it.title;
    PlayLog.switched(prevTitle, prevSec, it.title);
    currentThumb.value = it.thumbUrl ?? '';
    AppHistory.recordListen(it.title);
    final recentKey = it.title.toLowerCase();
    _recentlyPlayed.remove(recentKey);
    _recentlyPlayed.add(recentKey);
    if (_recentlyPlayed.length > _maxRecent) {
      _recentlyPlayed.removeAt(0);
    }
    // The handler advanced on its own = audio IS flowing (it can't advance
    // a paused track). Mark it so the single-item refill gate below doesn't
    // mistake a stale UI-isolate state for "audio unconfirmed".
    // handler-advanced adoption: an implicit playing event, so it writes
    // the skin truth too (co-writer with the state listener only).
    _lastPlayerState = PlayerState.playing;
    playingN.value = true;
    _prefetchNext();
    _maybeAutoplay();
    _refreshEngineNext();
  }

  void _prefetchNext() {
    if (items.isEmpty) return;
    final n = (index + 1) % items.length;
    final it = items[n];
    if (it.videoId != null &&
        (it.url.contains('/staging/resolve/') || it.resolveName != null) &&
        resolver != null) {
      resolver!(it.videoId!)
          .then((u) {
            if (n < items.length &&
                identical(items[n], it) &&
                it.videoId == items[n].videoId) {
              items[n] = QueueItem(
                it.title,
                u,
                thumbUrl: it.thumbUrl,
                baseName: it.baseName,
                videoId: it.videoId,
                // Preserve re-resolve + display fields (same data-loss
                // class as the _resolveItemUrl write-back): without these
                // a replay can never re-resolve and art/album vanish.
                resolveName: it.resolveName,
                manuallyPlaced: it.manuallyPlaced,
                fromInternet: it.fromInternet,
                album: it.album,
                albumImage: it.albumImage,
                lyricsArtist: it.lyricsArtist,
                lyricsTitle: it.lyricsTitle,
              );
              _refreshEngineNext();
            }
          })
          .catchError((_) {});
      warm?.call(it.videoId!);
    } else if (it.resolveName != null && nameResolver != null) {
      final rn = it.resolveName!;
      nameResolver!(rn.artist, rn.title)
          .then((u) {
            if (n < items.length && identical(items[n], it)) {
              items[n] = QueueItem(
                it.title,
                u,
                thumbUrl: it.thumbUrl,
                baseName: it.baseName,
                videoId: it.videoId,
                // Same preservation as above: dropping these loses
                // re-resolvability and art/album on replay.
                resolveName: it.resolveName,
                manuallyPlaced: it.manuallyPlaced,
                fromInternet: it.fromInternet,
                album: it.album,
                albumImage: it.albumImage,
                lyricsArtist: it.lyricsArtist,
                lyricsTitle: it.lyricsTitle,
              );
              _refreshEngineNext();
            }
          })
          .catchError((_) {});
    }
  }

  /// Look-ahead file cache: while online, fetch the NEXT few queue songs'
  /// bytes into [PrefetchStore] so going offline mid-queue doesn't stop
  /// playback (the playing song streams live and is never fetched — no
  /// double-GET with the engine). Best-effort background pass
  /// (WiFi-gated + capped inside the store). The first wave (next 3)
  /// starts IMMEDIATELY on play — no stagger delay, no resumed requirement —
  /// so the most urgent bytes land before any offline switch; songs past
  /// that are foreground-only (battery). A wave started online runs to
  /// completion (gen-guarded only, never offline-aborted): going offline
  /// mid-wave just fails the remaining fetches fast inside the store.
  /// Each pass owns one HTTP client: when a newer play supersedes it,
  /// closing that client aborts in-flight downloads immediately instead
  /// of letting zombie 5MB GETs saturate the pipe for up to 60s each.
  http.Client? _prefetchClient;

  /// Batch liked flags for the in-flight prefetch wave (one call per
  /// wave, not one per row). Read by fetchOne via the closure.
  Map<String, bool> _waveLiked = {};

  void _prefetchAheadFiles(int gen) async {
    if (items.isEmpty || index < 0) return;
    final upcoming = PrefetchStore.window(
      items,
      index + 1,
      PrefetchStore.aheadCount,
    );
    if (upcoming.isEmpty) return;
    // Supersede the previous pass first: its in-flight downloads die
    // with its client instead of fighting the new track's stream.
    try {
      _prefetchClient?.close();
    } catch (_) {}
    final passClient = http.Client();
    _prefetchClient = passClient;
    DiagLog.restart.log(
      'prefetch-pass start=${upcoming.first.title} count=${upcoming.length} '
      'gen=$gen offline=${isOffline.value}',
    );
    Future<void> fetchOne(QueueItem it) async {
      var url = it.url;
      final vid = it.videoId;
      if (url.contains('/staging/resolve/')) {
        // Placeholder: nothing cacheable until resolved to http.
        if (vid == null || resolver == null) return;
        try {
          url = await resolver!(vid).timeout(const Duration(seconds: 10));
        } catch (_) {
          return;
        }
      } else if (it.resolveName != null && nameResolver != null) {
        final rn = it.resolveName!;
        try {
          url = await nameResolver!(
            rn.artist,
            rn.title,
          ).timeout(const Duration(seconds: 10));
        } catch (_) {
          return;
        }
      }
      // Server-relative NAS/relay paths are cacheable too — absolutize
      // instead of dropping them in the http check below.
      if (url.startsWith('/staging/') && _api != null) {
        url = '${_api!.serverBase}$url';
      }
      if (url.startsWith('file://')) return;
      // A superseded pass dies here; an offline switch does NOT abort —
      // the wave started online runs out, remaining fetches fail fast.
      if (gen != _playGen) return;
      if (!url.startsWith('http')) return;
      // Liked comes from the queue item when the playlist payload threaded
      // it through; otherwise ONE batch call covers the whole wave — never
      // a likedStatus roundtrip per row (funnel: N calls fighting audio).
      final liked = it.liked ?? _waveLiked[it.identity];
      await PrefetchStore.fetch(
        it.title,
        url,
        client: passClient,
        baseName: it.baseName,
        thumbUrl: (it.thumbUrl?.isNotEmpty ?? false)
            ? it.thumbUrl
            : it.albumImage,
        liked: liked,
      );
    }

    // One batch liked-status lookup for the whole wave (rows without a
    // threaded flag get it here; failures leave them unknown, never fatal).
    // The CURRENT fetch fires first so first audio never waits on it.
    final waveLiked = <String, bool>{};
    _waveLiked = waveLiked;
    try {
      if (_api != null) {
        final missing = [
          for (final it in upcoming)
            if (it.liked == null) it.identity,
        ];
        if (missing.isNotEmpty) {
          waveLiked.addAll(
            await _api!.likedBatch(missing).timeout(const Duration(seconds: 8)),
          );
        }
      }
    } catch (_) {}
    Future<void> worker(ListQueue<QueueItem> pending) async {
      while (true) {
        if (gen != _playGen) return;
        if (pending.isEmpty) return;
        final it = pending.removeFirst();
        try {
          await fetchOne(it);
        } catch (_) {}
      }
    }

    // First wave (next 3) NOW, no stagger, fg or bg; the rest fg-only.
    final firstPending = ListQueue.of(upcoming.take(3));
    for (var i = 0; i < PrefetchStore.fetchConcurrency; i++) {
      unawaited(worker(firstPending));
    }
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final restPending = ListQueue.of(upcoming.skip(3));
    for (var i = 0; i < PrefetchStore.fetchConcurrency; i++) {
      unawaited(worker(restPending));
    }
  }
}
