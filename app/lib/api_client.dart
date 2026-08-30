import 'dart:convert';

import 'package:http/http.dart' as http;

/// A song already on the NAS library.
class LibraryTrack {
  final String baseName;
  final String folder;
  final String url;
  LibraryTrack({required this.baseName, required this.folder, required this.url});

  factory LibraryTrack.fromJson(Map<String, dynamic> j) => LibraryTrack(
        baseName: j['base_name'],
        folder: j['folder'] ?? '',
        url: j['url'],
      );
}

/// A not-yet-owned track discovered from YouTube / YouTube Music.
class DiscoveryTrack {
  final String videoId;
  final String artist;
  final String title;
  final String channel;
  final int durationS;
  final int score;
  final int tier;
  DiscoveryTrack({
    required this.videoId,
    required this.artist,
    required this.title,
    required this.channel,
    required this.durationS,
    required this.score,
    required this.tier,
  });

  factory DiscoveryTrack.fromJson(Map<String, dynamic> j) => DiscoveryTrack(
        videoId: j['video_id'],
        artist: j['artist'],
        title: j['title'],
        channel: j['channel'] ?? '',
        durationS: j['duration_s'] ?? 0,
        score: j['score'] ?? 0,
        tier: j['tier'] ?? 2,
      );
}

class SearchResultPage {
  final List<LibraryTrack> library;
  final List<DiscoveryTrack> discovery;
  SearchResultPage({required this.library, required this.discovery});
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
  Candidate({
    required this.videoId,
    required this.title,
    required this.channel,
    this.durationS,
    this.score,
  });

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
  final String? albumImage;
  PlaylistEntry({
    required this.baseName,
    required this.path,
    required this.exists,
    this.url,
    this.albumImage,
  });

  factory PlaylistEntry.fromJson(Map<String, dynamic> j) => PlaylistEntry(
        baseName: j['base_name'],
        path: j['path'],
        exists: j['exists'] ?? false,
        url: j['url'],
        albumImage: j['album_image'],
      );
}

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);
  @override
  String toString() => 'API $statusCode: $message';
}

/// Client for the NASMusic server's `/staging/` API.
class ApiClient {
  ApiClient({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  Uri _uri(String path, [Map<String, String>? q]) =>
      Uri.parse('$baseUrl/staging$path').replace(queryParameters: q);

  Map<String, dynamic> _decode(http.Response r) {
    final body = utf8.decode(r.bodyBytes);
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      j = null;
    }
    if (r.statusCode >= 400) {
      throw ApiException(r.statusCode, (j?['error'] ?? body).toString());
    }
    return j ?? <String, dynamic>{};
  }

  Future<SearchResultPage> search(String q) async {
    final j = _decode(await _client.get(_uri('/api/search', {'q': q})));
    return SearchResultPage(
      library: (j['local'] as List? ?? [])
          .map((e) => LibraryTrack.fromJson(e))
          .toList(),
      discovery: (j['discovery'] as List? ?? [])
          .map((e) => DiscoveryTrack.fromJson(e))
          .toList(),
    );
  }

  Future<String> stage(String artist, String title) async {
    final j = _decode(await _client.post(
      _uri('/api/stage'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'artist': artist, 'title': title}),
    ));
    return j['id'] as String;
  }

  Future<List<DownloadRow>> downloads({String? status}) async {
    final j = _decode(await _client.get(
        _uri('/api/downloads', status != null ? {'status': status} : null)));
    return (j['downloads'] as List? ?? [])
        .map((e) => DownloadRow.fromJson(e))
        .toList();
  }

  Future<List<Candidate>> candidates(String downloadId) async {
    final j =
        _decode(await _client.get(_uri('/api/downloads/$downloadId')));
    return (j['candidates'] as List? ?? [])
        .map((e) => Candidate.fromJson(e))
        .toList();
  }

  Future<void> redownload(String downloadId, String videoId) async {
    _decode(await _client.post(
      _uri('/api/redownload'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'download_id': downloadId, 'video_id': videoId}),
    ));
  }

  Future<void> remove(String downloadId) async {
    _decode(await _client.delete(_uri('/api/downloads/$downloadId')));
  }

  Future<void> addToPlaylist({
    String? downloadId,
    String? baseName,
    required String playlist,
  }) async {
    _decode(await _client.post(
      _uri('/api/keep'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        if (downloadId != null) 'download_id': downloadId,
        if (baseName != null) 'base_name': baseName,
        'playlist': playlist,
      }),
    ));
  }

  Future<List<PlaylistInfo>> playlists() async {
    final j = _decode(await _client.get(_uri('/api/playlists')));
    return (j['playlists'] as List? ?? [])
        .map((e) => PlaylistInfo.fromJson(e))
        .toList();
  }

  Future<List<PlaylistEntry>> playlistEntries(String name) async {
    final j = _decode(await _client.get(_uri('/api/playlists/$name')));
    return (j['entries'] as List? ?? [])
        .map((e) => PlaylistEntry.fromJson(e))
        .toList();
  }

  Future<void> createPlaylist(String name) async {
    _decode(await _client.post(
      _uri('/api/playlists'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'name': name}),
    ));
  }

  Future<void> removeFromPlaylist(String name, {required String baseName}) async {
    _decode(await _client.delete(
      _uri('/api/playlists/$name/entries'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'base_name': baseName}),
    ));
  }

  Future<void> deletePlaylist(String name) async {
    _decode(await _client.delete(_uri('/api/playlists/$name')));
  }

  /// Streaming URL for a discovery track, proxied through the server. The
  /// player always talks to the NAS (cleartext-allowed HTTP) instead of
  /// YouTube directly, and the server relays with an Android-safe format.
  Future<String> resolve(String videoId) async =>
      '$baseUrl/staging/api/stream?vid=$videoId';

  /// Absolute URL for playing a library file through the server.
  /// Path segments are percent-encoded (space, `'`, `,`, `()`, …) because
  /// Android's MediaPlayer will not encode them and the raw request line
  /// (with spaces) breaks the server's HTTP parsing → player timeout.
  String fileUrl(String relativeFileUrl) {
    final encoded = relativeFileUrl
        .split('/')
        .map((s) => s.isEmpty ? '' : Uri.encodeComponent(s))
        .join('/');
    return '$baseUrl$encoded';
  }

  /// Album-art endpoint for a `/staging/file/...` or `/staging/pl/...` URL.
  String coverUrl(String fileRelUrl) {
    String f;
    if (fileRelUrl.startsWith('/staging/file/')) {
      f = fileRelUrl.replaceFirst('/staging/file/', '');
    } else if (fileRelUrl.startsWith('/staging/pl/')) {
      f = 'pl:' + fileRelUrl.replaceFirst('/staging/pl/', '');
    } else {
      f = fileRelUrl;
    }
    return '$baseUrl/staging/api/cover?f=${Uri.encodeComponent(f)}';
  }

  /// YouTube thumbnail proxied through the server (for discovery tracks).
  String thumbUrl(String videoId) =>
      '$baseUrl/staging/api/cover?vid=$videoId';
}
