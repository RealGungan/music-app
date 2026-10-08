import 'package:shared_preferences/shared_preferences.dart';

/// Local (on-device) search + listened history stored via shared_preferences.
/// Search history is the exact query text the user ran; listened history is
/// the last played track titles (most recent first), deduped, capped.
class AppHistory {
  static const _searchKey = 'history.search';
  static const _listenKey = 'history.listen';

  static Future<List<String>> loadSearch() =>
      _load(_searchKey);

  static Future<List<String>> loadListen() =>
      _load(_listenKey);

  static Future<List<String>> _load(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(key) ?? <String>[];
  }

  /// Record a search query, most-recent-first, deduped, capped at [cap].
  static Future<void> recordSearch(String q) =>
      _record(_searchKey, q, cap: 15);

  /// Record a played track title, most-recent-first, deduped, capped at [cap].
  static Future<void> recordListen(String q) =>
      _record(_listenKey, q, cap: 30);

  static Future<void> _record(String key, String value, {required int cap}) async {
    final v = value.trim();
    if (v.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(key) ?? <String>[];
    list.removeWhere((x) => x == v);
    list.insert(0, v);
    if (list.length > cap) list.removeRange(cap, list.length);
    await prefs.setStringList(key, list);
  }

  static Future<void> clearSearch() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_searchKey);
  }

  static Future<void> clearListen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_listenKey);
  }
}
