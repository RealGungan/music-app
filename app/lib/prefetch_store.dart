import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_store.dart';
import 'diag_log.dart';

/// Look-ahead song cache: while online, the next few queue songs are fetched
/// into app-private storage so playback survives going offline mid-queue.
///
/// Separate from OfflineStore (explicit user downloads): this cache is
/// automatic, WiFi-gated by default, LRU-capped, and invisible in the UI
/// except for the settings switches + size readout.
class PrefetchStore {
  PrefetchStore._();
  static const _kIndex = 'prefetch.index.v1';
  static const _kEnabled = 'prefetch.enabled';
  // v2 key: the v1 default (WiFi-only) silently disabled the whole feature
  // for mobile-data listeners, and the stored value can't be told apart
  // from an explicit choice — so everyone gets the new default (fetch on
  // any connection) once, and the Settings toggle still works after that.
  static const _kWifiOnly = 'prefetch.wifi-only.v2';

  /// How many upcoming songs to keep ready.
  static const int aheadCount = 10;

  /// How many files to fetch concurrently. Sequential fill of 11 songs
  /// (each with its own resolve + up-to-60s download) never finishes
  /// before the user goes offline; 3-way keeps it fast without
  /// starving the live stream.
  static const int fetchConcurrency = 3;

  /// One shared client for all prefetch downloads: a fresh client per
  /// song forces a fresh TLS handshake every time (handshake failures
  /// under burst concurrency), while keep-alive reuses connections.
  /// One shared client for all prefetch downloads: top-level http.get()
  /// opens a NEW TLS handshake per song, and bursts of parallel
  /// handshakes were failing (HandshakeException) and pressuring the
  /// shared pipe. Keep-alive reuses connections instead. App-lifetime
  /// singleton like ApiClient._client — never closed.
  static final http.Client _http = http.Client();

  /// Pure window computation for the look-ahead pass: a slice of [count]
  /// rows starting at [index], clamped to the queue. Callers pass
  /// index+1 for next-only (the playing song streams; never prefetched).
  static List<T> window<T>(List<T> items, int index, int count) {
    if (items.isEmpty || index < 0 || count <= 0) return <T>[];
    final start = index.clamp(0, items.length);
    final end = (index + count).clamp(0, items.length);
    if (start >= end) return <T>[];
    return items.sublist(start, end);
  }

  /// Cap for the whole cache (songs average ~5MB: ~60 songs fit).
  static const int maxBytes = 300 * 1024 * 1024;

  static Directory? _dir;
  static Directory? _docsDir;
  // Safe user this in-memory index belongs to (lowercased, sanitized).
  static String? _user;
  static final Map<String, _Entry> _entries = {};
  static bool _ready = false;
  // Guards concurrent first-use: without this, a second caller entering
  // init() mid-flight saw _ready==true with _dir still null and an
  // unloaded index (fileFor miss / _dir! crash swallowed as null).
  static Future<void>? _initializing;
  // Single-flight: concurrent fetch() calls for the same key await the
  // first GET instead of firing a duplicate download.
  static final Map<String, Future<String?>> _inFlight = {};

  static bool enabled = true;
  // Default: fetch on any connection. The whole point of the look-ahead
  // cache is surviving signal loss on mobile data; gating to WiFi by
  // default silently disables it for data listeners. Still toggleable
  // in Settings for data savers.
  static bool wifiOnly = false;

  /// Bumped on mutations the settings readout listens to.
  static final ValueNotifier<int> change = ValueNotifier(0);

  static String _safeUser(String? u) {
    final s = (u ?? '')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_');
    return s.isEmpty ? 'shared' : s;
  }

  static String _currentSafeUser() {
    try {
      return _safeUser(AuthStore.instance.username);
    } catch (_) {
      return 'shared';
    }
  }

  static File _indexFileFor(String safe) =>
      File('${_docsDir!.path}/prefetch-index.$safe.json');

  static Future<void> init() {
    // User switch: drop the cached future so the next caller loads the new
    // user's JSON instead of reusing the old user's in-memory index.
    if (_user != null && _currentSafeUser() != _user) {
      _initializing = null;
      _ready = false;
    }
    _initializing ??= _doInit();
    return _initializing!;
  }

  /// Force reload for the current user (call on login/logout/user switch;
  /// init() also auto-detects the switch lazily on next fileFor/fetch).
  static Future<void> reloadForUserSwitch() {
    _initializing = null;
    _ready = false;
    _entries.clear();
    return init();
  }

