import 'dart:convert';

import 'package:http/http.dart' as http;

class LocalResult {
  final String baseName;
  final String folder;
  final String url;
  final String artist;
  LocalResult(
      {required this.baseName,
      required this.folder,
      required this.url,
      this.artist = ''});

  factory LocalResult.fromJson(Map<String, dynamic> j) => LocalResult(
        baseName: j['base_name'],
        folder: j['folder'] ?? '',
        url: j['url'],
        artist: j['artist'] ?? '',
      );
}

class DiscoveryResult {
  final String videoId;
  final String artist;
  final String title;
  final String channel;
  final int durationS;
  final int score;
  final int tier;
  final String streamUri;
  DiscoveryResult({
    required this.videoId,
    required this.artist,
    required this.title,
    required this.channel,
    required this.durationS,
    required this.score,
    required this.tier,
    required this.streamUri,
  });

  factory DiscoveryResult.fromJson(Map<String, dynamic> j) => DiscoveryResult(
        videoId: j['video_id'],
        artist: j['artist'],
        title: j['title'],
        channel: j['channel'] ?? '',
        durationS: j['duration_s'] ?? 0,
        score: j['score'] ?? 0,
        tier: j['tier'] ?? 2,
        streamUri: j['stream_uri'],
      );
}

class SearchResultPage {
  final List<LocalResult> local;
  final List<DiscoveryResult> discovery;
  SearchResultPage({required this.local, required this.discovery});
}

class JobStatus {
  final String id;
  final String baseName;
  final String status;
  final String? error;
  JobStatus({required this.id, required this.baseName, required this.status, this.error});

  bool get isActive =>
      ['queued', 'searching', 'downloading', 'retrying', 'pending']
          .contains(status);

  factory JobStatus.fromJson(Map<String, dynamic> j) => JobStatus(
      id: j['id'],
      baseName: j['base_name'],
      status: j['status'] ?? '?',
      error: j['error']);
}

class DownloadRow {
  final String id;
  final String baseName;
  final String status;
  final String? videoId;
  final String? channel;
  final int? durationS;
  final String? path;
  DownloadRow({
    required this.id,
    required this.baseName,
    required this.status,
    this.videoId,
    this.channel,
    this.durationS,
    this.path,
  });

  factory DownloadRow.fromJson(Map<String, dynamic> j) => DownloadRow(
        id: j['id'],
        baseName: j['base_name'],
        status: j['status'],
        videoId: j['video_id'],
        channel: j['channel'],
        durationS: j['duration_s'],
        path: j['path'],
      );
}

class Candidate {
  final String videoId;
  final String title;
  final String channel;
  final int? durationS;
  final int? score;
  Candidate(
      {required this.videoId,
      required this.title,
      required this.channel,
      this.durationS,
      this.score});

  factory Candidate.fromJson(Map<String, dynamic> j) => Candidate(
        videoId: j['video_id'],
        title: j['title'] ?? '',
        channel: j['channel'] ?? '',
        durationS: j['duration_s'],
        score: j['score'],
      );
}

class PlaylistInfo {
  final String name;
  final int tracks;
  PlaylistInfo({required this.name, required this.tracks});

  factory PlaylistInfo.fromJson(Map<String, dynamic> j) =>
      PlaylistInfo(name: j['name'], tracks: j['tracks'] ?? 0);
}

class PlaylistEntry {
  final String baseName;
  final String path;
  final bool exists;
  final String? url;
  final int? addedAt; // epoch seconds, when known from an export
  final String? albumImage;
  PlaylistEntry(
      {required this.baseName,
      required this.path,
      required this.exists,
      this.url,
      this.addedAt,
      this.albumImage});

  factory PlaylistEntry.fromJson(Map<String, dynamic> j) => PlaylistEntry(
        baseName: j['base_name'],
        path: j['path'],
        exists: j['exists'] ?? false,
        url: j['url'],
        addedAt: j['added_at'],
        albumImage: j['album_image'],
      );
}

class LyricLine {
  final int tMs;
  final String text;
  LyricLine(this.tMs, this.text);
}

class Lyrics {
  final List<LyricLine> synced;
  final String? plain;
  bool get hasSynced => synced.isNotEmpty;
  Lyrics(this.synced, this.plain);
}

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);
  @override
  String toString() => 'API $statusCode: $message';
}

