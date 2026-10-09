import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:workmanager/workmanager.dart';

import 'api_client.dart';
import 'announcer.dart';
import 'deep_link.dart';
import 'audio_handler.dart';
import 'audio_session_state.dart';
import 'auth_store.dart';
import 'bg_announce.dart';
import 'debug_overlay.dart';
import 'diag_log.dart';
import 'lang.dart';
import 'play_log.dart';
import 'offline_store.dart';
import 'prefetch_store.dart';
import 'replace_tracker.dart';
import 'keep_dialog.dart';
import 'now_playing.dart' show NowPlayingRoute;
import 'playback_engine.dart';
import 'queue_player.dart';
import 'screens/library_screen.dart';
import 'screens/listen_history_screen.dart';
import 'screens/login_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/user_errors_screen.dart';
import 'screens/staging_screen.dart';
import 'screens/wrapped_screen.dart';
import 'theme.dart';
import 'toast.dart';
import 'widgets.dart';

const _kServerKey = 'server_base_url';

/// Bridge port that receives transport commands (play/pause/seek/next/prev)
/// from the audio_service handler (the shared engine) and forwards them to the
/// real QueuePlayer in this main isolate.
final ReceivePort _audioCmdPort = ReceivePort();

void _handleAudioCommand(dynamic msg) {
  final qp = QueuePlayer.instance;
  if (msg is String) {
    // Events from the handler arrive JSON-encoded ({"ev":"pos",...}); the
    // bare transport commands arrive as plain strings. Try JSON first so
    // pos/dur/state/err events aren't swallowed by the command switch below.
    if (msg.startsWith('{')) {
      _decodeAudioJson(msg);
      return;
    }
    DiagLog.car.log('cmd from handler/session: $msg');
    switch (msg) {
      case 'play':
        qp.resume();
        break;
      case 'pause':
        qp.pause();
        break;
      case 'stop':
        qp.stop();
        break;
      case 'next':
        qp.next();
        break;
      case 'prev':
        qp.previous();
        break;
    }
    return;
  }
  if (msg is List<int>) {
    _decodeAudioJson(utf8.decode(msg));
  }
}

void _decodeAudioJson(String json) {
  final qp = QueuePlayer.instance;
  try {
    final m = jsonDecode(json);
    final ev = m?['ev'];
    if (ev != null) {
      // State/position/errors pushed back from the handler isolate's real
      // player (mobile). Rehydrate the engine's streams so the queue sees
      // them exactly as if the player were local.
      if (ev != 'pos') {
        DiagLog.car.log('handler ev: $json');
      }
      final e = qp.engine;
      if (e is RemoteEngine) e.feedRemoteEvent(m);
      // Media-session transport reports (BT headset / car wheel /
      // notification play/pause): the handler already Paused/resumed its
      // player — fold the intent into the queue so the heal loop obeys it
      // (pause latches, play clears), without re-sending a command back.
      if (ev == 'transport') {
        final rep = transportReportFor(m?['op']?.toString());
        if (rep == TransportReport.paused) {
          qp.onTransportPause();
        } else if (rep == TransportReport.resumed) {
          qp.onTransportResume();
        }
        return;
      }
      // External-audio callbacks must FORCE handler truth, not just fold the
      // event in: a focus loss/regain that lands while the UI isolate sleeps
      // leaves a stale icon (events alone already missed once). Re-query via
      // the same resync the app-resume path uses — play buttons stay disabled
      // (stateSyncing) until the repaint lands.
      if (ev == 'focus') {
        final phase = m?['phase']?.toString();
        if (phase == 'lost-honored' ||
            phase == 'regained' ||
            phase == 'regained-stay-paused') {
          // Interrupt hooks on the LIVE path (right next to the onResumed
          // call that proves it executes): external pause-fire / resume-fire
          // rows instead of silent icon flips.
          if (phase == 'lost-honored') {
            qp.report('pause-fire', 'focus lost-honored ${m?['type']}');
          } else {
            qp.report('resume-fire', 'focus $phase ${m?['type']}');
          }
          unawaited(qp.onResumed());
        }
      }
      return;
    }
    final seekMs = m?['seek_ms'];
    if (seekMs is num) {
      qp.seek(Duration(milliseconds: seekMs.toInt()));
    }
  } catch (_) {}
}

/// Pushes current media metadata into the handler isolate so the lock-screen /
/// notification reflect what the queue is showing. The handler derives
/// playing/position/duration from ITS OWN player (it owns audio on mobile),
/// so this push carries no playback timing.
///
/// Throttled: at most once per second to avoid flooding the isolate port
/// on every high-frequency position tick.
DateTime _lastPushAt = DateTime.fromMillisecondsSinceEpoch(0);
String _lastPushedIdentity = '';
Future<void> _pushAudioState() async {
  final now = DateTime.now();
  final identity =
      '${QueuePlayer.instance.currentTitle.value}|${QueuePlayer.instance.currentThumb.value}';
  // The throttle is for the HIGH-FREQUENCY position ticks that re-push the
  // SAME track. When the track identity actually changed (user skipped/next in
  // the same second), ALWAYS push: the play command races down the port, and
  // if this metadata never lands the handler would publish the PREVIOUS song's
  // title for the new URL (car shows the wrong song).
  if (identity == _lastPushedIdentity &&
      now.difference(_lastPushAt) < const Duration(seconds: 1))
    return;
  _lastPushedIdentity = identity;
  _lastPushAt = now;
  final sp = IsolateNameServer.lookupPortByName(kAudioStatePort);
  if (sp == null) return;
  final qp = QueuePlayer.instance;
  final art = qp.currentThumb.value;
  final hasMedia =
      qp.items.isNotEmpty && qp.index >= 0 && qp.index < qp.items.length;
  // AVRCP/car head units show artist + song independently; a raw "Artist -
  // Song" in the title with no artist field renders as a blank track. Split it.
  final full = qp.currentTitle.value.replaceAll('.{ext}', '');
  final sep = full.indexOf(' - ');
  final artist = sep > 0 ? full.substring(0, sep).trim() : (hasMedia ? '' : '');
  final song = sep > 0 ? full.substring(sep + 3).trim() : full;
  final item = hasMedia ? qp.items[qp.index] : null;
  final msg = <String, dynamic>{
    'has_media': hasMedia,
    'title': song,
    'artist': artist,
    'album': (item?.album?.isNotEmpty ?? false) ? item!.album! : '',
    'art': art,
    'loading': qp.loading.value,
  };
  DiagLog.car.log(
    'push has_media=$hasMedia title="$song" artist="$artist" '
    'album="${(item?.album?.isNotEmpty ?? false) ? item!.album! : ''}"',
  );
  // Send base metadata IMMEDIATELY (before any art await below). The handler's
  // play command lands on the same port; if this message waited for the art
  // download, the play cmd could arrive first and the handler would publish
  // the previous track's title for the new URL.
  sp.send(jsonEncode(msg));
  // On mobile, the media-session artwork loader is unreliable at fetching
  // remote HTTP URLs. Download the cover bytes here and hand them to the
  // handler so it writes a local file and publishes a content:// artUri
  // (served by our exported ArtFileProvider) that SystemUI renders
  // dependably. Only re-download when the track's art actually changes.
  // Sent as a SEPARATE message so art never blocks the track-change metadata.
  final cached = _artWorks != art;
  _artWorks = art;
  if (hasMedia && art.isNotEmpty) {
    if (cached) {
      _artBytes = null;
      _artFut = _downloadArt(art);
    }
    if (_artBytes != null) {
      sp.send(jsonEncode({'art_bytes': _artBytes}));
    } else if (_artFut != null) {
      try {
        final b = await _artFut;
        if (b != null) {
          _artBytes = b;
          sp.send(jsonEncode({'art_bytes': b}));
        }
      } catch (_) {}
    }
  }
}