  /// Test hook: forget everything (user + dir + flags) between cases.
  static Future<void> resetForTest() {
    _initializing = null;
    _inFlight.clear();
    _ready = false;
    _user = null;
    _dir = null;
    _docsDir = null;
    _entries.clear();
    enabled = true;
    wifiOnly = false;
    return Future.value();
  }

  static Future<void> _doInit() async {
    if (_ready) return;
    final safe = _currentSafeUser();
    _user = safe;
    final docs = await getApplicationDocumentsDirectory();
    _docsDir = docs;
    _dir = Directory('${docs.path}/prefetch');
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    final prefs = await SharedPreferences.getInstance();
    // Per-user flags: per-user prefs, then legacy global (one-time migrate).
    enabled =
        prefs.getBool('$_kEnabled.$safe') ?? prefs.getBool(_kEnabled) ?? true;
    wifiOnly =
        prefs.getBool('$_kWifiOnly.$safe') ?? prefs.getBool(_kWifiOnly) ?? false;
    _entries.clear();
    var loaded = false;
    // 1. Per-user JSON in the app dir (survives kill + reinstall-kept data,
    //    unlike the memory-only index that read 0KB after a user switch).
    try {
      final f = _indexFileFor(safe);
      if (await f.exists()) {
        final fileRaw = await f.readAsString();
        if (fileRaw.isNotEmpty) {
          final doc = jsonDecode(fileRaw) as Map<String, dynamic>;
          enabled = (doc['enabled'] as bool?) ?? enabled;
          wifiOnly = (doc['wifiOnly'] as bool?) ?? wifiOnly;
          final idx = doc['entries'];
          if (idx is Map<String, dynamic>) {
            idx.forEach((k, v) {
              if (v is Map<String, dynamic>) {
                try {
                  final e = _Entry.fromJson(k, v);
                  if (e.file.isEmpty ||
                      File('${_dir!.path}/${e.file}').existsSync()) {
                    _entries[k] = e;
                  }
                } catch (_) {}
              }
            });
            loaded = true;
          }
        }
      }
    } catch (_) {}
    if (!loaded) {
      // 2. Per-user prefs, then 3. legacy global index (adopt on first run
      // after upgrade / user switch so the 4.8MB on disk isn't forgotten).
      final raw = prefs.getString('$_kIndex.$safe') ?? prefs.getString(_kIndex);
      _entries.clear();
      if (raw != null && raw.isNotEmpty) {
        try {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          map.forEach((k, v) {
            if (v is Map<String, dynamic>) {
              final e = _Entry.fromJson(k, v);
              if (File('${_dir!.path}/${e.file}').existsSync()) {
                _entries[k] = e;
              }
            }
          });
        } catch (_) {}
      }
    }
    // Rebuild: adopt orphan mp3s the map lost (title unrecoverable from a
    // bare '<hashCode>.mp3' name, so they count toward MB + LRU as
    // placeholders; a later fetch of the same title overwrites + rekeys).
    await _adoptOrphans();
    await _prune();
    // _prune() skips saving below the cap — save anyway so adopted orphans
    // and migrated flags actually reach disk.
    await _save();
    _ready = true;
  }

  static Future<void> _adoptOrphans() async {
    try {
      final live =
          _entries.values.map((e) => e.file).where((f) => f.isNotEmpty).toSet();
      await for (final ent in _dir!.list()) {
        if (ent is! File) continue;
        final name = ent.uri.pathSegments.last;
        if (!name.endsWith('.mp3') || live.contains(name)) continue;
        var size = 0;
        DateTime? m;
        try {
          size = await ent.length();
          m = (await ent.stat()).modified;
        } catch (_) {}
        if (size <= 0) continue;
        _entries['orphan:${name.substring(0, name.length - 4)}'] =
            _Entry(title: name, file: name, size: size, at: m);
      }
    } catch (_) {}
  }

  static String normKey(String s) => s.trim().toLowerCase();

  static String _key(String title) => normKey(title);

  // Legacy v1 keys (base64 title) — one-release fallback so existing
  // cache rows still hit after the key unification.
  static String _legacyKey(String title) =>
      base64Url.encode(utf8.encode(title)).replaceAll('=', '');

  // Identity is the NAS baseName ("Artist - Title"); QueueItem.title is
  // display text and can drift from it. Lookups try title first (existing
  // rows), then baseName — store keys prefer baseName when provided.
  static _Entry? _lookup(String title, [String? baseName]) {
    final hit = _entries[_key(title)] ?? _entries[_legacyKey(title)];
    if (hit != null) return hit;
    if (baseName != null && baseName.isNotEmpty && baseName != title) {
      return _entries[_key(baseName)] ?? _entries[_legacyKey(baseName)];
    }
    return null;
  }

