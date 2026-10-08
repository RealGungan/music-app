import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'demo_wrapped.dart';
import 'diag_log.dart';
import 'wrapped.dart';

/// True when [server] (dotted, e.g. "1.0.74") is newer than [installed].
/// Non-numeric tails ignored; missing parts count as 0.
bool isServerNewer(String server, String installed) {
  List<int> parts(String v) => v
      .split('.')
      .map((p) => int.tryParse(RegExp(r'\d+').firstMatch(p)?.group(0) ?? '') ?? 0)
      .toList();
  final a = parts(server), b = parts(installed);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// Published events from the server (/api/announcements): the Wrapped
/// season flag + notification cards. Each item notifies once per device
/// (seen ids in prefs); tap routes to Wrapped via [onOpenWrapped].
class Announcer {
  Announcer._();
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static void Function()? onOpenWrapped;
  static void Function(String url)? onOpenLink;
  static bool _ready = false;
  static bool wrappedSeason = false;

  /// Bumped whenever check() finishes (season flag may have flipped).
  static final ValueNotifier<int> change = ValueNotifier(0);
  static DateTime _lastCheck = DateTime.fromMillisecondsSinceEpoch(0);
  static bool _checking = false;
  static String? pendingPayload;

  static const AndroidNotificationChannel _channel =
      AndroidNotificationChannel(
    'gunganfm_events',
    'Events',
    description: 'Wrapped season and announcements',
    importance: Importance.high,
  );

  static Future<void> init() async {
    if (_ready) return;
    try {
      DiagLog.restart.log('announce: init start');
      const android = AndroidInitializationSettings('@drawable/ic_stat_music');
      const darwin = DarwinInitializationSettings();
      await _plugin.initialize(
        const InitializationSettings(
            android: android, iOS: darwin, macOS: darwin),
      onDidReceiveNotificationResponse: (resp) {
        final p = resp.payload ?? '';
        if (p == 'wrapped') {
          onOpenWrapped?.call();
        } else if (p.startsWith('link:')) {
          onOpenLink?.call(p.substring(5));
        }
      },
      ).timeout(const Duration(seconds: 10));
      DiagLog.restart.log('announce: plugin ready');
      try {
        await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(_channel)
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    // Cold-start tap (app was dead): replay into the pending slot for
    // main to consume after login (wrapped opens Wrapped, links open).
    try {
      final launch = await _plugin
          .getNotificationAppLaunchDetails()
          .timeout(const Duration(seconds: 5));
      final p = launch?.notificationResponse?.payload ?? '';
      if ((launch?.didNotificationLaunchApp ?? false) &&
          (p == 'wrapped' || p.startsWith('link:'))) {
        pendingPayload = p;
      }
    } catch (_) {}
      _ready = true;
      DiagLog.restart.log('announce: init done');
    } catch (e) {
      DiagLog.restart.log('announce INIT FAILED: ${e.runtimeType}');
    }
  }

  /// Fetch + notify once per item. Silent on any failure (never blocks
  /// startup). Call when logged in, on start and on resume (throttled).
  static Future<void> check(ApiClient api) async {
    if (_checking ||
        DateTime.now().difference(_lastCheck) <
            const Duration(minutes: 5)) {
      return;
    }
    _checking = true;
    DiagLog.restart.log('announce: check start');
    try {
      await init();
      final a = await api.announcements();
      wrappedSeason = a['wrapped_season'] == true;
      change.value++;
      DiagLog.restart.log(
          'announce: season=$wrappedSeason items=${(a['items'] as List? ?? []).length}');
      final prefs = await SharedPreferences.getInstance();
      await _checkAppUpdate(a, api, prefs);
      final items = (a['items'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      if (items.isEmpty) return;
      // First check on a fresh install: baseline everything silently.
      // Otherwise every ever-published card pings at once on install.
      if (!(prefs.getBool('announcer.baselined') ?? false)) {
        await prefs.setStringList(
            'announcer.seen',
            items
                .map((it) => (it['id'] ?? '').toString())
                .where((id) => id.isNotEmpty)
                .toList());
        await prefs.setBool('announcer.baselined', true);
        DiagLog.restart.log(
            'announce: baselined ${items.length} existing cards');
        return;
      }
      final seen =
          (prefs.getStringList('announcer.seen') ?? []).toSet();
      // Prune ids the server no longer publishes.
      seen.retainWhere((id) =>
          items.any((it) => (it['id'] ?? '').toString() == id));
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        final id = (it['id'] ?? '').toString();
        if (id.isEmpty || seen.contains(id)) continue;
        final url = (it['url'] ?? '').toString();
        final payload = url.isNotEmpty
            ? 'link:$url'
            : (id.startsWith('wrapped') ? 'wrapped' : null);
        await _plugin.show(
          1000 + i,
          (it['title'] ?? 'gungan.fm').toString(),
          (it['body'] ?? '').toString(),
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'gunganfm_events',
              'Events',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
          payload: payload,
        );
        seen.add(id);
        DiagLog.restart.log('announce: notified $id');
      }
      await prefs.setStringList('announcer.seen', seen.toList());
    } catch (e) {
      DiagLog.restart.log('announce FAILED: ${e.runtimeType} $e');
      // announcements must never break startup
    } finally {
      _lastCheck = DateTime.now();
      _checking = false;
    }
  }

  /// Developer preview: fire a Wrapped notification with sample stats
  /// (demo data, no server needed). Tap routes to Wrapped via payload.
  static Future<void> testWrapped() async {
    await init();
    try {
      final s =
          WrappedStats.compute(demoEvents(), year: DateTime.now().year);
      final top =
          s.topArtists.isNotEmpty ? s.topArtists.first.name : '—';
      await _plugin.show(
        1977,
        'Wrapped (test)',
        '${s.totalStreams} streams · Top: $top',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'gunganfm_events',
            'Events',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: 'wrapped',
      );
      DiagLog.restart.log('announce: test wrapped fired');
    } catch (e) {
      DiagLog.restart.log('announce TEST FAILED: ${e.runtimeType}');
    }
  }

  /// Automatic update notice: when the server reports a newer app_version
  /// (and the owner hasn't killed auto-updates), notify once per version
  /// with a tap-to-download link. Silent on any failure.
  static Future<void> _checkAppUpdate(Map<String, dynamic> a, ApiClient api,
      SharedPreferences prefs) async {
    try {
      if (a['app_updates'] == false) return;
      final v = (a['app_version'] ?? '').toString().trim();
      if (v.isEmpty) return;
      // A manual "Send update" card covers this version: don't double-ping.
      final apk = api.apkUrl;
      final items = (a['items'] as List? ?? [])
          .whereType<Map<String, dynamic>>();
      if (items.any((it) => (it['url'] ?? '').toString() == apk)) return;
      if (prefs.getString('announcer.seen_update') == v) return;
      final installed = (await PackageInfo.fromPlatform()).version;
      if (!isServerNewer(v, installed)) return;
      await _plugin.show(
        999,
        'Update available',
        'gungan.fm $v is ready — tap to download.',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'gunganfm_events',
            'Events',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: 'link:${api.apkUrl}',
      );
      await prefs.setString('announcer.seen_update', v);
      DiagLog.restart.log('announce: update notice $installed -> $v');
    } catch (e) {
      DiagLog.restart.log('announce update FAILED: ${e.runtimeType}');
    }
  }
}