String _artWorks = '';
String? _artBytes;
Future<String?>? _artFut;

/// Downloads [url] and returns it base64-encoded so it can cross the isolate
/// port. Returns null on any failure (the notification then falls back to the
/// URL form, or no art).
Future<String?> _downloadArt(String url) async {
  try {
    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return null;
    return base64Encode(resp.bodyBytes);
  } catch (_) {
    return null;
  }
}

/// Android 13+ requires a runtime OK for the media-session notification /
/// reliable background playback. Request it up front (best-effort; never
/// block startup on it). Mobile-only: audio_service/audio_session/
/// permission_handler have no Linux desktop implementation.
bool _mobileOnlyAudio() =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Android 13+ requires a runtime OK for the media-session notification /
/// reliable background playback. Request it up front (best-effort; never
/// block startup on it).
Future<void> _requestNotificationPermission() async {
  if (!_mobileOnlyAudio()) return;
  try {
    final status = await Permission.notification.status;
    if (!status.isGranted) {
      await Permission.notification.request();
    }
  } catch (_) {
    // ignore: permission failures must never block the app.
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _requestNotificationPermission();
  // Load persisted theme + UI look prefs BEFORE the first frame so the app
  // never flashes the default palette.
  await ThemeStore.instance.init();
  await UiStore.instance.init();
  await LocaleStore.instance.init();
  // Multi-user session: token/username/device survive restarts, so the
  // device remembers its login until an explicit logout.
  await AuthStore.instance.init();
  await DiagLog.initAll();
  await DebugInfo.load();
  await OfflineStore.init();
  await OfflineStore.loadMode();
  // Look-ahead cache BEFORE first frame: rebuilds the per-user disk index
  // (orphan mp3s adopted) so offline kill+reopen finds prefetched songs.
  await PrefetchStore.init();
  final prefs = await SharedPreferences.getInstance();
  // Fresh installs default to the public funnel URL: it works with no
  // Tailscale on the phone (the old tailnet default left every new user
  // staring at a dead app). Stored values are never migrated.
  var base =
      prefs.getString(_kServerKey) ??
      (const String.fromEnvironment('NASMUSIC_SERVER').isNotEmpty
          ? const String.fromEnvironment('NASMUSIC_SERVER')
          : 'https://naboo.taildfeb4f.ts.net');
  // Heal stored values saved before normalization (trailing `/staging`
  // produced `/staging/staging/...` on every call for public-URL users).
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  if (base.toLowerCase().endsWith('/staging')) {
    base = base.substring(0, base.length - '/staging'.length);
    try {
      await prefs.setString(_kServerKey, base);
    } catch (_) {}
  }
  // Bridge: handler -> this main-isolate player. Remove-then-register:
  // a swipe-closed process can survive cached with stale mappings, and a
  // leftover name makes this registration silently fail (dead first
  // launch after close).
  IsolateNameServer.removePortNameMapping(kAudioBridgePort);
  final bridgeOk = IsolateNameServer.registerPortWithName(
    _audioCmdPort.sendPort,
    kAudioBridgePort,
  );
  debugPrint('[audio] bridge port registered: $bridgeOk');
  _audioCmdPort.listen(_handleAudioCommand);
  runApp(NasMusicApp(baseUrl: base));
  // Remember the installed version for the background isolate (it can't
  // use PackageInfo channels, so it reads this pref instead).
  try {
    final pi = await PackageInfo.fromPlatform();
    await prefs.setString('installed.version', pi.version);
  } catch (_) {}
  // Background announcements (Android only): WorkManager wakes the app
  // every ~30min even with the screen off / app dead, so update + broadcast
  // notices arrive like any other app's. Same prefs/ids as the foreground
  // Announcer, so no double-ping. Inexact under Doze, no FCM needed.
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      await Workmanager().initialize(bgAnnounceDispatcher);
      await Workmanager().registerPeriodicTask(
        bgAnnounceTask,
        bgAnnounceTask,
        frequency: const Duration(minutes: 30),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (_) {}
  }
  // Start the media session + foreground service so playback keeps going with
  // the screen off and shows lock-screen / notification controls. Done AFTER
  // runApp (and soft-fail) so a slow/erroring service can never black-screen
  // the app on launch.
  _initAudioService();
}

/// MethodChannel events from the native side (MainActivity). Currently only
/// used for ACTION_AUDIO_BECOMING_NOISY (headphones / car stereo disconnect).
const _kAudioEventChannel = MethodChannel('com.nasmusic.nasmusic/audio_events');

/// Deep links: shared Spotify / YT-Music links opened with this app land here
/// (Android intent-filters in AndroidManifest.xml; MainActivity stores the
/// cold-start URL and forwards warm ones via this channel).
const _kDeepLinkChannel = MethodChannel('com.nasmusic.nasmusic/deep_links');

Future<void> _initAudioService() async {
  if (!_mobileOnlyAudio()) return;
  try {
    // Configure the audio_session audioplayers uses so it keeps the audio
    // focus for playback while backgrounded.
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    await AudioService.init(
      builder: () => NASMusicAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.nasmusic.nasmusic.channel.audio',
        androidNotificationChannelName: 'Playback',
        // Keep the mediaPlayback fg-service while playing: dropping it on
        // every pause kills bg playback on Android 12+. Idle stops stay
        // explicit (AudioService.stop on paused-empty / 10min timer in
        // didChangeAppLifecycleState), never via this auto flag.
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
        // PNG glyph (white note, drawable-nodpi): vectors crashed
        // notification posting on-device, the launcher flattens to a
        // white square. A pre-rendered opaque PNG is the textbook
        // smallIcon — art still shows via the metadata bitmap.
        androidNotificationIcon: 'drawable/ic_stat_music',
        // Tints the small white silhouette (largeIcon cover untouched —
        // that bitmap still comes from the session art).
        notificationColor: Color(0xFF1DB954),
      ),
    );
    // Push the current (possibly idle) state once the session is up.
    _pushAudioState();
    audioSessionReady.value = true;
    // Catch ACTION_AUDIO_BECOMING_NOISY ourselves. NOTE: we deliberately do
    // NOT use audio_session.setActive(true) + its becomingNoisyEventStream:
    // audioplayers requests its own audio focus when a song starts, which
    // takes focus away from audio_session — its Java handler then calls
    // abandonAudioFocus() and unregisters its noisy receiver, so the event
    // would arrive only when NOT plugged into anything. Our own (focus-free)
    // receiver in MainActivity is what reaches Dart here.
    _kAudioEventChannel.setMethodCallHandler((call) async {
      if (call.method == 'becomingNoisy') {
        // Pause-fire hook: headphones/car-stereo disconnect is the one
        // pause path with no UI tap, so it gets its own row (was silent).
        QueuePlayer.instance.report('pause-fire', 'becoming-noisy');
        QueuePlayer.instance.pause();
      }
    });
  } catch (e, st) {
    // DO NOT ignore silently: if this fails there is NO MediaSession, so
    // Bluetooth AVRCP (car metadata + steering-wheel controls) sees nothing
    // even though the fallback local player still streams audio. Log it loud
    // AND surface it: a release build hides debugPrint, and an invisible
    // tray with working in-app audio is exactly this failure.
    debugPrint('[audio] AudioService.init FAILED: $e\n$st');
    QueuePlayer.instance.lastError.value = "${tr('Audio service failed')}: $e";
  }
}