class ApiClient {
  ApiClient({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();
  final String baseUrl;
  final http.Client _client;

  static const _timeout = Duration(seconds: 45);

  Future<T> _guard<T>(Future<T> future) =>
      future.timeout(_timeout, onTimeout: () => throw ApiException(
          0,
          'server took longer than 45s — check WiFi / server address'));

  Uri _uri(String path, [Map<String, String>? q]) =>
      Uri.parse('$baseUrl/staging$path').replace(queryParameters: q);

  Future<http.Response> _get(Uri u, {Map<String, String>? h}) =>
      _guard(_client.get(u, headers: h));
  Future<http.Response> _post(Uri u, {Object? b, Map<String, String>? h}) =>
      _guard(_client.post(u, headers: h, body: b));
  Future<http.Response> _delete(Uri u,
          {Object? b, Map<String, String>? h}) =>
      _guard(_client.delete(u, headers: h, body: b));

  Map<String, dynamic> _decode(http.Response r) {
    final body = utf8.decode(r.bodyBytes);
    Map<String, dynamic> j;
    try {
      j = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(r.statusCode, body);
    }
    if (r.statusCode >= 400) {
      throw ApiException(r.statusCode, (j['error'] ?? body).toString());
    }
    return j;
  }

  Future<SearchResultPage> search(String q) async {
    final j = _decode(await _get(_uri('/api/search', {'q': q})));
    return SearchResultPage(
      local: (j['local'] as List)
          .map((e) => LocalResult.fromJson(e))
          .toList(),
      discovery: (j['discovery'] as List)
          .map((e) => DiscoveryResult.fromJson(e))
          .toList(),
    );
  }

  Future<String> stage(String artist, String title) async {
    final j = _decode(await _post(_uri('/api/stage'),
        b: jsonEncode({'artist': artist, 'title': title})));
    return j['id'] as String;
  }

  Future<List<JobStatus>> jobs() async {
    final j = _decode(await _get(_uri('/api/jobs')));
    return (j['jobs'] as List).map((e) => JobStatus.fromJson(e)).toList();
  }

  Future<List<DownloadRow>> downloads({String? status}) async {
    final j = _decode(await _get(_uri('/api/downloads',
        status != null ? {'status': status} : null)));
    return (j['downloads'] as List)
        .map((e) => DownloadRow.fromJson(e))
        .toList();
  }

  Future<List<Candidate>> candidates(String downloadId) async {
    final j = _decode(await _get(_uri('/api/downloads/$downloadId')));
    return (j['candidates'] as List)
        .map((e) => Candidate.fromJson(e))
        .toList();
  }

  Future<void> redownload(String downloadId, String videoId) async {
    _decode(await _post(_uri('/api/redownload'),
        b: jsonEncode({'download_id': downloadId, 'video_id': videoId})));
  }

  Future<void> remove(String downloadId) async {
    _decode(await _delete(_uri('/api/downloads/$downloadId')));
  }

  Future<void> keep(String downloadId, String playlist) async {
    _decode(await _post(_uri('/api/keep'),
        b: jsonEncode({'download_id': downloadId, 'playlist': playlist})));
  }

  Future<List<PlaylistInfo>> playlists() async {
    final j = _decode(await _get(_uri('/api/playlists')));
    return (j['playlists'] as List)
        .map((e) => PlaylistInfo.fromJson(e))
        .toList();
  }

  Future<List<PlaylistEntry>> playlistEntries(String name) async {
    final j = _decode(await _get(_uri('/api/playlists/$name')));
    return (j['entries'] as List)
        .map((e) => PlaylistEntry.fromJson(e))
        .toList();
  }

  Future<void> createPlaylist(String name) async {
    _decode(await _post(_uri('/api/playlists'),
        b: jsonEncode({'name': name})));
  }

  Future<void> removeFromPlaylist(String name,
      {required String baseName}) async {
    _decode(await _delete(_uri('/api/playlists/$name/entries'),
        b: jsonEncode({'base_name': baseName})));
  }

  Future<void> deletePlaylist(String name) async {
    _decode(await _delete(_uri('/api/playlists/$name')));
  }

  /// Universal 'add to playlist'. Works for staged, downloading,
  /// already-kept and never-downloaded tracks alike.
  Future<void> addToPlaylist(
      {String? downloadId, String? baseName, required String playlist}) async {
    _decode(await _post(_uri('/api/keep'),
        b: jsonEncode({
          if (downloadId != null) 'download_id': downloadId,
          if (baseName != null) 'base_name': baseName,
          'playlist': playlist,
        })));
  }

  Future<String> resolve(String videoId) async {
    final j = _decode(await _get(_uri('/api/resolve/$videoId')));
    return j['url'] as String;
  }

  Future<List<DiscoveryResult>> similar(String query,
      {List<String> excludeTitles = const [], int n = 8}) async {
    final j = _decode(await _get(_uri('/api/similar', {
      'q': query,
      'n': '$n',
      'exclude': excludeTitles.join('||'),
    })));
    return (j['similar'] as List)
        .map((e) => DiscoveryResult(
              videoId: e['video_id'],
              artist: query,
              title: e['title'],
              channel: e['channel'] ?? '',
              durationS: e['duration_s'] ?? 0,
              score: 0,
              tier: 1,
              streamUri: 'staging:yt:${e['video_id']}',
            ))
        .toList();
  }

  Future<Lyrics?> lyrics(String fileRelUrl) async {
    final f = fileRelUrl.replaceFirst('/staging/file/', '');
    try {
      final j = _decode(await _client
          .get(_uri('/api/lyrics', {'f': Uri.encodeComponent(f)})));
      return Lyrics(
        [for (final l in (j['synced'] as List))
          LyricLine(l['t'] as int, l['text'] as String)],
        j['plain'] as String?,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<List<LocalResult>> allTracks() async {
    final j = _decode(await _get(_uri('/api/tracks')));
    return (j['tracks'] as List)
        .map((e) => LocalResult.fromJson({
              'base_name': e['base_name'],
              'folder': e['folder'],
              'url': e['url'],
            }))
        .toList();
  }

  /// Reachability probe: GET /staging/
  Future<void> ping() async {
    await _get(Uri.parse('$baseUrl/staging/'));
  }

  /// Server info (paths, expiry) from GET /staging/
  Future<Map<String, dynamic>> info() async {
    final r = await _get(Uri.parse('$baseUrl/staging/'));
    return _decode(r);
  }

  /// Whether the server can discover non-library songs (yt-dlp present).
  Future<bool> discoveryAvailable() async {
    final j = await info();
    return j['discovery_available'] == true;
  }

  /// Absolute URL for playing a library file through the server.
  String fileUrl(String relativeFileUrl) => '$baseUrl$relativeFileUrl';

  /// Album-art endpoint for a '/staging/file/...' URL.
  String coverUrl(String fileRelUrl) {
    final f = fileRelUrl.replaceFirst('/staging/file/', '');
    return '$baseUrl/staging/api/cover?f=${Uri.encodeComponent(f)}';
  }
}
