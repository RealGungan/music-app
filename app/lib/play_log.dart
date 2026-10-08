import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One listened chunk: song identity + when + how many real seconds.
/// Written on every track switch, read by the Wrapped stats. Cap keeps
/// prefs small (~60B/event -> ~600KB max).
/// Offline-safe: SharedPreferences only, no network — offline plays seal too.
class PlayEvent {
  final String base;
  final int atMs;
  final int seconds;
  PlayEvent({required this.base, required this.atMs, required this.seconds});

  Map<String, dynamic> toJson() =>
      {'b': base, 'at': atMs, 's': seconds};

  static PlayEvent? fromJson(dynamic j) {
    if (j is! Map) return null;
    final b = (j['b'] ?? '').toString();
    final at = (j['at'] as num?)?.toInt() ?? 0;
    final s = (j['s'] as num?)?.toInt() ?? 0;
    if (b.isEmpty || at <= 0 || s < 0) return null;
    return PlayEvent(base: b, atMs: at, seconds: s);
  }
}

class PlayLog {
  PlayLog._();
  static const _key = 'playlog.events.v1';
  static const _cap = 10000;

  static String _open = '';

  /// Track switch (call with the outgoing title + its position, and the
  /// incoming title). A finished chunk (>30s, a banked stream) is sealed
  /// even on same-title restarts; short stall-retry tails extend the open
  /// entry instead of double-counting.
  static Future<void> switched(
      String prevTitle, int prevSeconds, String newTitle) async {
    newTitle = newTitle.trim();
    prevTitle = prevTitle.trim();
    if (newTitle.isEmpty) return;
    if (newTitle != _open || prevSeconds > 30) {
      await _seal(prevTitle, prevSeconds);
      _open = newTitle;
    }
  }

  /// App going away mid-song: seal the open entry.
  static Future<void> flush(String title, int seconds) async {
    if (title.trim().isEmpty || title != _open) return;
    await _seal(title, seconds);
    _open = '';
  }

  static Future<void> _seal(String title, int seconds) async {
    title = title.trim();
    if (title.isEmpty || seconds < 5) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      final list =
          (raw != null && raw.isNotEmpty ? jsonDecode(raw) : []) as List;
      list.add(PlayEvent(
        base: title,
        atMs: DateTime.now().millisecondsSinceEpoch,
        seconds: seconds,
      ).toJson());
      while (list.length > _cap) {
        list.removeAt(0);
      }
      await prefs.setString(_key, jsonEncode(list));
    } catch (_) {
      // history must never break playback
    }
  }

  static Future<List<PlayEvent>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      return list
          .map(PlayEvent.fromJson)
          .whereType<PlayEvent>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> clear() async {
    _open = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}