class NasMusicApp extends StatefulWidget {
  const NasMusicApp({super.key, required this.baseUrl});
  final String baseUrl;

  @override
  State<NasMusicApp> createState() => _NasMusicAppState();
}

class _NasMusicAppState extends State<NasMusicApp> with WidgetsBindingObserver {
  late String _baseUrl = widget.baseUrl;
  late ApiClient _api = ApiClient(baseUrl: _baseUrl);

  /// Session gate: null = validating saved token, true = home, false = login.
  bool? _sessionValid;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  final _navigatorKey = GlobalKey<NavigatorState>();
  String? _lastDlUrl;
  DateTime? _lastDlAt;

  /// Deep-link flow logging (debugPrint only; not visible in release builds
  /// without adb/logcat).
  void _traceDl(String msg) {
    debugPrint('[deeplink] $msg');
  }

  void _wireApiAuth(ApiClient api) {
    api.authToken = AuthStore.instance.token;
    api.onAuthFailure = () => AuthStore.instance.expire();
  }

  void _onAuthChanged() async {
    // New login / logout / user switch: point the client at the new token
    // and swap to that user's prefetch index BEFORE the next paint, so a
    // stale cross-user liked cache never renders.
    _api.authToken = AuthStore.instance.token;
    await PrefetchStore.reloadForUserSwitch();
    if (!AuthStore.instance.loggedIn && mounted) {
      setState(() => _sessionValid = false);
    }
  }

  Future<void> _validateSession() async {
    _wireApiAuth(_api);
    final store = AuthStore.instance;
    if (!store.loggedIn) {
      if (mounted) setState(() => _sessionValid = false);
      return;
    }
    // Optimistic home: a stored login enters instantly (offline-capable)
    // instead of waiting out the me() timeout on a dead route — that wait
    // is the "loads forever" on cold-start-offline. Validation continues
    // in the background and only kicks to login on 401 (via onAuthFailure
    // + _onAuthChanged); a brief home flash for a dead token is the cost.
    if (mounted) setState(() => _sessionValid = true);
    _validateSessionBackground();
  }