  /// Cached file path for a title (or baseName), or null (missing prunes).
  static Future<String?> fileFor(String title, [String? baseName]) async {
    await init();
    final e = _lookup(title, baseName);
    if (e == null) return null;
    // Migrate legacy base64 rows to the unified norm key on first hit.
    final k = _key(title);
    if (_entries[k] == null) {
      _entries[k] = e;
      _entries.remove(_legacyKey(title));
      if (baseName != null && baseName.isNotEmpty && baseName != title) {
        _entries.remove(_legacyKey(baseName));
      }
      await _save();
    }
    if (e.file.isEmpty) return null; // liked-only row: no audio (yet).
    final f = File('${_dir!.path}/${e.file}');
    if (!await f.exists()) {
      _entries.remove(_key(title));
      _entries.remove(_legacyKey(title));
      if (baseName != null && baseName.isNotEmpty && baseName != title) {
        _entries.remove(_key(baseName));
        _entries.remove(_legacyKey(baseName));
      }
      await _save();
      return null;
    }
    return f.path;
  }

  static int get bytesUsed =>
      _entries.values.fold(0, (s, e) => s + e.size);

  static int get count => _entries.length;

  /// Sync availability check for grey-out decisions (index loads at init).
  /// Liked-only rows (no audio yet) don't count — nothing playable.
  static bool has(String title, [String? baseName]) =>
      _lookup(title, baseName)?.file.isNotEmpty == true;

  /// Cached cover-art file path for a title, or null.
  static String? coverFileFor(String title, [String? baseName]) {
    final e = _lookup(title, baseName);
    final c = e?.cover;
    if (c == null || c.isEmpty || _dir == null) return null;
    final f = File('${_dir!.path}/$c');
    return f.existsSync() ? f.path : null;
  }

  /// Cached liked status for a title (null = unknown).
  static bool? likedFor(String title, [String? baseName]) =>
      _lookup(title, baseName)?.liked;

  static Future<void> setLiked(String title, bool v, [String? baseName]) async {
    await init();
    final k = _key(
        (baseName?.isNotEmpty ?? false) ? baseName! : title);
    final e = _entries[k] ?? _lookup(title, baseName);
    if (e == null) {
      // No audio cached yet: still persist liked (audio-less row) so the
      // like survives offline and _load reads it back.
      _entries[k] = _Entry(title: title, file: '', size: 0, liked: v);
      await _save();
      return;
    }
    if (e.liked == v) return;
    _entries[k] = _Entry(
        title: e.title, file: e.file, size: e.size, at: e.at, cover: e.cover, liked: v);
    await _save();
  }

  /// Fetch one song into the cache (no-op when disabled, already cached,
  /// or off-WiFi while WiFi-only). Returns the file path or null.
  /// Pass [client] to bind this download's lifetime to something the
  /// caller can abort: closing it fails the in-flight GET immediately
  /// instead of holding the pipe up to 60s after nobody wants it.
  static Future<String?> fetch(String title, String url,
      {http.Client? client,
      String? thumbUrl,
      bool? liked,
      String? baseName,
      // Explicit PLAY tap: the user asked for THIS song, so data cost is
      // intentional — bypass wifiOnly (enabled still gates above).
      bool ignoreWifiOnly = false}) async {
    await init();
    if (!enabled || url.isEmpty || !url.startsWith('http')) return null;
    final k = _key((baseName?.isNotEmpty ?? false) ? baseName! : title);
    final hit = await fileFor(title, baseName);
    if (hit != null) {
      DiagLog.restart.log('prefetch-hit "$title"');
      await _fillMeta(title,
          baseName: baseName, thumbUrl: thumbUrl, liked: liked, client: client);
      return hit;
    }
    final ongoing = _inFlight[k];
    if (ongoing != null) return ongoing;
    final fut = _doFetch(title, url,
        client: client,
        thumbUrl: thumbUrl,
        liked: liked,
        baseName: baseName,
        ignoreWifiOnly: ignoreWifiOnly);
    _inFlight[k] = fut;
    try {
      return await fut;
    } finally {
      _inFlight.remove(k);
    }
  }

