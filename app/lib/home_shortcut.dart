import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'deep_link.dart';
import 'offline_store.dart';

/// Launcher shortcuts for playlists ("Add to home screen").
///
/// The pinned set is ours, not Android's: the launcher only ever sees the
/// list we push, and it caps PINNED dynamic shortcuts at 4. Left to the
/// system a 5th pin silently kills one, which reads as a bug — so the cap
/// (and the eviction) live in [pinPlaylistShortcut] and we re-publish the
/// whole set after every change. SharedPreferences is the source of truth
/// because the launcher keeps its own copy of the shortcuts; on every app
/// start we re-push so a list the user edited outside the app comes back.
class HomeShortcuts {
  static const _channel = MethodChannel('com.nasmusic.nasmusic/shortcuts');
  static const _prefsKey = 'pl.pinned.shortcuts';

  static List<String> _pinned = const [];
  static List<String> get pinned => List.unmodifiable(_pinned);

  /// Read the pinned set and re-publish it. Call once on startup.
  static Future<void> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _pinned = (jsonDecode(raw) as List).map((e) => e.toString()).toList();
      } catch (_) {
        _pinned = const []; // corrupt prefs must not brick startup
      }
    }
    await publish();
  }

  /// Push the pinned set to the launcher. No-op on desktop (no native
  /// side behind the channel) and on Android < 25 (no ShortcutManager).
  static Future<void> publish() async {
    if (_pinned.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('publishShortcuts', [
        for (final n in _pinned)
          {
            // Stable across restarts (same trick as the cover cache keys):
            // re-pinning an existing playlist UPDATES its shortcut instead
            // of stacking a duplicate.
            'id': 'pl_${n.hashCode}',
            'label': n,
            'uri': playlistDeepLinkUri(n),
            // Cached cover bitmap path, or null -> app icon on the native side.
            'icon': OfflineStore.playlistCoverFileFor(n),
          },
      ]);
    } catch (e) {
      debugPrint('[shortcut] publish failed: $e');
    }
  }

  /// Pin [name] as a launcher shortcut. Returns the oldest playlist that
  /// had to be dropped to stay within the cap (null when nothing was).
  static Future<String?> pin(String name) async {
    if (name.trim().isEmpty) return null;
    final r = pinPlaylistShortcut(_pinned, name);
    _pinned = r.list;
    await (await SharedPreferences.getInstance()).setString(
          _prefsKey,
          jsonEncode(_pinned),
        );
    await publish();
    return r.evicted;
  }
}
