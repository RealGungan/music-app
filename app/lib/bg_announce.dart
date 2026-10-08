import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'announcer.dart' show isServerNewer;
import 'api_client.dart';

/// Periodic background announcements check (Android WorkManager).
/// Runs in its own isolate with the app dead / screen off: polls
/// /api/announcements and notifies for new cards + app updates.
/// Same prefs keys + notification ids as the foreground Announcer so the
/// two never double-ping (seen ids / seen_update shared).
/// Cadence is inexact under Doze (~15-30min) — no FCM infra needed.
const bgAnnounceTask = 'gunganfm-announce-check';

@pragma('vm:entry-point')
void bgAnnounceDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final base = prefs.getString('server_base_url') ?? '';
      final tok = prefs.getString('auth.session_token') ?? '';
      final installed = prefs.getString('installed.version') ?? '';
      if (base.isEmpty || tok.isEmpty) return true;
      final api = ApiClient(baseUrl: base)..authToken = tok;
      final a = await api.announcements().timeout(
            const Duration(seconds: 25),
          );

      final plugin = FlutterLocalNotificationsPlugin();
      const android =
          AndroidInitializationSettings('@drawable/ic_stat_music');
      await plugin.initialize(
        const InitializationSettings(android: android),
      );
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'gunganfm_events',
          'Events',
          importance: Importance.high,
          priority: Priority.high,
        ),
      );

      // App-update notice (same once-per-version rule as foreground).
      if (a['app_updates'] != false) {
        final v = (a['app_version'] ?? '').toString().trim();
        if (v.isNotEmpty &&
            installed.isNotEmpty &&
            isServerNewer(v, installed) &&
            prefs.getString('announcer.seen_update') != v) {
          await plugin.show(
            999,
            'Update available',
            'gungan.fm $v is ready — tap to download.',
            details,
            payload: 'link:${api.apkUrl}',
          );
          await prefs.setString('announcer.seen_update', v);
        }
      }

      // Broadcast cards (same once-per-id rule as foreground).
      final items = (a['items'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      // Fresh install: baseline silently (see Announcer.check).
      if (!(prefs.getBool('announcer.baselined') ?? false)) {
        await prefs.setStringList(
            'announcer.seen',
            items
                .map((it) => (it['id'] ?? '').toString())
                .where((id) => id.isNotEmpty)
                .toList());
        await prefs.setBool('announcer.baselined', true);
      } else if (items.isNotEmpty) {
        final seen =
            (prefs.getStringList('announcer.seen') ?? []).toSet();
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
          await plugin.show(
            1000 + i,
            (it['title'] ?? 'gungan.fm').toString(),
            (it['body'] ?? '').toString(),
            details,
            payload: payload,
          );
          seen.add(id);
        }
        await prefs.setStringList('announcer.seen', seen.toList());
      }
    } catch (_) {
      // Never fail the task; WorkManager reschedules on its own cadence.
    }
    return true;
  });
}