  static Future<String?> _doFetch(String title, String url,
      {http.Client? client,
      String? thumbUrl,
      bool? liked,
      String? baseName,
      bool ignoreWifiOnly = false}) async {
    await init();
    if (!enabled || url.isEmpty || !url.startsWith('http')) return null;
    final k = _key((baseName?.isNotEmpty ?? false) ? baseName! : title);
    final hit = await fileFor(title, baseName);
    if (hit != null) {
      DiagLog.restart.log('prefetch-hit "$title"');
      await _fillMeta(title,
          baseName: baseName, thumbUrl: thumbUrl, liked: liked, client: client);
      return hit;
    }
    if (!enabled) {
      DiagLog.restart.log('prefetch-skip "$title" (disabled)');
      return null;
    }
    if (!url.startsWith('http')) {
      DiagLog.restart.log('prefetch-skip "$title" (non-http url)');
      return null;
    }
    final onWifi = await _onWifi();
    if (wifiOnly && !onWifi && !ignoreWifiOnly) {
      DiagLog.restart.log(
          'prefetch-skip "$title" (wifiOnly, onWifi=$onWifi)');
      return null;
    }
    DiagLog.restart.log(
        'prefetch-fetch "$title" (wifiOnly=$wifiOnly onWifi=$onWifi)');
    try {
      final resp = await (client ?? _http)
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
        DiagLog.restart.log(
            'prefetch-fail "$title" (http ${resp.statusCode}, '
            '${resp.bodyBytes.length}b)');
        return null;
      }
      final fname = '${title.hashCode}.mp3';
      final file = File('${_dir!.path}/$fname');
      await file.writeAsBytes(resp.bodyBytes, flush: true);
      var cover = '';
      if (thumbUrl != null && thumbUrl.startsWith('http')) {
        cover = await _fetchCover(title, thumbUrl, client: client);
      }
      _entries[k] = _Entry(
          title: title,
          file: fname,
          size: resp.bodyBytes.length,
          cover: cover.isEmpty ? null : cover,
          liked: liked ?? _entries[k]?.liked);
      // A formerly-adopted orphan placeholder for this file is now rekeyed.
      _entries.removeWhere(
          (key, v) => key.startsWith('orphan:') && v.file == fname);
      // Persist the index on EVERY fetch, not just on prune: _prune()
      // returns early (without saving) below the cap, so without this
      // the cache was memory-only and vanished on every app restart.
      await _save();
      await _prune();
      change.value++;
      DiagLog.restart.log(
          'prefetch-saved "$title" (${resp.bodyBytes.length}b, '
          'total=${bytesUsed}b)');
      return file.path;
    } catch (e) {
      // Type only: exception text can embed the tokenized URL.
      DiagLog.restart.log('prefetch-fail "$title" (${e.runtimeType})');
      return null;
    }
  }

  static Future<bool> _onWifi() async {
    try {
      final rs = await Connectivity().checkConnectivity();
      return rs.contains(ConnectivityResult.wifi) ||
          rs.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return true;
    }
  }

  /// LRU eviction over the cap (oldest first). The cap holds audio +
  /// cover-art bytes on disk; orphans are entries so already counted.
  static Future<void> _prune() async {
    var total = bytesUsed + _coverBytes();
    if (total <= maxBytes) return;
    final ordered = _entries.entries.toList()
      ..sort((a, b) => a.value.at.compareTo(b.value.at));
    for (final kv in ordered) {
      if (total <= maxBytes) break;
      final e = kv.value;
      if (e.file.isEmpty) continue; // liked-only row: nothing to evict.
      final coverSize = _coverSizeOf(e);
      try {
        await File('${_dir!.path}/${e.file}').delete();
      } catch (_) {}
      if (e.cover != null && e.cover!.isNotEmpty) {
        try {
          await File('${_dir!.path}/${e.cover}').delete();
        } catch (_) {}
      }
      _entries.remove(kv.key);
      total -= e.size + coverSize;
    }
    await _save();
  }

  static int _coverSizeOf(_Entry e) {
    final c = e.cover;
    if (c == null || c.isEmpty || _dir == null) return 0;
    try {
      return File('${_dir!.path}/$c').lengthSync();
    } catch (_) {
      return 0;
    }
  }

  static int _coverBytes() {
    var n = 0;
    for (final e in _entries.values) {
      n += _coverSizeOf(e);
    }
    return n;
  }

  /// Best-effort cover download (<=512KB jpg next to the audio).
  static Future<String> _fetchCover(String title, String thumbUrl,
      {http.Client? client}) async {
    try {
      final resp = await (client ?? _http)
          .get(Uri.parse(thumbUrl))
          .timeout(const Duration(seconds: 15));
      final bytes = resp.bodyBytes;
      if (resp.statusCode != 200 || bytes.isEmpty || bytes.length > 512 * 1024) {
        return '';
      }
      final cdir = Directory('${_dir!.path}/covers');
      if (!await cdir.exists()) await cdir.create(recursive: true);
      final rel = 'covers/${title.hashCode}.jpg';
      await File('${_dir!.path}/$rel').writeAsBytes(bytes);
      return rel;
    } catch (_) {
      return '';
    }
  }

  /// Backfill cover/liked onto an already-cached row (offline skip/prev
  /// shows the same art + liked state).
  static Future<void> _fillMeta(String title,
      {String? baseName,
      String? thumbUrl,
      bool? liked,
      http.Client? client}) async {
    final e = _lookup(title, baseName);
    if (e == null) return;
    final k = _entries.entries
        .firstWhere((kv) => identical(kv.value, e),
            orElse: () => MapEntry(
                _key((baseName?.isNotEmpty ?? false) ? baseName! : title), e))
        .key;
    var cover = e.cover;
    if ((cover == null || cover.isEmpty) &&
        thumbUrl != null &&
        thumbUrl.startsWith('http')) {
      final c = await _fetchCover(title, thumbUrl, client: client);
      if (c.isNotEmpty) cover = c;
    }
    final l = liked ?? e.liked;
    if (cover == e.cover && l == e.liked) return;
    _entries[k] = _Entry(
        title: e.title, file: e.file, size: e.size, at: e.at, cover: cover, liked: l);
    await _save();
  }

  static Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final safe = _user ?? _currentSafeUser();
    // Preserve insert keys (baseName-preferred): rebuilding keys from
    // e.title here would silently rekey baseName rows back to display.
    final raw = jsonEncode(
        {for (final kv in _entries.entries) kv.key: kv.value.toJson()});
    await prefs.setString('$_kIndex.$safe', raw);
    // Legacy global key: one-release read fallback for old builds/tests.
    await prefs.setString(_kIndex, raw);
    await prefs.setBool('$_kEnabled.$safe', enabled);
    await prefs.setBool('$_kWifiOnly.$safe', wifiOnly);
    // Authoritative copy: per-user JSON in the app dir.
    try {
      _docsDir ??= await getApplicationDocumentsDirectory();
      await _indexFileFor(safe).writeAsString(
          jsonEncode({
            'enabled': enabled,
            'wifiOnly': wifiOnly,
            'entries': {
              for (final kv in _entries.entries) kv.key: kv.value.toJson()
            },
          }),
          flush: true);
    } catch (_) {}
    change.value++;
  }

  static Future<void> setEnabled(bool v) async {
    await init();
    enabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_kEnabled.${_user ?? _currentSafeUser()}', v);
    await _save();
  }

  static Future<void> setWifiOnly(bool v) async {
    await init();
    wifiOnly = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_kWifiOnly.${_user ?? _currentSafeUser()}', v);
    await _save();
  }

  /// Drop the whole look-ahead cache (explicit downloads untouched).
  static Future<void> clear() async {
    for (final e in _entries.values) {
      try {
        await File('${_dir!.path}/${e.file}').delete();
      } catch (_) {}
      if (e.cover != null && e.cover!.isNotEmpty) {
        try {
          await File('${_dir!.path}/${e.cover}').delete();
        } catch (_) {}
      }
    }
    _entries.clear();
    await _save();
  }
}

class _Entry {
  final String title;
  final String file;
  final int size;
  final DateTime at;
  final String? cover;
  final bool? liked;
  _Entry(
      {required this.title,
      required this.file,
      required this.size,
      DateTime? at,
      this.cover,
      this.liked})
      : at = at ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'title': title,
        'file': file,
        'size': size,
        'at': at.millisecondsSinceEpoch,
        if (cover != null && cover!.isNotEmpty) 'cover': cover,
        if (liked != null) 'liked': liked,
      };

  static _Entry fromJson(String _, Map<String, dynamic> j) => _Entry(
        title: (j['title'] ?? '').toString(),
        file: (j['file'] ?? '').toString(),
        size: (j['size'] as num? ?? 0).toInt(),
        at: DateTime.fromMillisecondsSinceEpoch(
            (j['at'] as num? ?? 0).toInt()),
        cover: (j['cover'] as String?),
        liked: (j['liked'] as bool?),
      );
}
