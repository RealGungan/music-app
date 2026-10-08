import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

/// Last-known library metadata, shown when the server is unreachable.
/// Tiny JSON (a 2000-song library is ~200KB) — this costs no phone space
/// to speak of. Keyed per user; refreshed on every successful load.
class MetaCache {
  MetaCache._();

  static String _listsKey(String user) => 'meta.playlists.$user';
  static String _entriesKey(String user, String name) =>
      'meta.entries.$user.$name';

  static Future<void> savePlaylists(
      String user, List<PlaylistInfo> pls) async {
    if (user.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_listsKey(user),
          jsonEncode([for (final p in pls) p.toJson()]));
    } catch (_) {}
  }

  static Future<List<PlaylistInfo>> loadPlaylists(String user) async {
    if (user.isEmpty) return [];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_listsKey(user));
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      return [
        for (final j in list)
          if (j is Map<String, dynamic>) PlaylistInfo.fromJson(j)
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveEntries(
      String user, String name, List<PlaylistEntry> entries) async {
    if (user.isEmpty || name.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_entriesKey(user, name),
          jsonEncode([for (final e in entries) e.toJson()]));
    } catch (_) {}
  }

  static Future<List<PlaylistEntry>> loadEntries(
      String user, String name) async {
    if (user.isEmpty || name.isEmpty) return [];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_entriesKey(user, name));
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      return [
        for (final j in list)
          if (j is Map<String, dynamic>) PlaylistEntry.fromJson(j)
      ];
    } catch (_) {
      return [];
    }
  }

  /// Offline search over cached entries: case-insensitive substring on the
  /// baseName. Pure (no prefs) so it unit-tests without mocks.
  static List<PlaylistEntry> searchEntries(
      List<PlaylistEntry> entries, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    return entries
        .where((e) => e.baseName.toLowerCase().contains(q))
        .toList();
  }
}