  Future<void> _validateSessionBackground() async {
    // Fast offline notice (fresh probe, capped) — display only, gates on
    // nothing.
    try {
      if (await QueuePlayer.probeOffline()) {
        if (!mounted) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _messengerKey.currentContext;
          if (ctx != null) {
            toast(
              ctx,
              tr('Offline — server unreachable, showing downloads'),
              icon: Icons.wifi_off_outlined,
            );
          }
        });
      }
    } catch (_) {}
    // Bounded: at cold start the route (Tailscale/DNS) may not exist yet.
    String? u;
    try {
      u = await _api.me().timeout(const Duration(seconds: 10));
    } catch (_) {
      u = null;
    }
    if (!mounted) return;
    if (u != null) {
      _checkAnnouncements();
    }
    // else: offline (stay home, screens show Retry) or 401 (expire()
    // already kicked us to login via onAuthFailure + _onAuthChanged).
  }

  /// Last offline episode we already handled (reset when back online, so
  /// one dropout = one prompt, not a nag loop).
  bool _offlinePrompted = false;

  /// No route to the server: offer swapping the queue for phone downloads.
  /// Scope: this playlist's downloads when listening to X, else any.
  void _wireOfflinePopup() {
    QueuePlayer.instance.isOffline.addListener(() {
      final off = QueuePlayer.instance.isOffline.value;
      if (!off) {
        _offlinePrompted = false;
        return;
      }
      if (_offlinePrompted) return;
      _offlinePrompted = true;
      final qp = QueuePlayer.instance;
      if (qp.items.isEmpty) return;
      // Nothing to save when everything coming up is already on the phone.
      final upcoming = qp.items.skip(qp.index + 1);
      if (upcoming.isNotEmpty &&
          upcoming.every((it) => OfflineStore.isDownloaded(it.title))) {
        return;
      }
      final mode = OfflineStore.mode;
      if (mode == 'off') return;
      final pl = qp.fromPlaylist.value ? qp.playlistName : null;
      final mine = (pl != null && pl.isNotEmpty)
          ? OfflineStore.songsIn(pl)
          : <OfflineEntry>[];
      final any = OfflineStore.all();
      if (mode == 'mine') {
        if (mine.isNotEmpty) {
          _swapOfflineQueue(mine, pl);
        }
        return;
      }
      if (mode == 'any') {
        if (any.isNotEmpty) _swapOfflineQueue(any, null);
        return;
      }
      if (mine.isEmpty && any.isEmpty) return;
      if (_navigatorKey.currentState == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _navigatorKey.currentContext;
        if (ctx == null) return;
        showDialog<void>(
          context: ctx,
          builder: (dctx) => AlertDialog(
            title: Text(tr('No connection')),
            content: Text(
              "${tr('Replace the queue with songs from your phone?')}"
              '${pl != null && pl.isNotEmpty ? '\n${tr('Playlist')}: $pl (${mine.length})' : ''}'
              '\n${tr('All downloads')}: ${any.length}',
            ),
            actions: [
              if (mine.isNotEmpty)
                TextButton(
                  onPressed: () {
                    Navigator.pop(dctx);
                    _swapOfflineQueue(mine, pl);
                  },
                  child: Text("${tr('This playlist')} (${mine.length})"),
                ),
              if (any.isNotEmpty)
                TextButton(
                  onPressed: () {
                    Navigator.pop(dctx);
                    _swapOfflineQueue(any, null);
                  },
                  child: Text("${tr('Any')} (${any.length})"),
                ),
              TextButton(
                onPressed: () => Navigator.pop(dctx),
                child: Text(tr('Keep queue')),
              ),
            ],
          ),
        );
      });
    });
  }

  /// Replace the queue with shuffled phone downloads (all local playback).
  void _swapOfflineQueue(List<OfflineEntry> entries, String? playlist) {
    final items = entries
        .map((e) {
          final uri = OfflineStore.localUriFor(e.base);
          if (uri == null) return null;
          return QueueItem(e.base, uri, album: e.playlist);
        })
        .whereType<QueueItem>()
        .toList();
    if (items.isEmpty) return;
    items.shuffle();
    QueuePlayer.instance.playList(
      items,
      playFromPlaylist: playlist != null && playlist.isNotEmpty,
      playlistName: playlist,
    );
  }

  /// Last replace job we already popped a completion dialog for (jobs are
  /// identified by start time; never nag twice for the same one).
  DateTime? _replacePopupShownFor;

  /// Pops a completion dialog when a check-songs replacement finishes
  /// downloading + swapping — wherever the user is in the app.
  void _wireReplacePopup() {
    ReplaceTracker.active.addListener(() {
      final rs = ReplaceTracker.active.value;
      if (rs == null || !rs.done) return;
      if (_replacePopupShownFor == rs.startedAt) return;
      _replacePopupShownFor = rs.startedAt;
      if (_navigatorKey.currentState == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _navigatorKey.currentContext;
        if (ctx == null) return;
        showDialog<void>(
          context: ctx,
          builder: (dctx) => AlertDialog(
            title: Text(
              rs.success
                  ? tr('Replacement finished')
                  : tr('Replacement failed'),
            ),
            content: Text(
              '"${rs.baseName}"\n'
              '${rs.detail.isNotEmpty ? rs.detail : (rs.success ? tr('The new audio is in place.') : tr('The old copy was kept.'))}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dctx),
                child: Text(tr('OK')),
              ),
            ],
          ),
        );
      });
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Tag every API + image request with the running build so the server
    // log shows which version each phone runs (version-confusion triage).
    PackageInfo.fromPlatform()
        .then((pi) {
          _api.appVersion = pi.version;
          DebugInfo.appVersion = pi.version;
        })
        .catchError((_) {});
    QueuePlayer.instance.lastError.addListener(_onPlayError);
    _wireAutoplay(_api);
    QueuePlayer.instance.loadAutoplay();
    _wireApiAuth(_api);
    // Reachable-base: cached choice instantly, tailnet preferred, funnel
    // fallback — re-checks on network change (queue_player) / ping fail.
    _api.selectBestBase();
    AuthStore.instance.addListener(_onAuthChanged);
    _validateSession();
    _wireAudioStateBridge();
    _wireDeepLinks();
    _wireReplacePopup();
    _wireOfflinePopup();
    _wireAnnouncements();
  }

  /// Published events (Wrapped season + cards): check on start, on resume,
  /// and after session validation. Tap routes to Wrapped.
  void _wireAnnouncements() {
    DateTime lastOpen = DateTime.fromMillisecondsSinceEpoch(0);
    void openWrapped() {
      // Dedupe rapid double-taps; never push over the login screen.
      if (DateTime.now().difference(lastOpen).inSeconds < 2) return;
      if (!AuthStore.instance.loggedIn) return;
      lastOpen = DateTime.now();
      final nav = _navigatorKey.currentState;
      if (nav != null) {
        nav.push(MaterialPageRoute(builder: (_) => WrappedScreen(api: _api)));
      }
    }

    Announcer.onOpenWrapped = openWrapped;
    Announcer.onOpenLink = (url) async {
      try {
        final uri = Uri.parse(url);
        if (uri.scheme != 'http' && uri.scheme != 'https') return;
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    };
    Announcer.init();
  }

  void _checkAnnouncements() {
    if (AuthStore.instance.loggedIn) {
      Announcer.check(_api).then((_) {
        final p = Announcer.pendingPayload;
        if (p == null || p.isEmpty) return;
        Announcer.pendingPayload = null;
        if (p == 'wrapped') {
          Announcer.onOpenWrapped?.call();
        } else if (p.startsWith('link:')) {
          Announcer.onOpenLink?.call(p.substring(5));
        }
      });
    }
  }

  /// Shared Spotify / YT-Music links opened with this app: pull the cold-start
  /// URL once (MainActivity queues it until Flutter's first query), then
  /// receive warm links whenever onNewIntent fires. Each one opens the song
  /// like a tapped discovery row.
  Future<void> _wireDeepLinks() async {
    _traceDl('BUILD=V41');
    String? initial;
    try {
      initial = await _kDeepLinkChannel.invokeMethod<String>('getInitialLink');
    } catch (e) {
      _traceDl('getInitialLink threw: $e');
      // No native side (desktop) — deep links are Android-only.
    }
    _traceDl('getInitialLink -> ${initial ?? 'null'}');
    final initialUrl = initial;
    if (initialUrl != null && initialUrl.isNotEmpty) {
      // Cold start: the navigator (and with it every toast + route push) only
      // exists AFTER the first frame — running _openDeepLink now would
      // silently drop its feedback and skip the NowPlayingRoute push. Defer
      // to post-frame so the song actually appears and errors are visible.
      debugPrint('[deeplink] cold-start initial: $initialUrl');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openDeepLink(initialUrl);
      });
    } else {
      _traceDl('no initial link (cold start had none — ok if warm start)');
    }
    try {
      _kDeepLinkChannel.setMethodCallHandler((call) async {
        if (call.method == 'openUrl') {
          final url = call.arguments?.toString();
          _traceDl('openUrl event -> $url');
          if (url != null && url.isNotEmpty) {
            _openDeepLink(url).catchError((Object e) {
              _traceDl('UNHANDLED (openUrl event): $e');
            });
          }
        }
      });
    } catch (e) {
      _traceDl('setMethodCallHandler threw: $e');
      // ignore: same as above.
    }
    _traceDl('deep-link handler registered');
  }

  /// Visible on-screen toast used in release builds where debugPrint cannot
  /// be read without adb. No-op while the navigator isn't built yet.
  void _dlToast(String msg) {
    _traceDl(msg);
    final nav = _navigatorKey.currentState;
    final ov = nav?.overlay;
    if (ov != null) toastInOverlay(ov, msg);
  }

  Future<void> _openDeepLink(String rawUrl) async {
    _traceDl('openDeepLink: $rawUrl');
    // WhatsApp tacks on ?si=…/utm_source=… — strip before dedup + classify
    // so a re-tap of the same song with different tracking still dedups
    // and the server sees the canonical link.
    rawUrl = stripTrackingParams(rawUrl);
    // Cold start + warm openUrl can deliver the same URL twice (native
    // flush + getInitialLink raced before the MainActivity fix; belt and
    // braces against any future double delivery): play once.
    final now = DateTime.now();
    if (isDuplicateDeepLink(_lastDlUrl, _lastDlAt, rawUrl, now)) {
      _traceDl('duplicate deep link ignored');
      return;
    }
    _lastDlUrl = rawUrl;
    _lastDlAt = now;
    final url = Uri.tryParse(rawUrl);
    if (url == null) {
      _traceDl('URI parse FAILED');
      _dlToast("Deep link unparseable: $rawUrl");
      return;
    }
    final kind = classifyDeepLink(rawUrl);
    final host = (url.host.isNotEmpty ? url.host : url.path).toLowerCase();
    final isSpotify = kind == DeepLinkKind.spotify;
    final isYt = kind == DeepLinkKind.youtube;
    _traceDl('host=$host isSpotify=$isSpotify isYt=$isYt');
    if (!isSpotify && !isYt) {
      _dlToast("Not a music share link ($host)");
      return;
    }
    _traceDl('openUrl BEFORE');
    final ov = _navigatorKey.currentState?.overlay;
    if (ov != null) {
      try {
        toastInOverlay(ov, "${tr('Opening shared song')} ($host)…");
      } catch (e) {
        // The toast is decoration — a throw here must NOT kill the flow.
        _traceDl('toast threw (ignored): $e');
      }
    }
    try {
      final info = await _api
          .openUrl(rawUrl)
          .timeout(const Duration(seconds: 12));
      _traceDl(
        'openUrl AFTER: kind=${info.kind} videoId=${info.videoId} '
        'artist=${info.artist} title=${info.title}',
      );
      final qp = QueuePlayer.instance;
      QueueItem? item;
      if (info.kind == 'youtube' && info.videoId.isNotEmpty) {
        // Instant: relay URL plays now; NAS exact-match upgrades inside
        // the engine. No resolve await before first audio.
        qp.wireTapResolvers(_api);
        item = QueueItem(
          info.title.isNotEmpty
              ? '${info.artist.isNotEmpty ? '${info.artist} - ' : ''}${info.title}'
              : 'YouTube Music',
          _api.relayUrl(info.videoId),
          thumbUrl: _api.thumbUrl(info.videoId),
          videoId: info.videoId,
          fromInternet: true,
          album: info.album,
          lyricsArtist: info.artist,
          lyricsTitle: info.title,
        );
      } else // The server returns 'unknown' for Spotify search links (/search/...),
      // only 'spotify' for actual /track/ links. Handle both.
      if (info.kind == 'spotify' &&
          (info.artist.isNotEmpty && info.title.isNotEmpty)) {
        // NAS-first, mirroring the tap-to-play flow for discovery rows.
        // Instant placeholder: the engine resolves NAS-first bounded,
        // then streams. No inNas/resolve await before first audio.
        qp.wireTapResolvers(_api);
        // Carry Spotify art (open-url image, Deezer fallback server-side):
        // without this the queue item has null art -> CoverArt gradient.
        final dlArt = info.image.isNotEmpty
            ? _api.imageProxy(info.image)
            : null;
        item = QueueItem(
          '${info.artist} - ${info.title}',
          '',
          resolveName: (artist: info.artist, title: info.title),
          fromInternet: true,
          lyricsArtist: info.artist,
          lyricsTitle: info.title,
          thumbUrl: dlArt,
          album: info.album,
          albumImage: dlArt,
        );
      } else if (isSpotify &&
          'search' ==
              (url.pathSegments.isNotEmpty
                  ? url.pathSegments.first
                  : 'search') &&
          url.pathSegments.contains('search')) {
        // Spotify search link (/search/<q>): extract the query and resolve by
        // name — same NAS-first flow as a real track link.
        final segs = url.pathSegments;
        var q = Uri.decodeQueryComponent(
          segs.isNotEmpty && segs.last != 'search' ? segs.last : '',
        );
        if (q.isEmpty) q = url.queryParameters['q'] ?? '';
        if (q.isNotEmpty) {
          qp.wireTapResolvers(_api);
          item = QueueItem(
            q,
            '',
            resolveName: (artist: '', title: q),
            fromInternet: true,
            lyricsTitle: q,
          );
        }
      }
      if (item == null) {
        _traceDl('item == null');
        final ov2 = _navigatorKey.currentState?.overlay;
        if (ov2 != null) toastInOverlay(ov2, tr("Can't play that link"));
        return;
      }
      // Navigate FIRST, start audio SECOND. If playOne hangs or fails, the
      // user still sees the song screen (and the error toast) instead of the
      // deep link doing "nothing".
      _traceDl('now playing: ${item.url}');
      final nav = _navigatorKey.currentState;
      if (nav != null) {
        nav.push(NowPlayingRoute());
        _traceDl('NowPlaying pushed');
      } else {
        _traceDl('push skipped (nav null)');
      }
      await qp.playOne(item).timeout(const Duration(seconds: 20));
      _traceDl('playOne done');
    } on TimeoutException {
      _traceDl('TIMEOUT: openUrl hang');
      final ov3 = _navigatorKey.currentState?.overlay;
      if (ov3 != null)
        toastInOverlay(ov3, tr('Slow/broken server link — timeout'));
    } on ApiException catch (e) {
      _traceDl('APIERROR: ${e.statusCode} ${e.message}');
      final ov4 = _navigatorKey.currentState?.overlay;
      if (ov4 != null)
        toastInOverlay(ov4, "${tr('Server rejected that link')}: ${e.message}");
    } catch (e) {
      _traceDl('ERROR: $e');
      final ov5 = _navigatorKey.currentState?.overlay;
      if (ov5 != null) toastInOverlay(ov5, "${tr('Playback failed')}: $e");
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AuthStore.instance.removeListener(_onAuthChanged);
    QueuePlayer.instance.lastError.removeListener(_onPlayError);
    _unwrapAudioStateBridge();
    super.dispose();
  }

  /// Y: when the app is fully detached (swiped from recents on Android),
  /// stop playback and kill the foreground service so the notification is
  /// dismissed.
  AppLifecycleState? _lastLifecycle;
  Timer? _pauseStopTimer;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lastLifecycle = state;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      // Paused bg: no fg-service needed. Empty queue stops now; otherwise
      // stop after 10min still-paused so a forgotten pause can't wakelock.
      final qp0 = QueuePlayer.instance;
      // Pause-then-kill loses the open Wrapped entry (detached rarely
      // fires on Android): bank it now. Skip while playing — the handler
      // is alive and the completion path seals the full track later.
      if (!qp0.playing) {
        PlayLog.flush(qp0.currentTitle.value, qp0.position.value.inSeconds);
      }
      if (qp0.items.isEmpty && !qp0.playing) {
        if (!kIsWeb) AudioService.stop();
      } else {
        _pauseStopTimer?.cancel();
        _pauseStopTimer = Timer(const Duration(minutes: 10), () {
          final qp = QueuePlayer.instance;
          if (!qp.playing) {
            try {
              if (!kIsWeb) AudioService.stop();
            } catch (_) {}
          }
        });
      }
    }
    if (state == AppLifecycleState.detached) {
      // Seal the open Wrapped entry: the process may die with it.
      PlayLog.flush(
        QueuePlayer.instance.currentTitle.value,
        QueuePlayer.instance.position.value.inSeconds,
      );
      QueuePlayer.instance.stop();
      if (!kIsWeb) AudioService.stop();
    } else if (state == AppLifecycleState.resumed) {
      _pauseStopTimer?.cancel();
      _api.flushQueuedLogs();
      _checkAnnouncements();
      // Backgrounded with no music: the OS may have killed the audio
      // service while the UI survived. If there is something to control
      // (playing or queued) but the handler isolate is gone (its port
      // missing — positive evidence, not a guess), bring the service
      // back — otherwise taps play locally with no notification, until
      // a restart. NOTE: never read AudioService.running here — that
      // getter is broken (audio_session_state.dart: throws a ValueStream
      // cast on every read), which crashed this observer on EVERY resume
      // and could abort lifecycle delivery for later observers.
      final qp = QueuePlayer.instance;
      if (audioSessionReady.value &&
          (qp.playing || qp.items.isNotEmpty) &&
          IsolateNameServer.lookupPortByName(kAudioStatePort) == null) {
        _initAudioService();
      }
      // The UI isolate may have slept while the handler kept playing (or
      // noisy/focus paused it): re-query handler truth (state/pos/dur) via
      // the existing bridge into RemoteEngine.feedRemoteEvent to correct
      // stale _lastState (frozen play icon), and re-push metadata so a
      // restarted handler recovers _hasMedia/title instead of dropping play.
      qp.onResumed();
      _pushAudioState();
    }
  }

  /// Push the current song + playback state to the lock-screen / notification
  /// media session whenever anything changes, and on an interval so the seek
  /// bar stays live.
  void _wireAudioStateBridge() {
    final qp = QueuePlayer.instance;
    qp.currentTitle.addListener(_pushAudioState);
    qp.currentThumb.addListener(_pushAudioState);
    qp.loading.addListener(_pushAudioState);
    // 1s fg while playing (live seek bar); bg pushes NOTHING periodic —
    // metadata can't change without a track-change push (the listeners
    // above fire regardless of lifecycle), so a bg re-push is pure
    // isolate traffic + a needless art check every few seconds.
    _audioTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!qp.playing) return;
      if (_lastLifecycle != null &&
          _lastLifecycle != AppLifecycleState.resumed) {
        return;
      }
      _pushAudioState();
    });
    _pushAudioState();
  }

  void _unwrapAudioStateBridge() {
    final qp = QueuePlayer.instance;
    qp.currentTitle.removeListener(_pushAudioState);
    qp.currentThumb.removeListener(_pushAudioState);
    qp.loading.removeListener(_pushAudioState);
    _audioTimer?.cancel();
    _audioTimer = null;
  }

  Timer? _audioTimer;

  /// Spotify/YT-Music autoplay: fills the queue with related internet tracks
  /// ("from internet") behind the current NAS song. Re-pointed at the live
  /// [api] so server-address changes keep working.
  void _wireAutoplay(ApiClient api) {
    QueuePlayer.instance.resolver = api.resolve;
    QueuePlayer.instance.warm = api.warm;
    QueuePlayer.instance.wireTapResolvers(api);
    QueuePlayer
        .instance
        .relatedSource = (current, {int? limit, List<String>? excludeTitles}) async {
      // Prefer the resolved lyrics identity (set on internet rows), then the
      // 'Artist - Title' display string, then the bare title as a last
      // resort — never refuse to query just because the separator is missing
      // (playlist/offline rows can be bare filenames).
      var artist = (current.lyricsArtist ?? '').trim();
      var title0 = (current.lyricsTitle ?? '').trim();
      if (artist.isEmpty || title0.isEmpty) {
        final split = current.title.indexOf(' - ');
        if (split > 0) {
          artist = current.title.substring(0, split).trim();
          title0 = current.title.substring(split + 3).trim();
        } else {
          artist = '';
          title0 = current.title.trim();
        }
      }
      title0 = title0
          .replaceAll(
            RegExp(
              r'\.(?:mp3|flac|m4a|ogg|opus|wav|aac|wma)$',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      if (title0.isEmpty) {
        debugPrint(
          '[autoplay] relatedSource: empty title for "${current.title}"',
        );
        return <QueueItem>[];
      }
      // Try recommend first (Spotify-style cross-artist), fall back to radio (same-artist)
      List<Suggestion> rows;
      try {
        rows = await api.recommend(
          artist,
          title0,
          limit: limit,
          exclude: excludeTitles,
        );
      } catch (e) {
        debugPrint('[autoplay] recommend failed, falling back to radio: $e');
        rows = [];
      }
      if (rows.isEmpty) {
        try {
          rows = await api.radio(
            artist,
            title0,
            limit: limit,
            exclude: excludeTitles,
          );
        } catch (e) {
          debugPrint('[autoplay] radio also failed: $e');
          rows = [];
        }
      }
      if (rows.isEmpty) {
        final seedLabel = artist.isEmpty ? title0 : '$artist - $title0';
        debugPrint(
          '[autoplay] both recommend and radio returned empty for "$seedLabel"',
        );
      }
      Future<QueueItem?> resolveOne(Suggestion s) async {
        try {
          // If track is on NAS, play local file directly (no internet resolution needed).
          // Server annotates recommend/radio rows with in_nas/nas_url.
          final inNas = s.inNas;
          final nasUrl = s.nasUrl;
          if (inNas && (nasUrl?.isNotEmpty ?? false)) {
            return QueueItem(
              '${s.artist} - ${s.title}',
              api.fileUrl(nasUrl!),
              thumbUrl: (s.albumImage?.isNotEmpty ?? false)
                  ? s.albumImage
                  : null,
              album: s.album,
              fromInternet: false,
            );
          }
          // Fallback: query /api/innas if annotation missing (older server).
          final nas = await api.inNas(
            artist: s.artist ?? '',
            title: s.title ?? '',
          );
          if (nas.found && (nas.url?.isNotEmpty ?? false)) {
            return QueueItem(
              '${s.artist} - ${s.title}',
              api.fileUrl(nas.url!),
              thumbUrl: (nas.albumImage?.isNotEmpty ?? false)
                  ? nas.albumImage
                  : null,
              album: nas.album,
              fromInternet: false,
            );
          }
          // Not on NAS: resolve via internet (YouTube Music).
          final r = await api.resolveByName(
            artist: s.artist ?? '',
            title: s.title ?? '',
          );
          final thumb = r.thumb.isNotEmpty
              ? api.thumbUrl(r.videoId)
              : s.albumImage;
          return QueueItem(
            '${s.artist} - ${s.title}',
            r.url,
            thumbUrl: thumb,
            videoId: r.videoId,
            album: (r.album?.isNotEmpty ?? false)
                ? r.album
                : ((s.album?.isNotEmpty ?? false) ? s.album : null),
            albumImage: s.albumImage,
            fromInternet: true,
            lyricsArtist: r.resolvedArtist ?? s.artist,
            lyricsTitle: r.resolvedTitle ?? s.title,
          );
        } catch (_) {
          return null;
        }
      }

      // Bounded parallelism: resolving ALL rows at once opens dozens of
      // concurrent chains (inNas + up-to-24s resolveByName polling each),
      // starving the live stream + covers on the shared pipe while the
      // tapped song is trying to start. Four workers drain the same rows
      // with the same results (planner randomizes downstream anyway).
      var nextRow = 0;
      final resolved = <QueueItem?>[];
      Future<void> worker() async {
        while (true) {
          if (nextRow >= rows.length) return;
          final s = rows[nextRow++];
          try {
            resolved.add(await resolveOne(s));
          } catch (_) {
            resolved.add(null);
          }
        }
      }

      await Future.wait(List.generate(4, (_) => worker()));
      return resolved.whereType<QueueItem>().toList();
    };
  }

  void _onPlayError() {
    final e = QueuePlayer.instance.lastError.value;
    final ctx = _messengerKey.currentContext;
    if (e == null || ctx == null) return;
    toast(ctx, "${tr('Playback failed')}: $e", icon: Icons.error_outline);
    // Terminal give-ups go to the server log (transient healable errors
    // would just spam it — those resolve on their own).
    if (QueuePlayer.instance.gaveUp) {
      final t = QueuePlayer.instance.currentTitle.value;
      _api.logClientError('playback-gave-up', '$t — $e');
    }
  }

  /// Normalize a user-typed server address: trim, drop trailing slashes
  /// and a trailing `/staging` (ApiClient appends `/staging` itself —
  /// pasting the full public URL used to produce `/staging/staging/...`).
  String _normalizeServer(String v) {
    var s = v.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.toLowerCase().endsWith('/staging')) {
      s = s.substring(0, s.length - '/staging'.length);
    }
    return s;
  }

  Future<String?> _changeServer() async {
    final controller = TextEditingController(text: _baseUrl);
    String status = '';
    bool testing = false;
    // NOTE: never showDialog() with this State's own context — it sits
    // ABOVE MaterialApp, so no Navigator exists there and the dialog
    // silently never opens (the "clicking does nothing" bug).
    final navCtx = _navigatorKey.currentContext;
    if (navCtx == null) return null;
    final result = await showDialog<String>(
      context: navCtx,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(tr('Server address')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: 'https://naboo.taildfeb4f.ts.net',
                ),
                onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
              ),
              const SizedBox(height: 8),
              const Text(
                'Public (no Tailscale): https://naboo.taildfeb4f.ts.net\n'
                'At home (Tailscale): http://music.rg.nig:8004',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
              if (status.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(status, style: const TextStyle(fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: testing ? null : () => Navigator.pop(ctx),
              child: Text(tr('Cancel')),
            ),
            TextButton(
              onPressed: testing
                  ? null
                  : () async {
                      setDlg(() {
                        testing = true;
                        status = tr('Testing…');
                      });
                      final ok = await _testServer(
                        _normalizeServer(controller.text.trim()),
                      );
                      setDlg(() {
                        testing = false;
                        status = ok
                            ? tr('Reachable — Save to switch.')
                            : tr('Unreachable — check the address/network.');
                      });
                    },
              child: Text(tr('Test')),
            ),
            FilledButton(
              onPressed: testing
                  ? null
                  : () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(tr('Save')),
            ),
          ],
        ),
      ),
    );
    if (result == null || result.isEmpty) return null;
    final normalized = _normalizeServer(result);
    if (normalized == _baseUrl) return null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kServerKey, normalized);
    setState(() {
      _baseUrl = normalized;
      _api = ApiClient(baseUrl: normalized);
    });
    _api.pinBase(normalized);
    PackageInfo.fromPlatform()
        .then((pi) {
          _api.appVersion = pi.version;
          DebugInfo.appVersion = pi.version;
        })
        .catchError((_) {});
    _wireApiAuth(_api);
    _wireAutoplay(_api);
    // A new server means the saved token may not exist there — re-gate.
    setState(() => _sessionValid = null);
    _validateSession();
    // Pop back to home: already-open routes hold the OLD ApiClient object.
    _navigatorKey.currentState?.popUntil((r) => r.isFirst);
    return result;
  }

  /// Reachability probe: any HTTP answer (even 401) means the server is
  /// there; timeout/exception means it isn't.
  Future<bool> _testServer(String base) async {
    if (base.isEmpty) return false;
    try {
      final r = await http
          .get(Uri.parse('$base/staging/api/me'))
          .timeout(const Duration(seconds: 8));
      return r.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ServerContext(
      api: _api,
      child: ListenableBuilder(
        listenable: Listenable.merge([
          ThemeStore.instance,
          LocaleStore.instance,
          AuthStore.instance,
        ]),
        builder: (context, _) => MaterialApp(
          title: 'gungan.fm',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: _messengerKey,
          navigatorKey: _navigatorKey,
          // Re-key per theme so every static Spots.* widget above MaterialApp
          // (plus the whole tree) rebuilds when the preset changes.
          key: ValueKey(ThemeStore.instance.current.id),
          theme: Spots.dark(),
          builder: (context, child) => DebugOverlay(child: child, api: _api),
          home: !AuthStore.instance.loggedIn
              ? LoginScreen(
                  api: _api,
                  onDone: () {
                    if (!mounted) return;
                    setState(() => _sessionValid = true);
                  },
                )
              : _sessionValid == null
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : _sessionValid!
              ? _HomeShell(
                  api: _api,
                  baseUrl: _baseUrl,
                  onServer: _changeServer,
                )
              : LoginScreen(
                  api: _api,
                  onDone: () {
                    if (!mounted) return;
                    setState(() => _sessionValid = true);
                  },
                ),
        ),
      ),
    );
  }
}

