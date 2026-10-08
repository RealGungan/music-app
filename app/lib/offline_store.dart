import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

/// Thrown when a download (or a quota change) would break the user's cap.
class OfflineQuotaError implements Exception {
  final String message;
  OfflineQuotaError(this.message);
  @override
  String toString() => message;
}

/// One phone-side downloaded song.
class OfflineEntry {
  final String base;
  final int size;
  final String playlist;
  final String file;
  final String? thumb;
  final String? coverFile;
  final DateTime at;
  OfflineEntry({
    required this.base,
    required this.size,
    required this.playlist,
    required this.file,
    this.thumb,
    this.coverFile,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
        'size': size,
        'playlist': playlist,
        'file': file,
        if (thumb != null && thumb!.isNotEmpty) 'thumb': thumb,
        if (coverFile != null && coverFile!.isNotEmpty)
          'coverFile': coverFile,
        'at': at.millisecondsSinceEpoch,
      };

  static OfflineEntry fromJson(String base, Map<String, dynamic> j) =>
      OfflineEntry(
        base: base,
        size: (j['size'] as num? ?? 0).toInt(),
        playlist: (j['playlist'] ?? '').toString(),
        file: (j['file'] ?? '').toString(),
        thumb: (j['thumb'] as String?),
        coverFile: (j['coverFile'] as String?),
        at: DateTime.fromMillisecondsSinceEpoch(
            (j['at'] as num? ?? 0).toInt()),
      );
}

/// Phone-side song downloads with a user-capped storage quota.
///
/// Files live app-private (`<docs>/offline/`, no permission needed) so they
/// survive restarts but uninstall with the app. The index (sizes, playlist
/// tags, quota) lives in SharedPreferences. Identity is the NAS baseName
/// ("Artist - Title"), which is also what QueueItem.title carries — so the
/// player can prefer the phone copy with a single lookup.
class OfflineStore {
  OfflineStore._();
  static const _kIndex = 'offline.index.v1';
  static const _kQuota = 'offline.quota.gb';
  static const _kMode = 'offline.mode.v1'; // ask|mine|any|off
  static const double defaultQuotaGb = 2;

  static Directory? _dir;
  static final Map<String, OfflineEntry> _entries = {};
  static double quotaGb = defaultQuotaGb;

  /// Bumped on every mutation so Settings/queue UI can listen.
  static final ValueNotifier<int> change = ValueNotifier(0);

  /// Backfill a missing cover thumb (entries saved before thumbs were
  /// stored). No-op when already set. Persists + notifies.
  static Future<void> setThumb(String base, String thumb) async {
    final e = _entries[base];
    if (e == null || (e.thumb ?? '').isNotEmpty || thumb.isEmpty) return;
    _entries[base] = OfflineEntry(
      base: e.base,
      size: e.size,
      playlist: e.playlist,
      file: e.file,
      thumb: thumb,
      at: e.at,
    );
    await _save();
  }

  static Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    _dir = Directory('${docs.path}/offline');
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    final prefs = await SharedPreferences.getInstance();
    quotaGb = prefs.getDouble(_kQuota) ?? defaultQuotaGb;
    final raw = prefs.getString(_kIndex);
    _entries.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        map.forEach((base, v) {
          if (v is Map<String, dynamic>) {
            final e = OfflineEntry.fromJson(base, v);
            if (File('${_dir!.path}/${e.file}').existsSync()) {
              _entries[base] = e;
            }
          }
        });
      } catch (_) {
        // corrupt index: rescan below
      }
    }
    // Prune orphan cover art (audio deleted externally, cover left behind).
    try {
      final cdir = Directory('${_dir!.path}/covers');
      if (await cdir.exists()) {
        final live = _entries.values
            .map((e) => e.coverFile)
            .whereType<String>()
            .toSet();
        await for (final f in cdir.list()) {
          if (!live.contains('covers/${f.uri.pathSegments.last}')) {
            try {
              await f.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    await _save();
  }

  static Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kIndex,
        jsonEncode(_entries.map((k, v) => MapEntry(k, v.toJson()))));
    change.value++;
  }

  static int get bytesUsed =>
      _entries.values.fold(0, (sum, e) => sum + e.size);

  static int get quotaBytes => (quotaGb * 1024 * 1024 * 1024).round();

  static int get count => _entries.length;

  /// Lowering the cap below what's stored is refused (user asked: error,
  /// don't silently allow it).
  static Future<void> setQuotaGb(double gb) async {
    if (gb * 1024 * 1024 * 1024 < bytesUsed) {
      throw OfflineQuotaError(
          'Already using ${_fmt(bytesUsed)} — delete songs first.');
    }
    quotaGb = gb;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kQuota, gb);
    change.value++;
  }

  static String normKey(String s) => s.trim().toLowerCase();

  /// Same norm as PrefetchStore: exact trim first, then case-insensitive
  /// scan (keeps pre-existing mixed-case rows working). [alt] is the
  /// second identity (baseName vs display title) — tried when [base] misses.
  static OfflineEntry? _entryFor(String base, [String? alt]) {
    final hit = _exactOrNorm(base);
    if (hit != null) return hit;
    if (alt != null && alt.isNotEmpty && alt != base) {
      return _exactOrNorm(alt);
    }
    return null;
  }

  static OfflineEntry? _exactOrNorm(String base) {
    final t = base.trim();
    return _entries[t] ??
        _entries[normKey(base)] ??
        _entries.values
            .cast<OfflineEntry?>()
            .firstWhere((e) => normKey(e!.base) == normKey(base),
                orElse: () => null);
  }
  static String get mode => _modeCache ?? 'ask';
  static String? _modeCache;

  static Future<String> loadMode() async {
    final prefs = await SharedPreferences.getInstance();
    _modeCache = prefs.getString(_kMode) ?? 'ask';
    return _modeCache!;
  }

  static Future<void> setMode(String m) async {
    _modeCache = m;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, m);
    change.value++;
  }

  static bool isDownloaded(String base, [String? alt]) =>
      _entryFor(base, alt) != null;

  /// Absolute file:// URI for the phone copy, or null.
  static String? localUriFor(String base, [String? alt]) {
    final e = _entryFor(base, alt);
    if (e == null || _dir == null) return null;
    final f = File('${_dir!.path}/${e.file}');
    if (!f.existsSync()) return null;
    return Uri.file(f.path).toString();
  }

  static List<OfflineEntry> songsIn(String playlist) {
    final k = normKey(playlist);
    return _entries.values
        .where((e) => normKey(e.playlist) == k)
        .toList()
      ..sort((a, b) => a.base.compareTo(b.base));
  }

  static List<String> playlists() {
    final seen = <String, String>{}; // normKey -> first display name
    for (final e in _entries.values) {
      final k = normKey(e.playlist);
      seen.putIfAbsent(k, () => e.playlist.trim());
    }
    return seen.values.toList()..sort();
  }

  static List<OfflineEntry> all() => _entries.values.toList()
    ..sort((a, b) => b.at.compareTo(a.at));

  static String _fileName(String base, String ext) {
    final safe = base.trim().replaceAll(RegExp(r'[^\w\-. ]+'), '_');
    return '$safe.$ext';
  }

  /// Download [url] (must already carry ?token= — every QueueItem.url does)
  /// tagged to [playlist] ('' for loose songs). Enforces the quota before
  /// AND during the transfer; over-quota leaves no partial file behind.
  static Future<OfflineEntry> download({
    required String base,
    required String url,
    String playlist = '',
    String? thumb,
    ApiClient? api, // optional: if provided and playlist has cover, cache it
    void Function(int received, int? total)? onProgress,
  }) async {
    base = base.trim();
    playlist = playlist.trim();
    if (_dir == null) await init();
    if (isDownloaded(base)) return _entries[base]!;
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      // Interactive cap (was 30s): a DNS-dead route must fail fast enough
      // to flip bases, not park the download spinner for half a minute.
      final resp = await client.send(req).timeout(
          const Duration(seconds: 10));
      final total = resp.contentLength;
      if (total != null &&
          total > 0 &&
          bytesUsed + total > quotaBytes) {
        throw OfflineQuotaError(
            'Not enough phone space (${_fmt(bytesUsed)} of ${_fmt(quotaBytes)} used).');
      }
      final ctype = resp.headers['content-type'] ?? '';
      if (ctype.contains('text/html')) {
        throw OfflineQuotaError('Server refused the download (HTML reply).');
      }
      final ext = ctype.contains('mp4') || ctype.contains('m4a')
          ? 'm4a'
          : 'mp3';
      final tmp = File('${_dir!.path}/.${base.hashCode}.part');
      var received = 0;
      final sink = tmp.openWrite();
      try {
        await for (final chunk in resp.stream) {
          received += chunk.length;
          if (bytesUsed + received > quotaBytes) {
            throw OfflineQuotaError(
                'Download would exceed your ${_fmt(quotaBytes)} limit.');
          }
          sink.add(chunk);
          onProgress?.call(received, total);
        }
        await sink.close();
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {}
        if (await tmp.exists()) await tmp.delete();
        rethrow;
      }
      final entry = OfflineEntry(
        base: base,
        size: received,
        playlist: playlist,
        file: _fileName(base, ext),
        thumb: thumb,
        at: DateTime.now(),
      );
      // A cut connection can end the stream cleanly at any point — a
      // short file must never pass as a good download (it plays until
      // the cut, stalls, and the heal loop restarts it forever).
      if (received <= 0) {
        await tmp.delete();
        throw OfflineQuotaError('Download came back empty.');
      }
      if (total != null && total > 0 && received != total) {
        await tmp.delete();
        throw OfflineQuotaError(
            'Download cut off (${_fmt(received)} of ${_fmt(total)}) — try again.');
      }
      await tmp.rename('${_dir!.path}/${entry.file}');
      // Best-effort cover pre-cache (offline covers/pictures): a small
      // jpg next to the audio. Never fails the download — no cover just
      // means the gradient fallback until re-downloaded.
      var coverFile = '';
      if (thumb != null && thumb.isNotEmpty) {
        coverFile = await _fetchCover(base, thumb);
      }
      final done = OfflineEntry(
        base: entry.base,
        size: entry.size,
        playlist: entry.playlist,
        file: entry.file,
        thumb: entry.thumb,
        coverFile: coverFile.isEmpty ? null : coverFile,
        at: entry.at,
      );
      _entries[base] = done;
      await _save();
      // Best-effort: cache playlist cover if this download is from a playlist
      // and we don't have the cover cached yet. Runs in background, doesn't
      // block the download result.
      if (playlist.isNotEmpty && api != null) {
        unawaited(maybeCachePlaylistCover(playlist, api));
      }
      return done;
    } finally {
      client.close();
    }
  }

  /// Backfill covers for downloads made before pre-caching existed:
  /// fetches missing art (bounded count, best-effort, online only —
  /// callers must check connectivity first). Small thumbs, ~15s each max.
  static Future<void> backfillCovers({int max = 40}) async {
    if (_dir == null) return;
    var done = 0;
    for (final e in _entries.values) {
      if (done >= max) break;
      if (e.coverFile != null && e.coverFile!.isNotEmpty) continue;
      final t = e.thumb;
      if (t == null || t.isEmpty) continue;
      try {
        final coverFile = await _fetchCover(e.base, t);
        if (coverFile.isNotEmpty) {
          _entries[e.base] = OfflineEntry(
            base: e.base,
            size: e.size,
            playlist: e.playlist,
            file: e.file,
            thumb: e.thumb,
            coverFile: coverFile,
            at: e.at,
          );
          done++;
        }
      } catch (_) {}
    }
    if (done > 0) await _save();
  }

  /// Download thumb art to covers/<hash>.jpg. Returns the relative path
  /// or '' (too big, failed, not an image — never throws).
  static Future<String> _fetchCover(String base, String thumb) async {
    final client = http.Client();
    try {
      final cresp = await client
          .get(Uri.parse(thumb))
          .timeout(const Duration(seconds: 15));
      final bytes = cresp.bodyBytes;
      if (cresp.statusCode != 200 ||
          bytes.isEmpty ||
          bytes.length > 512 * 1024) {
        return '';
      }
      final cdir = Directory('${_dir!.path}/covers');
      if (!await cdir.exists()) await cdir.create(recursive: true);
      final rel = 'covers/${base.hashCode}.jpg';
      await File('${_dir!.path}/$rel').writeAsBytes(bytes);
      return rel;
    } catch (_) {
      return '';
    } finally {
      client.close();
    }
  }
  /// Local cover art path for a downloaded song (pre-cached at download
  /// time), or null. Lets art render instantly offline.
  static String? coverFileFor(String base, [String? alt]) {
    if (_dir == null) return null;
    final e = _entryFor(base, alt);
    final c = e?.coverFile;
    if (c == null || c.isEmpty) return null;
    final f = File('${_dir!.path}/$c');
    return f.existsSync() ? f.path : null;
  }

  /// Local playlist cover path (cached when user sets a cover), or null.
  /// Uses the same normalized key as the downloader: hash of the playlist name.
  static String? playlistCoverFileFor(String name) {
    if (_dir == null) return null;
    final f = File('${_dir!.path}/covers/pl_${name.hashCode}.jpg');
    return f.existsSync() ? f.path : null;
  }

  /// Normalized playlist cover key - consistent with downloader.
  static String _playlistCoverKey(String name) => 'covers/pl_${name.hashCode}.jpg';

  /// Download and cache a playlist cover from [url]. Returns true on success.
  static Future<bool> cachePlaylistCover(String name, String url) async {
    if (_dir == null) await init();
    final client = http.Client();
    try {
      final resp = await client.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      final bytes = resp.bodyBytes;
      if (resp.statusCode != 200 || bytes.isEmpty || bytes.length > 512 * 1024) {
        return false;
      }
      final cdir = Directory('${_dir!.path}/covers');
      if (!await cdir.exists()) await cdir.create(recursive: true);
      final rel = 'covers/pl_${name.hashCode}.jpg';
      await File('${_dir!.path}/$rel').writeAsBytes(bytes);
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Remove cached playlist cover.
  static Future<void> removePlaylistCover(String name) async {
    if (_dir == null) return;
    final f = File('${_dir!.path}/covers/pl_${name.hashCode}.jpg');
    if (await f.exists()) await f.delete();
  }

  /// Backfill missing playlist covers (online only — callers must check
  /// connectivity first). Fetches covers for playlists that have covers
  /// set on the server but no local cached file.
  static Future<void> backfillPlaylistCovers(
      List<Map<String, dynamic>> playlists, ApiClient api, {int max = 20}) async {
    if (_dir == null) await init();
    var done = 0;
    for (final pl in playlists) {
      if (done >= max) break;
      if (pl['hasCover'] != true) continue;
      final name = pl['name'] as String;
      final local = playlistCoverFileFor(name);
      if (local != null) continue;
      try {
        final coverUrl = api.playlistCoverUrl(name);
        final ok = await cachePlaylistCover(name, coverUrl);
        if (ok) done++;
      } catch (_) {}
    }
  }

  /// Cache a playlist cover if it exists on the server and we don't have it locally.
  /// Returns true if cached, false if no cover or already cached.
  static Future<bool> maybeCachePlaylistCover(String playlistName, ApiClient api) async {
    if (_dir == null) await init();
    // Check if already cached
    if (playlistCoverFileFor(playlistName) != null) return false;
    // Use the API client's playlistCoverUrl which includes auth token
    final coverUrl = api.playlistCoverUrl(playlistName);
    return await cachePlaylistCover(playlistName, coverUrl);
  }

  static Future<void> remove(String base) async {
    final e = _entries.remove(base.trim());
    if (e != null && _dir != null) {
      final f = File('${_dir!.path}/${e.file}');
      if (await f.exists()) await f.delete();
      final c = e.coverFile;
      if (c != null && c.isNotEmpty) {
        final cf = File('${_dir!.path}/$c');
        if (await cf.exists()) await cf.delete();
      }
    }
    await _save();
  }

  static Future<void> clear() async {
    _entries.clear();
    if (_dir != null && await _dir!.exists()) {
      await for (final f in _dir!.list(recursive: true)) {
        try {
          await f.delete(recursive: true);
        } catch (_) {}
      }
    }
    await _save();
  }

  static String fmtBytes(int b) => _fmt(b);

  static String _fmt(int b) {
    if (b >= 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (b >= 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }
}