class _HomeShell extends StatefulWidget {
  const _HomeShell({
    required this.api,
    required this.baseUrl,
    required this.onServer,
  });
  final ApiClient api;
  final String baseUrl;
  final Future<String?> Function() onServer;

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Keyboard overlays instead of squishing the tab shell; scrollable
      // tabs pad with viewInsets themselves.
      resizeToAvoidBottomInset: false,
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                LibraryScreen(api: widget.api, onServer: widget.onServer),
                HomeTab(api: widget.api, onServer: widget.onServer),
                StagingScreen(api: widget.api, onServer: widget.onServer),
                ListenHistoryScreen(api: widget.api, visible: _tab == 3),
              ],
            ),
          ),
          // Single bottom inset: the SafeArea around the nav bar below owns the
          // system gesture inset. Strip it above so MiniPlayerBar's own
          // MediaQuery.paddingOf margin doesn't consume it a second time.
          MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: const MiniPlayerBar(),
          ),
          // Slim, centered bottom tab bar (Material NavigationBar enforces a ~80px
          // minimum height, so it ignored `height: 56`; a custom bar gives us the
          // compact centered look the user asked for). Wrapped in SafeArea so it
          // clears the gesture bar on Android / desktop nothing extra. Its look
          // follows UiStore.navStyle: solid / pill / glass.
          SafeArea(
            top: false,
            child: ListenableBuilder(
              listenable: UiStore.instance,
              builder: (context, _) {
                final style = UiStore.instance.navStyle;
                final row = Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _bottomTab(
                      0,
                      Icons.library_music_outlined,
                      Icons.library_music,
                      tr('Library'),
                    ),
                    _bottomTab(1, Icons.search, Icons.search, tr('Search')),
                    _bottomTab(
                      2,
                      Icons.download_outlined,
                      Icons.download,
                      tr('Downloads'),
                    ),
                    _bottomTab(3, Icons.history, Icons.history, tr('History')),
                  ],
                );
                switch (style) {
                  case 'pill':
                    return Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        margin: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Spots.elevated,
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: const [
                            BoxShadow(color: Colors.black38, blurRadius: 12),
                          ],
                        ),
                        child: row,
                      ),
                    );
                  case 'glass':
                    // Translucent frosted bar (no BackdropFilter: unframed in a
                    // Column it blurs the whole screen / breaks rendering on
                    // Android). Semi-transparent elevated + a hairline top edge
                    // gives the glass look without the blur breakdown.
                    return Container(
                      decoration: BoxDecoration(
                        color: Spots.elevated.withValues(alpha: 0.55),
                        border: const Border(
                          top: BorderSide(color: Colors.white10),
                        ),
                      ),
                      child: row,
                    );
                  default: // solid
                    return Container(color: Spots.elevated, child: row);
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomTab(int i, IconData icon, IconData sel, String label) {
    final active = _tab == i;
    return InkWell(
      onTap: () => setState(() => _tab = i),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? sel : icon,
              size: 22,
              color: active ? Spots.green : Colors.white54,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active ? Spots.green : Colors.white54,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Search tab (separate Scaffold so the search field sits under its AppBar).
class HomeTab extends StatelessWidget {
  const HomeTab({super.key, required this.api, required this.onServer});
  final ApiClient api;
  final Future<String?> Function() onServer;

  @override
  Widget build(BuildContext context) {
    // Throttled inside (announcer pattern): refreshes the gear red dot.
    ErrorDot.refresh(api);
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Text(tr('Search')),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: tr('Settings'),
            onPressed: () =>
                openSettings(context, api: api, onServer: onServer),
          ),
        ],
      ),
      body: SearchScreen(api: api),
    );
  }
}
