import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// A song already on the NAS library.
class LibraryTrack {
  final String baseName;
  final String folder;
  final String url;
  LibraryTrack({
    required this.baseName,
    required this.folder,
    required this.url,
  });

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

  /// Provider that pinned the canonical identity (Spotify, Deezer, YouTube).
  final String provider;

  /// True when this exact track already exists in the NAS library.
  final bool inNas;

  /// Source library marker: 'nas' when the track is on NAS (in_nas=true),
  /// allowing _bestLocal fast path to work without a populated library section.
  final String? library;

  /// Track art from the provider (Deezer cover); preferred over the
  /// low-res YouTube thumbnail for discovery tiles.
  final String? album;
  final String? albumImage;
  DiscoveryTrack({
    required this.videoId,
    required this.artist,
    required this.title,
    required this.channel,
    required this.durationS,
    required this.score,
    required this.tier,
    this.provider = 'YouTube',
    this.inNas = false,
    this.library,
    this.album,
    this.albumImage,
  });

  factory DiscoveryTrack.fromJson(Map<String, dynamic> j) => DiscoveryTrack(
    videoId: j['video_id'],
    artist: j['artist'],
    title: j['title'],
    channel: j['channel'] ?? '',
    durationS: j['duration_s'] ?? 0,
    score: j['score'] ?? 0,
    tier: j['tier'] ?? 2,
    provider: j['provider'] ?? 'YouTube',
    inNas: j['in_nas'] == true,
    library: j['library']?.toString(),
    album: j['album']?.toString(),
    albumImage: j['album_image']?.toString(),
  );
}

/// Resolved query identity shared across results (provider + expected dur).
class ResolvedQuery {
  final String? artist;
  final String? title;
  final String provider;
  final int? expectedDur;
  ResolvedQuery({
    this.artist,
    this.title,
    this.provider = 'YouTube',
    this.expectedDur,
  });

  factory ResolvedQuery.fromJson(Map<String, dynamic> j) => ResolvedQuery(
    artist: j['artist'],
    title: j['title'],
    provider: j['provider'] ?? 'YouTube',
    expectedDur: (j['expected_dur'] as num?)?.toInt(),
  );
}

class SearchResultPage {
  final List<LibraryTrack> library;
  final List<DiscoveryTrack> discovery;
  final List<ArtistHit> artists;
  final ResolvedQuery? resolved;
  final bool discoveryPending;
  final bool artistsPending;
  SearchResultPage({
    required this.library,
    required this.discovery,
    this.artists = const [],
    this.resolved,
    this.discoveryPending = false,
    this.artistsPending = false,
  });

  factory SearchResultPage.fromJson(Map<String, dynamic> j) => SearchResultPage(
    library: ((j['local'] as List?) ?? [])
        .whereType<Map<String, dynamic>>()
        .map(LibraryTrack.fromJson)
        .toList(),
    discovery: ((j['discovery'] as List?) ?? [])
        .whereType<Map<String, dynamic>>()
        .map(DiscoveryTrack.fromJson)
        .toList(),
    discoveryPending: (j['discovery_pending'] as bool?) ?? false,
    artistsPending: (j['artists_pending'] as bool?) ?? false,
    artists: ((j['artists'] as List?) ?? [])
        .whereType<Map<String, dynamic>>()
        .map(ArtistHit.fromJson)
        .toList(),
    resolved: j['resolved'] == null
        ? null
        : ResolvedQuery.fromJson(j['resolved'] as Map<String, dynamic>),
  );
}

/// An artist hit with a photo, shown at the top of search results.
class ArtistHit {
  final String name;
  final String? image;
  final int? albumCount;
  ArtistHit({required this.name, this.image, this.albumCount});

  factory ArtistHit.fromJson(Map<String, dynamic> j) => ArtistHit(
    name: j['name'] ?? '',
    image: j['image'],
    albumCount: (j['album_count'] as num?)?.toInt(),
  );
}

/// One timestamped lyric line (synced LRC).
class LyricLine {
  final double t;
  final String text;
  LyricLine({required this.t, required this.text});

  factory LyricLine.fromJson(Map<String, dynamic> j) =>
      LyricLine(t: (j['t'] as num?)?.toDouble() ?? 0, text: j['text'] ?? '');
}

/// Lyrics for a track: synced lines and/or plain lines.
class LyricsData {
  final String source;
  final bool found;
  final List<LyricLine> synced;
  final List<String> plain;
  LyricsData({
    required this.source,
    required this.found,
    required this.synced,
    required this.plain,
  });

  bool get isSynced => synced.isNotEmpty;

  factory LyricsData.fromJson(Map<String, dynamic> j) => LyricsData(
    source: j['source'] ?? '',
    found: j['found'] == true,
    synced: (j['synced'] as List? ?? [])
        .map((e) => LyricLine.fromJson(e))
        .toList(),
    plain: (j['plain'] as List? ?? []).map((e) => e.toString()).toList(),
  );
}

/// Album/artist info for a song (from the bundled Spotify metadata).
class MetaInfo {
  final String baseName;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? albumImage;
  MetaInfo({
    required this.baseName,
    this.artist,
    this.album,
    this.albumArtist,
    this.albumImage,
  });

  factory MetaInfo.fromJson(Map<String, dynamic> j) => MetaInfo(
    baseName: j['base_name'],
    artist: j['artist'],
    album: j['album'],
    albumArtist: j['album_artist'],
    albumImage: j['album_image'],
  );
}

/// One playable song inside an artist/album page.
class ArtistSong {
  final String baseName;
  final String? title;
  final String? artist;
  final bool exists;
  final String? url;
  final String? album;
  final String? albumImage;
  final int? durationS;
  ArtistSong({
    required this.baseName,
    this.title,
    this.artist,
    required this.exists,
    this.url,
    this.album,
    this.albumImage,
    this.durationS,
  });

  factory ArtistSong.fromJson(Map<String, dynamic> j) => ArtistSong(
    baseName: j['base_name'],
    title: j['title'],
    artist: j['artist'],
    exists: j['exists'] ?? false,
    url: j['url'],
    album: j['album'],
    albumImage: j['album_image'],
    durationS: j['duration_s'] as int?,
  );
}

class ArtistAlbum {
  final String album;
  final String? albumArtist;
  final String? image;
  final int tracks;
  final int owned;
  final int? albumId;
  final String type;
  ArtistAlbum({
    required this.album,
    this.albumArtist,
    this.image,
    required this.tracks,
    this.owned = 0,
    this.albumId,
    this.type = 'album',
  });

  factory ArtistAlbum.fromJson(Map<String, dynamic> j) => ArtistAlbum(
    album: j['album'] ?? '',
    albumArtist: j['album_artist'],
    image: j['image'],
    tracks: j['tracks'] ?? 0,
    owned: j['owned'] ?? 0,
    albumId: (j['album_id'] as num?)?.toInt(),
    type: j['type'] ?? 'album',
  );
}

class ArtistPage {
  final String name;
  final String? photo;
  final List<ArtistSong> songs;
  final List<ArtistAlbum> albums;
  final List<ArtistSong> singles;
  final bool pending;

  /// Raw server pending sections (e.g. ['photo']): lets the page render
  /// songs/albums immediately and fetch only the photo async.
  final List<String> pendingSections;
  ArtistPage({
    required this.name,
    this.photo,
    required this.songs,
    required this.albums,
    required this.singles,
    this.pending = false,
    this.pendingSections = const [],
  });

  factory ArtistPage.fromJson(Map<String, dynamic> j) {
    final sections =
        ((j['pending'] as List?) ?? []).map((e) => e.toString()).toList();
    return ArtistPage(
      name: j['name'] ?? '',
      photo: j['photo'],
      songs: (j['songs'] as List? ?? [])
          .map((e) => ArtistSong.fromJson(e))
          .toList(),
      albums: (j['albums'] as List? ?? [])
          .map((e) => ArtistAlbum.fromJson(e))
          .toList(),
      singles: (j['singles'] as List? ?? [])
          .map((e) => ArtistSong.fromJson(e))
          .toList(),
      pending: sections.isNotEmpty,
      pendingSections: sections,
    );
  }

  /// Photo-only remainder: content is ready, just the photo is still warming.
  bool get photoOnlyPending =>
      pending && pendingSections.every((s) => s == 'photo');

  ArtistPage withPhoto(String? p) => ArtistPage(
    name: name,
    photo: p ?? photo,
    songs: songs,
    albums: albums,
    singles: singles,
    pending: p != null ? false : pending,
    pendingSections: p != null ? const [] : pendingSections,
  );
}

class AlbumPage {
  final String album;
  final String? artist;
  final String? image;
  final List<ArtistSong> songs;
  AlbumPage({
    required this.album,
    this.artist,
    this.image,
    required this.songs,
  });

  factory AlbumPage.fromJson(Map<String, dynamic> j) => AlbumPage(
    album: j['album'] ?? '',
    artist: j['artist'],
    image: j['image'],
    songs: (j['songs'] as List? ?? [])
        .map((e) => ArtistSong.fromJson(e))
        .toList(),
  );
}

class LikedStatus {
  final bool liked;
  final bool downloaded;
  LikedStatus({required this.liked, required this.downloaded});

  factory LikedStatus.fromJson(Map<String, dynamic> j) => LikedStatus(
    liked: j['liked'] == true,
    downloaded: j['downloaded'] == true,
  );
}

/// One live suggestion while searching (online Deezer suggestions, or a
/// NAS-only row in older servers). Online rows carry artist/title + provider
/// and are played by streaming; local rows carry baseName/url.
class Suggestion {
  final String kind;
  final String baseName;
  final String folder;
  final String url;
  final String? artist;
  final String? title;
  final String? album;
  final String? albumImage;
  final String? provider;
  final int? durationS;
  final bool isExplicit;
  final bool isOnline;

  /// Server-annotated NAS hit (from /api/recommend + /api/radio): when the
  /// recommended song already exists on the NAS, [inNas] is true and [nasUrl]
  /// is the local file path — play the local copy instead of streaming.
  final bool inNas;
  final String? nasUrl;
  Suggestion({
    this.kind = 'song',
    this.baseName = '',
    this.folder = '',
    this.url = '',
    this.artist,
    this.title,
    this.album,
    this.albumImage,
    this.provider,
    this.durationS,
    this.isExplicit = false,
    this.inNas = false,
    this.nasUrl,
    bool? isOnline,
  }) : isOnline = isOnline ?? (baseName.isEmpty);

  factory Suggestion.fromJson(Map<String, dynamic> j) {
    final hasOnline =
        (j['kind'] == 'song') && j['url'] == null && (j['base_name'] == null);
    return Suggestion(
      kind: j['kind'] ?? 'song',
      baseName: j['base_name'] ?? '',
      folder: j['folder'] ?? '',
      url: j['url'] ?? '',
      artist: j['artist'],
      title: j['title'],
      album: j['album'],
      albumImage: j['album_image'],
      provider: j['provider'],
      durationS: j['duration_s'] is int ? j['duration_s'] : null,
      isExplicit: j['is_explicit'] == true,
      inNas: j['in_nas'] == true,
      nasUrl: j['nas_url'],
      isOnline: hasOnline,
    );
  }
}

class ResolvedName {
  final String url;
  final String videoId;
  final String thumb;
  final String? artist;
  final String? title;

  /// The identity of the ACTUAL YouTube video chosen (resolvename) — used as
  /// the lyrics key so lyrics match what is really playing.
  final String? resolvedArtist;
  final String? resolvedTitle;
  ResolvedName({
    required this.url,
    required this.videoId,
    required this.thumb,
    this.artist,
    this.title,
    this.resolvedArtist,
    this.resolvedTitle,
  });

  factory ResolvedName.fromJson(Map<String, dynamic> j) => ResolvedName(
    url: j['url'],
    videoId: j['video_id'],
    thumb: j['thumb'] ?? '',
    artist: j['artist'],
    title: j['title'],
    resolvedArtist: j['resolved_artist'],
    resolvedTitle: j['resolved_title'],
  );
}

/// Identity of a song opened from a public share link (Spotify / YT-Music)
/// — /api/open-url's payload. [kind] is 'youtube' or 'spotify'.
class OpenLink {
  final String kind;
  final String videoId;
  final String artist;
  final String title;
  final String image;
  final String url;
  OpenLink({
    required this.kind,
    this.videoId = '',
    this.artist = '',
    this.title = '',
    this.image = '',
    this.url = '',
  });

  factory OpenLink.fromJson(Map<String, dynamic> j) => OpenLink(
    kind: (j['kind'] ?? 'unknown').toString(),
    videoId: (j['video_id'] ?? '').toString(),
    artist: (j['artist'] ?? '').toString(),
    title: (j['title'] ?? '').toString(),
    image: (j['image'] ?? '').toString(),
    url: (j['url'] ?? '').toString(),
  );
}

/// Result of the lightweight "is this song already on the NAS?" check
/// (/api/innas) — the queue uses it to prefer the local copy of an internet
/// song (bug O).
class InNasHit {
  final bool found;
  final String? baseName;
  final String? url;
  final String? rel;
  final String? album;
  final String? albumImage;
  InNasHit({
    required this.found,
    this.baseName,
    this.url,
    this.rel,
    this.album,
    this.albumImage,
  });

  factory InNasHit.fromJson(Map<String, dynamic> j) => InNasHit(
    found: j['found'] == true,
    baseName: j['base_name'],
    url: j['url'],
    rel: j['rel'],
    album: j['album'],
    albumImage: j['album_image'],
  );
}

/// One song's integrity result from /api/checksongs.
///
/// [status] is one of: 'ok' (clean studio copy), 'too_short' (likely censored
/// or edited — actual much shorter than the studio original), 'too_long'
/// (extended / live / remix), or 'no_ref' (no studio reference duration we
/// could match — worth a manual listen).
class CheckSongReport {
  final String baseName;
  final String status;
  final double? actualDur;
  final double? expectedDur;
  final double? driftS;
  final String? rel;
  final String? url;
  final String? realArtist;
  final String? realTitle;
  final bool mismatch;
  CheckSongReport({
    required this.baseName,
    required this.status,
    this.actualDur,
    this.expectedDur,
    this.driftS,
    this.rel,
    this.url,
    this.realArtist,
    this.realTitle,
    this.mismatch = false,
  });

  factory CheckSongReport.fromJson(Map<String, dynamic> j) => CheckSongReport(
    baseName: j['base_name'] ?? '',
    status: j['status'] ?? 'no_ref',
    actualDur: (j['actual_dur'] as num?)?.toDouble(),
    expectedDur: (j['expected_dur'] as num?)?.toDouble(),
    driftS: (j['drift_s'] as num?)?.toDouble(),
    rel: j['rel'],
    url: j['url'],
    realArtist: j['real_artist'],
    realTitle: j['real_title'],
    mismatch: j['mismatch'] == true,
  );

  bool get isProblem =>
      status == 'too_short' ||
      status == 'too_long' ||
      status == 'no_ref' ||
      status == 'unverified' ||
      status == 'needs_explicit_check';

  /// True when the report carries a URL the player can actually fetch.
  /// Staging-dir files have no play route (server sends url=null), and a
  /// bare relpath fallback would 404 in the player — never offer Play for
  /// those rows.
  bool get isPlayable =>
      url != null &&
      (url!.startsWith('/staging/file/') ||
          url!.startsWith('/staging/pl/') ||
          url!.startsWith('/staging/u/'));
}

class CheckSongsStatus {
  final bool running;
  final int scanned;
  final int total;
  final bool done;
  final List<CheckSongReport> reports;
  final String scope;
  CheckSongsStatus({
    required this.running,
    required this.scanned,
    required this.total,
    required this.done,
    required this.reports,
    this.scope = '',
  });

  factory CheckSongsStatus.fromJson(Map<String, dynamic> j) => CheckSongsStatus(
    running: j['running'] == true,
    scanned: (j['scanned'] as num?)?.toInt() ?? 0,
    total: (j['total'] as num?)?.toInt() ?? 0,
    done: j['done'] == true,
    reports: ((j['reports'] as List?) ?? [])
        .whereType<Map<String, dynamic>>()
        .map(CheckSongReport.fromJson)
        .toList(),
    scope: j['scope'] ?? '',
  );
}

class LyricsReport {
  final String baseName;
  final String status; // ok / none / mismatch / error
  final String? source;
  final String? reason;
  final String? theirTitle;
  final String? theirArtist;
  LyricsReport({
    required this.baseName,
    required this.status,
    this.source,
    this.reason,
    this.theirTitle,
    this.theirArtist,
  });

  factory LyricsReport.fromJson(Map<String, dynamic> j) => LyricsReport(
    baseName: j['base_name'] ?? '',
    status: j['status'] ?? 'none',
    source: j['source'] as String?,
    reason: j['reason'] as String?,
    theirTitle: j['their_title'] as String?,
    theirArtist: j['their_artist'] as String?,
  );

  bool get isProblem =>
      status == 'none' || status == 'mismatch' || status == 'error';
}

class LyricsStatus {
  final bool running;
  final int scanned;
  final int total;
  final bool done;
  final List<LyricsReport> reports;
  final String scope;
  LyricsStatus({
    required this.running,
    required this.scanned,
    required this.total,
    required this.done,
    required this.reports,
    this.scope = '',
  });

  factory LyricsStatus.fromJson(Map<String, dynamic> j) => LyricsStatus(
    running: j['running'] == true,
    scanned: (j['scanned'] as num?)?.toInt() ?? 0,
    total: (j['total'] as num?)?.toInt() ?? 0,
    done: j['done'] == true,
    reports: ((j['reports'] as List?) ?? [])
        .whereType<Map<String, dynamic>>()
        .map(LyricsReport.fromJson)
        .toList(),
    scope: j['scope'] ?? '',
  );
}

class SongVersion {
  final int? id;
  final String name;
  final String artist;
  final String album;
  final String albumImage;
  final int? durationS;
  final bool explicit;
  final String type;
  final bool isStudio;
  final String source;

  /// 30-second Deezer MP3 preview URL (non-NAS rows only).
  final String? previewUrl;

  /// For the NAS copy row: the file's relative URL so the picker can
  /// stream-preview the version already on the NAS.
  final String? nasRel;

  /// Correct serving URL for the NAS copy (handles /staging/file/ vs
  /// /staging/pl/ for playlist-dir files).
  final String? nasUrl;
  SongVersion({
    this.id,
    required this.name,
    required this.artist,
    required this.album,
    required this.albumImage,
    this.durationS,
    required this.explicit,
    required this.type,
    required this.isStudio,
    this.source = 'deezer',
    this.previewUrl,
    this.nasRel,
    this.nasUrl,
  });

  factory SongVersion.fromJson(Map<String, dynamic> j) => SongVersion(
    id: (j['id'] as num?)?.toInt(),
    name: j['name'] ?? '',
    artist: j['artist'] ?? '',
    album: j['album'] ?? '',
    albumImage: j['album_image'] ?? '',
    durationS: (j['duration_s'] as num?)?.toInt(),
    explicit: j['explicit'] == true,
    type: j['type'] ?? 'studio',
    isStudio: j['is_studio'] == true,
    source: j['source'] ?? 'deezer',
    previewUrl: j['preview_url'] as String?,
    nasRel: j['nas_rel'] as String?,
    nasUrl: j['nas_url'] as String?,
  );

  bool get isNas => source == 'nas';
}

class SpotifyRef {
  final String? spotifyId;
  final String name;
  final List<String> artists;
  final String album;
  final String albumImage;
  final int? durationS;
  final bool explicit;
  SpotifyRef({
    this.spotifyId,
    required this.name,
    required this.artists,
    required this.album,
    required this.albumImage,
    this.durationS,
    required this.explicit,
  });

  factory SpotifyRef.fromJson(Map<String, dynamic> j) => SpotifyRef(
    spotifyId: j['spotify_id'],
    name: j['name'] ?? '',
    artists: ((j['artists'] as List?) ?? []).whereType<String>().toList(),
    album: j['album'] ?? '',
    albumImage: j['album_image'] ?? '',
    durationS: (j['duration_s'] as num?)?.toInt(),
    explicit: j['explicit'] == true,
  );
}

class SongVersions {
  final String baseName;
  final String? artist;
  final String? title;
  final int? currentDur;
  final int? expectedDur;
  final String reason;
  final String? error;
  final SpotifyRef? spotify;
  final List<SongVersion> versions;
  SongVersions({
    required this.baseName,
    this.artist,
    this.title,
    this.currentDur,
    this.expectedDur,
    this.reason = '',
    this.error,
    this.spotify,
    required this.versions,
  });

  factory SongVersions.fromJson(Map<String, dynamic> j) => SongVersions(
    baseName: j['base_name'] ?? '',
    artist: j['artist'],
    title: j['title'],
    currentDur: (j['current_dur'] as num?)?.toInt(),
    expectedDur: (j['expected_dur'] as num?)?.toInt(),
    reason: j['reason'] ?? '',
    error: j['error'],
    spotify: j['spotify'] == null
        ? null
        : SpotifyRef.fromJson(j['spotify'] as Map<String, dynamic>),
    versions: ((j['versions'] as List?) ?? [])
        .whereType<Map<String, dynamic>>()
        .map(SongVersion.fromJson)
        .toList(),
  );
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

/// Live background-job state (/api/jobs): the pipeline's in-memory phase
/// when the worker is alive (with failure reason), else the durable DB row
/// status. Polled by the check-songs replace flow so "downloaded" (staged)
/// is never confused with "swapped in" (kept).
class JobStatus {
  final String id;
  final String baseName;
  final String status;
  final String? error;
  JobStatus({
    required this.id,
    required this.baseName,
    required this.status,
    this.error,
  });

  factory JobStatus.fromJson(Map<String, dynamic> j) => JobStatus(
    id: (j['id'] ?? '').toString(),
    baseName: (j['base_name'] ?? '').toString(),
    status: (j['status'] ?? '').toString(),
    error: j['error']?.toString(),
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
  final double? addedAt;
  final bool hasCover;
  PlaylistInfo({
    required this.name,
    required this.tracks,
    this.addedAt,
    this.hasCover = false,
  });

  factory PlaylistInfo.fromJson(Map<String, dynamic> j) => PlaylistInfo(
    name: j['name'],
    tracks: j['tracks'] ?? 0,
    addedAt: (j['added_at'] as num?)?.toDouble(),
    hasCover: j['has_cover'] == true,
  );

  Map<String, dynamic> toJson() => {
        'name': name,
        'tracks': tracks,
        if (addedAt != null) 'added_at': addedAt,
        'has_cover': hasCover,
      };
}

class PlaylistEntry {
  final String baseName;
  final String path;
  final bool exists;
  final String? url;
  final String? albumImage;
  final int? durationS;
  final double? addedAt;

  /// Inlined by the playlist-detail payload (single open = single call):
  /// per-row liked/in_nas/cover flags, no extra roundtrips on funnel.
  final bool liked;
  final bool inNas;

  /// Direct CDN art (ytimg/dzcdn) when the server knows one: fetch it
  /// straight off the CDN instead of NAS-proxied bytes (proxy doubles
  /// the funnel uplink). Null = fall back to [ApiClient.coverUrl].
  final String? coverDirect;
  PlaylistEntry({
    required this.baseName,
    required this.path,
    required this.exists,
    this.url,
    this.albumImage,
    this.durationS,
    this.addedAt,
    this.liked = false,
    this.inNas = false,
    this.coverDirect,
  });

  factory PlaylistEntry.fromJson(Map<String, dynamic> j) {
    final cd = j['cover_direct']?.toString();
    final ai = j['album_image']?.toString() ?? '';
    return PlaylistEntry(
      baseName: j['base_name'],
      path: j['path'],
      exists: j['exists'] ?? false,
      url: j['url'],
      albumImage: j['album_image'],
      durationS: j['duration_s'] as int?,
      addedAt: (j['added_at'] as num?)?.toDouble(),
      liked: j['liked'] == true,
      inNas: (j['in_nas'] ?? j['exists']) == true,
      coverDirect: (cd != null && cd.isNotEmpty)
          ? cd
          : (ai.startsWith('http') ? ai : null),
    );
  }

  Map<String, dynamic> toJson() => {
        'base_name': baseName,
        'path': path,
        'exists': exists,
        if (url != null) 'url': url,
        if (albumImage != null) 'album_image': albumImage,
        if (durationS != null) 'duration_s': durationS,
        if (addedAt != null) 'added_at': addedAt,
        'liked': liked,
        'in_nas': inNas,
        if (coverDirect != null) 'cover_direct': coverDirect,
      };
}

class PlaylistDetail {
  final String name;
  final List<PlaylistEntry> entries;
  final double? totalSeconds;
  final String source;
  PlaylistDetail({
    required this.name,
    required this.entries,
    this.totalSeconds,
    this.source = '',
  });
}

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);
  @override
  String toString() => 'API $statusCode: $message';
}

/// Result of register/login: who you are + the session token the device
/// keeps until logout (no re-entering credentials).
class AuthSession {
  final String username;
  final String token;
  final bool adopted;
  AuthSession({
    required this.username,
    required this.token,
    this.adopted = false,
  });

  factory AuthSession.fromJson(Map<String, dynamic> j) => AuthSession(
        username: (j['username'] ?? '').toString(),
        token: (j['token'] ?? '').toString(),
        adopted: j['adopted'] == true,
      );
}

/// True for net errors that must never become User-error rows: user-cancel
/// aborts (superseded suggest, disposed download) + best-effort typeahead
/// (the suggest UI already ignores these — logging them made most of the
/// timeout noise).
bool isNetNoise(String path, Object e) {
  final m = e.toString().toLowerCase();
  if (m.contains('cancel') ||
      m.contains('abort') ||
      m.contains('connection closed') ||
      m.contains('connection reset')) {
    return true;
  }
  if (path.contains('/api/suggest') &&
      (e is TimeoutException || e is SocketException)) {
    return true;
  }
  return false;
}

/// True for DNS-level failures (unresolvable funnel/tailnet host): these
/// must flip to the other reachable base, not just log a timeout row.
bool isDnsFailure(Object e) {
  if (e is! SocketException) return false;
  final m = e.toString().toLowerCase();
  return m.contains('failed host lookup') ||
      m.contains('no address associated') ||
      m.contains('network is unreachable') ||
      m.contains('no route to host');
}

/// http.Client wrapper that caps every request: the stock client has NO
/// timeout, so a dead route (Tailscale not up yet at cold start, DNS
/// blackhole) hangs the awaiting future FOREVER — stuck gate spinner,
/// stuck song loading. One choke point covers all ~40 call sites.
class _TimeoutClient extends http.BaseClient {
  _TimeoutClient(this._inner);
  final http.Client _inner;
  static const Duration _limit = Duration(seconds: 30);

  /// Fire-and-forget net-error sink (Timeout/Socket → server user_errors
  /// as `timeout`). Never logs the client-log call itself (recursion).
  void Function(String kind, String message)? onNetError;

  /// Fired on DNS-level failures so the client flips to the other
  /// reachable base (tailnet ↔ funnel) instead of only logging.
  void Function()? onConnectionFailure;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    try {
      return await _inner.send(request).timeout(_limit);
    } on TimeoutException catch (e) {
      if (!path.contains('client-log') && !isNetNoise(path, e)) {
        onNetError?.call('timeout', '${request.method} $path: $e');
      }
      rethrow;
    } on SocketException catch (e) {
      if (!path.contains('client-log') && !isNetNoise(path, e)) {
        onNetError?.call('timeout', '${request.method} $path: $e');
      }
      if (isDnsFailure(e)) onConnectionFailure?.call();
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}

/// Client for the gungan.fm server's `/staging/` API.
class ApiClient {
  ApiClient({required this.baseUrl, http.Client? client})
      : _client = _TimeoutClient(client ?? http.Client()) {
    _client.onNetError = (k, m) => logClientError(k, m);
    // DNS death = wrong base, not a slow server: flip tailnet ↔ funnel
    // once, best-effort (never blocks the failing call itself).
    _client.onConnectionFailure = () {
      unawaited(handleBaseFailure().catchError((_) => serverBase));
    };
  }

  /// Reachable-base endpoints: fast tailnet first, public funnel fallback.
  /// No manual toggle — [selectBestBase] probes both and all URLs follow.
  static const lanBase = 'http://100.89.94.101:8004';
  static const funnelBase = 'https://naboo.taildfeb4f.ts.net';
  static const _kActiveBase = 'server.activeBase.v1';
  static const _probeTimeout = Duration(seconds: 2);

  final String baseUrl;
  final _TimeoutClient _client;

  /// Currently selected base (null = not yet probed, fall back to [baseUrl]).
  String? _activeBase;

  /// True when the fast tailnet base is the live one (for any indicator).
  bool get usingLan => serverBase == _norm(lanBase);

  static String _norm(String s) {
    var v = s;
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    if (v.toLowerCase().endsWith('/staging')) {
      v = v.substring(0, v.length - '/staging'.length);
    }
    return v;
  }

  static Future<bool> _probe(String base) async {
    final c = http.Client();
    try {
      final r = await c
          .head(Uri.parse('${_norm(base)}/staging'))
          .timeout(_probeTimeout);
      return r.statusCode < 500;
    } catch (_) {
      return false;
    } finally {
      c.close();
    }
  }

  /// Probe both bases in parallel, preferring tailnet. Persists the winner
  /// so the next cold start has a cached choice instantly. Keeps the
  /// current base when neither answers (no slow death to a dead probe).
  Future<String> selectBestBase() async {
    if (_activeBase == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final cached = prefs.getString(_kActiveBase);
        if (cached != null && cached.isNotEmpty) _activeBase = _norm(cached);
      } catch (_) {}
    }
    final results = await Future.wait([_probe(lanBase), _probe(funnelBase)]);
    final best = results[0]
        ? _norm(lanBase)
        : results[1]
            ? _norm(funnelBase)
            : null;
    if (best != null && best != _activeBase) {
      _activeBase = best;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kActiveBase, best);
      } catch (_) {}
    }
    return serverBase;
  }

  /// Current base just failed: flip to the other one immediately (fast
  /// fallback, no second 2s stall), else re-probe. Returns the live base.
  Future<String> handleBaseFailure() async {
    final next =
        usingLan ? _norm(funnelBase) : _norm(lanBase);
    if (await _probe(next)) {
      _activeBase = next;
    } else {
      return selectBestBase();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kActiveBase, _activeBase!);
    } catch (_) {}
    return serverBase;
  }

  /// Manual server switch (settings): pin this base as the cached choice.
  Future<void> pinBase(String base) async {
    _activeBase = _norm(base);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kActiveBase, _activeBase!);
    } catch (_) {}
  }

  /// Client build tag (e.g. "1.0.80"), sent as ?av= on every request so
  /// the server log shows which build each phone runs. Set once at
  /// startup from PackageInfo; 'unknown' keeps old behavior.
  String appVersion = 'unknown';

  /// Session token from login/register (multi-user). Sent as `?token=` on
  /// every request — players and Image widgets can't set headers, so the
  /// query param is the single uniform mechanism (the server also accepts
  /// the X-NASMusic-Token header, unused here).
  String? authToken;

  /// Fired once per 401 response so the app can bounce to the login screen.
  Future<void> Function()? onAuthFailure;
  bool _notifiedAuthFailure = false;

  /// Normalized server root for display + hand-built URLs (no trailing
  /// slashes, no trailing `/staging`).
  String get serverBase => _base;

  /// Base without trailing slashes or a trailing `/staging` (users paste
  /// the full public URL; `/staging` is appended here exactly once).
  /// Prefers the probed [_activeBase] so every file/stream/cover/resolve
  /// URL follows the reachable-base choice.
  String get _base => _norm(_activeBase ?? baseUrl);

  Uri _uri(String path, [Map<String, String>? q]) {
    final params = <String, String>{...?q};
    final t = authToken;
    if (t != null && t.isNotEmpty) params['token'] = t;
    if (appVersion.isNotEmpty) params['av'] = appVersion;
    return Uri.parse('$_base/staging$path')
        .replace(queryParameters: params.isEmpty ? null : params);
  }

  /// Fast TCP reachability probe to the NAS (1.5s cap). Used for instant
  /// offline decisions instead of relying on connectivity_plus which only
  /// reports interface state (WiFi up ≠ NAS reachable).
  Future<bool> ping() async {
    try {
      final uri = Uri.parse(_base);
      final host = uri.host;
      final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
      await Socket.connect(host, port, timeout: const Duration(milliseconds: 1500));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Append the session token to a hand-built absolute URL (file, stream,
  /// cover, thumb — used by the player and Image widgets).
  String _tok(String url) {
    final t = authToken;
    if (t == null || t.isEmpty) return url;
    var u =
        '$url${url.contains('?') ? '&' : '?'}token=${Uri.encodeComponent(t)}';
    if (appVersion.isNotEmpty) {
      u += '&av=${Uri.encodeComponent(appVersion)}';
    }
    return u;
  }

  void _notifyAuthFailure() {
    final cb = onAuthFailure;
    if (cb == null || _notifiedAuthFailure) return;
    _notifiedAuthFailure = true;
    cb().catchError((_) {}).whenComplete(() {
      _notifiedAuthFailure = false;
    });
  }

  Map<String, dynamic> _decode(http.Response r) {
    final body = utf8.decode(r.bodyBytes);
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      j = null;
    }
    if (r.statusCode >= 400) {
      // YTM endpoints reuse 401 for "YouTube login missing" — that must
      // NEVER expire the app session (it logged users out of the app
      // just for opening a YTM list). Only real app-auth 401s bounce.
      final path = r.request?.url.path ?? '';
      if (r.statusCode == 401 && !path.contains('/ytm')) {
        _notifyAuthFailure();
      }
      throw ApiException(r.statusCode, (j?['error'] ?? body).toString());
    }
    return j ?? <String, dynamic>{};
  }

  Future<SearchResultPage> search(String q) async {
    final j = _decode(await _client.get(_uri('/api/search', {'q': q})));
    return SearchResultPage.fromJson(j);
  }

  Future<String> stage(String artist, String title) async {
    final j = _decode(
      await _client.post(
        _uri('/api/stage'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'artist': artist, 'title': title}),
      ),
    );
    return j['id'] as String;
  }

  Future<List<DownloadRow>> downloads({String? status}) async {
    final j = _decode(
      await _client.get(
        _uri('/api/downloads', status != null ? {'status': status} : null),
      ),
    );
    return (j['downloads'] as List? ?? [])
        .map((e) => DownloadRow.fromJson(e))
        .toList();
  }

  Future<List<Candidate>> candidates(String downloadId) async {
    final j = _decode(await _client.get(_uri('/api/downloads/$downloadId')));
    return (j['candidates'] as List? ?? [])
        .map((e) => Candidate.fromJson(e))
        .toList();
  }

  /// Live job board (pipeline phases + failure reasons). Empty on any
  /// failure — callers fall back to downloads().
  Future<List<JobStatus>> jobs() async {
    try {
      final j = _decode(await _client.get(_uri('/api/jobs')));
      return (j['jobs'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(JobStatus.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> redownload(String downloadId, String videoId) async {
    _decode(
      await _client.post(
        _uri('/api/redownload'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'download_id': downloadId, 'video_id': videoId}),
      ),
    );
  }

  Future<void> remove(String downloadId) async {
    _decode(await _client.delete(_uri('/api/downloads/$downloadId')));
  }

  Future<void> addToPlaylist({
    String? downloadId,
    String? baseName,
    required String playlist,
  }) async {
    _decode(
      await _client.post(
        _uri('/api/keep'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          if (downloadId != null) 'download_id': downloadId,
          if (baseName != null) 'base_name': baseName,
          'playlist': playlist,
        }),
      ),
    );
  }

  /// Report a client-side failure to the server log (stored in its events
  /// table). Fire-and-forget: never throws, never blocks. Offline sends are
  /// QUEUED in prefs (cap 50) and flushed on the next successful send, so
  /// release-build failures are still visible in Settings → User errors
  /// once the phone is back online (debugPrint is stripped in release).
  static const _kLogQueue = 'clientlog.queue.v1';
  static const _kLogQueueCap = 50;

  Future<void> logClientError(String kind, String message) async {
    final k = kind.length > 40 ? kind.substring(0, 40) : kind;
    final m = message.length > 500 ? message.substring(0, 500) : message;
    if (m.isEmpty) return;
    await _flushQueuedLogs();
    try {
      await _client
          .post(
            _uri('/api/client-log'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'kind': k, 'message': m, 'av': appVersion}),
          )
          .timeout(const Duration(seconds: 10));
      await _flushQueuedLogs();
    } catch (_) {
      await _queueLog(k, m);
    }
  }

  Future<void> _queueLog(String k, String m) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final q = prefs.getStringList(_kLogQueue) ?? [];
      q.add(jsonEncode({
        'k': k,
        'm': m,
        'ts': DateTime.now().millisecondsSinceEpoch,
      }));
      while (q.length > _kLogQueueCap) {
        q.removeAt(0);
      }
      await prefs.setStringList(_kLogQueue, q);
    } catch (_) {}
  }

  /// Public flush: call on connectivity back-online, app resume,
  /// settings open — NOT just "next send" (cached screens make no API
  /// calls, so the queue sat in prefs forever with zero offline rows).
  Future<void> flushQueuedLogs() => _flushQueuedLogs();

  /// Self-test "Error pipeline": writes a sentinel playback row then reads
  /// it back via user-errors to prove the end-to-end path works.
  Future<bool> verifyLogPipeline() async {
    final sentinel = 'error-pipeline ${DateTime.now().millisecondsSinceEpoch}';
    try {
      await logClientError('playback', sentinel);
      final j = await userErrors(q: sentinel, limit: 10);
      final rows = (j['errors'] as List?) ?? [];
      return rows.any((r) =>
          (r['message'] as String? ?? '').contains(sentinel) ||
          (r['title'] as String? ?? '').contains(sentinel));
    } catch (_) {
      return false;
    }
  }

  /// Send queued logs oldest-first; stops at the first failure (still
  /// offline) and keeps the rest. Posts straight at client-log (excluded
  /// from the _TimeoutClient net-error sink, so no recursion).
  Future<void> _flushQueuedLogs() async {
    List<String> q;
    try {
      final prefs = await SharedPreferences.getInstance();
      q = prefs.getStringList(_kLogQueue) ?? [];
      if (q.isEmpty) return;
    } catch (_) {
      return;
    }
    var failedAt = -1;
    for (var i = 0; i < q.length; i++) {
      Map<String, dynamic>? j;
      try {
        j = jsonDecode(q[i]) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      try {
        await _client
            .post(
              _uri('/api/client-log'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'kind': j['k'],
                'message': j['m'],
                'av': appVersion,
              }),
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        failedAt = i;
        break;
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      // Unparseable rows (skipped via continue) are dropped; unsent kept.
      await prefs.setStringList(
          _kLogQueue, failedAt < 0 ? <String>[] : q.sublist(failedAt));
    } catch (_) {}
  }

  Future<List<PlaylistInfo>> playlists() async {
    final j = _decode(
      await _client
          .get(_uri('/api/playlists'))
          .timeout(const Duration(seconds: 20)),
    );
    return (j['playlists'] as List? ?? [])
        .map((e) => PlaylistInfo.fromJson(e))
        .toList();
  }

  Future<PlaylistDetail> playlistEntries(String name) async {
    final j = _decode(
      await _client
          .get(_uri('/api/playlists/${Uri.encodeComponent(name)}'))
          .timeout(const Duration(seconds: 20)),
    );
    return PlaylistDetail(
      name: j['name'],
      entries: (j['entries'] as List? ?? [])
          .map((e) => PlaylistEntry.fromJson(e))
          .toList(),
      totalSeconds: (j['total_seconds'] as num?)?.toDouble(),
      source: (j['source'] ?? '').toString(),
    );
  }

  /// Remembered import link for a playlist ('' when never imported
  /// from a link). Powers verify-against-source + retry without asking.
  Future<String> playlistSource(String name) async {
    final j = _decode(
      await _client.get(_uri('/api/playlist-source', {'name': name})).timeout(
        const Duration(seconds: 20),
      ),
    );
    return (j['source'] ?? '').toString();
  }

  Future<void> createPlaylist(String name) async {
    _decode(
      await _client.post(
        _uri('/api/playlists'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': name}),
      ),
    );
  }

  /// Persist a new playlist display order (drag-reorder in the Library).
  Future<void> reorderPlaylists(List<String> order) async {
    _decode(
      await _client.put(
        _uri('/api/playlists'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'order': order}),
      ),
    );
  }

  Future<void> removeFromPlaylist(
    String name, {
    required String baseName,
  }) async {
    _decode(
      await _client.delete(
        _uri('/api/playlists/${Uri.encodeComponent(name)}/entries'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'base_name': baseName}),
      ),
    );
  }

  Future<void> deletePlaylist(String name) async {
    _decode(await _client
        .delete(_uri('/api/playlists/${Uri.encodeComponent(name)}')));
  }

  /// Rename a playlist (songs + cover + added-dates move along).
  Future<void> renamePlaylist(String name, String newName) async {
    _decode(
      await _client.post(
        _uri('/api/playlists/${Uri.encodeComponent(name)}/rename'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': newName}),
      ),
    );
  }

  /// Spotify playlist link -> its track order (title/artist/uri/duration,
  /// in sequence) via the public embed page. No auth needed server-side.
  /// full=true uses the anonymous web-player query: the WHOLE list with
  /// real added-dates (embed caps at 100), falling back to embed.
  Future<Map<String, dynamic>> spotifyPlaylistOrder(String url,
      {bool full = true}) async {
    return _decode(
      await _client.get(_uri('/api/spotify-playlist-order',
          {'url': url, if (full) 'full': '1'})),
    );
  }

  /// Rewrite a playlist's song order (match-Spotify-order). Entries not in
  /// [order] keep their relative order at the end. Returns the server counts.
  Future<Map<String, dynamic>> setPlaylistOrder(
    String name,
    List<String> order,
  ) async {
    return _decode(
      await _client.post(
        _uri('/api/playlists/${Uri.encodeComponent(name)}/order'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'order': order}),
      ),
    );
  }

  /// Create an account (username + password + verification). The server
  /// creates the private home folder — or adopts a pre-existing one the
  /// first time (owner claiming their tree). Throws ApiException:
  /// 400 validation, 409 name taken, 500 users storage not mounted.
  Future<AuthSession> register(
    String username,
    String password,
    String verify, {
    String deviceId = '',
    String deviceName = '',
    String invite = '',
  }) async {
    final j = _decode(
      await _client.post(
        _uri('/api/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
          'verify': verify,
          'device_id': deviceId,
          'device_name': deviceName,
          if (invite.isNotEmpty) 'invite': invite,
        }),
      ),
    );
    return AuthSession.fromJson(j);
  }

  /// Verify credentials → session token for this device. Throws
  /// ApiException (401 invalid username or password).
  Future<AuthSession> login(
    String username,
    String password, {
    String deviceId = '',
    String deviceName = '',
  }) async {
    final j = _decode(
      await _client.post(
        _uri('/api/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
          'device_id': deviceId,
          'device_name': deviceName,
        }),
      ),
    );
    return AuthSession.fromJson(j);
  }

  /// Who owns the current session token (null when invalid/expired).
  /// A 401 here means "show the login screen", not an error to surface.
  Future<String?> me() async {
    try {
      final j = _decode(await _client.get(_uri('/api/me')));
      final u = (j['username'] ?? '').toString();
      return u.isEmpty ? null : u;
    } on ApiException catch (e) {
      if (e.statusCode == 401) return null;
      rethrow;
    }
  }

  /// Revoke the current session token (best-effort; the local session is
  /// dropped regardless).
  Future<void> logout() async {
    try {
      await _client.post(_uri('/api/logout'));
    } catch (_) {
      // best-effort
    }
  }

  /// Change your own password (needs the current one). Other sessions are
  /// revoked; this one survives. Throws ApiException (401 wrong current).
  Future<void> changePassword(String current, String next) async {
    _decode(
      await _client.post(
        _uri('/api/password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'current_password': current,
          'new_password': next,
        }),
      ),
    );
  }

  /// Streaming URL for a discovery track. We prefer the DIRECT googlevideo
  /// URL: the phone (residential IP) reaches YouTube far faster than the NAS
  /// relay does (the NAS's datacenter path is throttled to ~5 KB/s, but the
  /// phone gets the same stream instantly). Falls back to the NAS relay
  /// (`/api/stream`) if the direct URL can't be resolved.
  Future<String> resolve(String videoId) async {
    try {
      final j = _decode(await _client.get(_uri('/api/resolve/$videoId')));
      final url = (j['url'] as String?) ?? '';
      // Rebuild relay URLs from our own base (server-minted host dies
      // on funnel/non-default ports — see relayUrl).
      if (url.contains('/staging/api/stream')) return relayUrl(videoId);
      if (url.isNotEmpty) return url;
    } catch (_) {
      // fall through to relay
    }
    return _tok('$_base/staging/api/stream?vid=$videoId');
  }

  /// Fire-and-forget warm-up: tell the server to resolve/cache this video's
  /// direct audio URL now, so the actual stream starts instantly later.
  /// Result is ignored; failures are silent (best-effort). Uses the
  /// timeout-capped client: a raw http.get with no timeout leaks a socket
  /// on every stall.
  Future<void> warm(String videoId) async {
    try {
      await _client.get(Uri.parse(_tok('$_base/staging/api/resolve/$videoId')));
    } catch (_) {
      // best-effort warm-up
    }
  }

  /// Absolute URL for playing a library file through the server.
  /// Path segments are percent-encoded (space, `'`, `,`, `()`, …) because
  /// Android's MediaPlayer will not encode them and the raw request line
  /// (with spaces) breaks the server's HTTP parsing → player timeout.
  String fileUrl(String relativeFileUrl) {
    final encoded = relativeFileUrl
        .split('/')
        .map((s) => s.isEmpty ? '' : Uri.encodeComponent(s))
        .join('/');
    return _tok('$_base$encoded');
  }

  /// Fire-and-forget NAS prewarm: warms TCP/TLS + file open so playOne's
  /// first Range GET answers progressively (206) instead of after full open.
  void prewarmFile(String url) {
    unawaited(
      http
          .get(Uri.parse(url), headers: const {'Range': 'bytes=0-65535'})
          .then<void>((_) {})
          .catchError((_, __) {}),
    );
  }

  /// Build a playable URL for a NAS file's relative path (as returned by
  /// the version picker's "On NAS" row), e.g. `Folder/song.mp3`.
  String nasFileUrl(String rel) {
    final r = rel.startsWith('/') ? rel.substring(1) : rel;
    return fileUrl('/staging/file/$r');
  }

  /// Album-art endpoint for a `/staging/file/...` or `/staging/pl/...` URL.
  String coverUrl(String fileRelUrl) {    String f;
    if (fileRelUrl.startsWith('/staging/file/')) {
      f = fileRelUrl.replaceFirst('/staging/file/', '');
    } else if (fileRelUrl.startsWith('/staging/pl/')) {
      f = 'pl:' + fileRelUrl.replaceFirst('/staging/pl/', '');
    } else if (fileRelUrl.startsWith('/staging/u/')) {
      f = 'u:' + fileRelUrl.replaceFirst('/staging/u/', '');
    } else {
      f = fileRelUrl;
    }
    return _tok('$_base/staging/api/cover?f=${Uri.encodeComponent(f)}');
  }

  /// Row art for a playlist entry: the server's direct CDN URL (ytimg /
  /// dzcdn) when known — the phone pulls it straight off the CDN instead
  /// of NAS-proxied bytes (proxy doubles the funnel uplink; N rows =
  /// N proxied fetches fighting the audio stream). Falls back to the
  /// proxied cover endpoint, so the Tailscale path is unchanged. '' =
  /// no art; callers fall back to gradients/playlist cover.
  String thumbFor(PlaylistEntry e) {
    final d = e.coverDirect;
    if (d != null && d.isNotEmpty) return d; // CDN needs no token
    return e.url != null ? coverUrl(e.url!) : '';
  }

  /// User-set playlist cover image URL (404 if none set).
  String playlistCoverUrl(String name) => _tok(
      '$_base/staging/api/cover?pl=${Uri.encodeComponent(name)}');

  /// Video thumbnail URL (YouTube art for a download row that has no
  /// staged file yet). 404 until the video id is known.
  String coverVidUrl(String videoId) => _tok(
      '$_base/staging/api/cover?vid=${Uri.encodeComponent(videoId)}');

  /// Fetch the cover image bytes for a library/playlist file (null if none).
  Future<Uint8List?> coverBytes(String fileRelUrl) async {
    final r = await _client.get(Uri.parse(coverUrl(fileRelUrl)));
    if (r.statusCode != 200 || r.bodyBytes.length < 64) return null;
    return r.bodyBytes;
  }

  /// Fetch raw bytes from an arbitrary http(s) URL (e.g. a user-pasted
  /// playlist-cover image). Returns null on any failure.
  Future<Uint8List?> fetchBytes(String url) async {
    try {
      final r = await _client.get(Uri.parse(url));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      return r.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// Owner-only developer viewer: per-user server error rows.
  Future<Map<String, dynamic>> userErrors(
      {String? user,
      String? section,
      String? q,
      int limit = 200,
      bool unseen = false}) async {
    final params = <String, String>{'limit': '$limit'};
    if (user != null && user.isNotEmpty) params['user'] = user;
    if (section != null && section.isNotEmpty) params['section'] = section;
    if (q != null && q.isNotEmpty) params['q'] = q;
    if (unseen) params['unseen'] = '1';
    return _decode(await _client.get(_uri('/api/user-errors', params)));
  }

  /// Flag user-error rows as seen (owner: any user; others: own only).
  Future<void> markUserErrorsSeen({String? user, List<int>? ids}) async {
    final body = <String, dynamic>{
      if (user != null && user.isNotEmpty) 'user': user,
      if (ids != null && ids.isNotEmpty) 'ids': ids,
    };
    final r = await _client.post(
      Uri.parse(_tok('$_base/staging/api/user-errors/seen')),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (r.statusCode == 401) _notifyAuthFailure();
    if (r.statusCode >= 400) throw ApiException(r.statusCode, r.body);
  }

  /// Upload raw image bytes as the playlist cover.
  Future<void> uploadPlaylistCover(String name, Uint8List bytes) async {
    final r = await _client.post(
      Uri.parse(_tok(
        '$_base/staging/api/playlists/${Uri.encodeComponent(name)}/cover',
      )),
      headers: {'Content-Type': 'image/jpeg'},
      body: bytes,
    );
    if (r.statusCode >= 400) {
      if (r.statusCode == 401) _notifyAuthFailure();
      throw ApiException(r.statusCode, r.body);
    }
  }

  /// Album/artist metadata for a library song, if we have it.
  Future<MetaInfo?> metainfo(String baseName) async {
    final j = _decode(
      await _client.get(_uri('/api/metainfo', {'base': baseName})),
    );
    return MetaInfo.fromJson(j);
  }

  /// Everything the artist page needs: all songs, album groups, singles.
  Future<ArtistPage> artist(String name) async {
    final j = _decode(
      await _client.get(_uri('/api/artist/${Uri.encodeComponent(name)}')),
    );
    return ArtistPage.fromJson(j);
  }

  /// Just an artist's photo URL (cheap, cached server-side).
  Future<String?> artistPhoto(String name) async {
    try {
      final j = _decode(
        await _client.get(_uri('/api/artist-photo', {'name': name})),
      );
      return j['photo'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// A single album's songs (downloaded + pending-to-download).
  Future<AlbumPage> album(String artist, String album, {int? albumId}) async {
    final j = _decode(
      await _client.get(
        _uri('/api/album', {
          if (artist.isNotEmpty) 'artist': artist,
          'album': album,
          if (albumId != null) 'album_id': '$albumId',
        }),
      ),
    );
    return AlbumPage.fromJson(j);
  }

  /// Whether the song is already liked / downloaded locally.
  Future<LikedStatus> likedStatus(String baseName) async {
    final j = _decode(
      await _client.get(_uri('/api/liked', {'base': baseName})),
    );
    return LikedStatus.fromJson(j);
  }

  /// ONE batch liked-status call per playlist open (newline-separated;
  /// base names may contain commas). Returns {base: liked}.
  Future<Map<String, bool>> likedBatch(List<String> bases) async {
    final want = bases.where((b) => b.isNotEmpty).take(500).toList();
    if (want.isEmpty) return {};
    final j = _decode(
      await _client.get(_uri('/api/liked', {'bases': want.join('\n')})),
    );
    final m = (j['liked'] as Map?) ?? {};
    return {for (final k in m.keys) k.toString(): m[k] == true};
  }

  /// Live suggestions while typing (online Deezer-style suggestions; the
  /// server returns provider-tagged rows that the app streams to play).
  /// 8s interactive cap: typeahead is best-effort, never a 30s stall.
  Future<List<Suggestion>> suggest(String q) async {
    final j = _decode(await _client
        .get(_uri('/api/suggest', {'q': q}))
        .timeout(const Duration(seconds: 8)));
    return (j['results'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(Suggestion.fromJson)
        .toList();
  }

  /// Related internet songs for a track (Spotify/YouTube-Music "up next"
  /// autoplay). The app resolves + streams each row like a suggestion.
  /// [limit] requests a bigger batch from the server; [exclude] sends the
  /// normalized titles the app already has so a refill for the SAME seed
  /// returns FRESH rows (endless-scroll — not the same 15 recycled).
  Future<List<Suggestion>> radio(
    String artist,
    String title, {
    int? limit,
    List<String>? exclude,
  }) async {
    final j = _decode(
      await _client.get(_uri('/api/radio', {
        'artist': artist,
        'title': title,
        if (limit != null) 'limit': '$limit',
        if (exclude != null && exclude.isNotEmpty)
          'exclude': exclude.join(','),
      })),
    );
    return (j['results'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(Suggestion.fromJson)
        .toList();
  }

  /// Spotify-powered multi-source recommendations: genre, similar artists,
  /// mood, cross-artist discovery. Server uses Spotify /v1/recommendations
  /// with Deezer related-artists as seeds. [limit]/[exclude] as [radio].
  Future<List<Suggestion>> recommend(
    String artist,
    String title, {
    int? limit,
    List<String>? exclude,
  }) async {
    final j = _decode(
      await _client.get(
        _uri('/api/recommend', {
          'artist': artist,
          'title': title,
          if (limit != null) 'limit': '$limit',
          if (exclude != null && exclude.isNotEmpty)
            'exclude': exclude.join(','),
        }),
      ),
    );
    return (j['results'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(Suggestion.fromJson)
        .toList();
  }

  /// Is this artist+title already on the NAS? (bug O — prefer the local copy
  /// over streaming.) Server-side cached, so it is cheap to call per row.
  Future<InNasHit> inNas({
    required String artist,
    required String title,
  }) async {
    final j = _decode(
      await _client
          .get(_uri('/api/innas', {'artist': artist, 'title': title}))
          .timeout(const Duration(seconds: 8)),
    );
    return InNasHit.fromJson(j);
  }

  /// Full flat NAS library (music + staging + playlists) for client-side
  /// fuzzy "is this queued song already on the NAS?" matching. Cached
  /// server-side by _suggest_index (60 s TTL) so it's cheap to refresh.
  Future<List<Map<String, dynamic>>> nasIndex() async {
    final j = _decode(
      await _client.get(_uri('/api/nas-index', {})),
    );
    return (j['tracks'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  /// Ask the server to verify every downloaded track against its studio
  /// (Spotify/Deezer) original, and return the current scan snapshot.
  ///
  /// [scope] limits the scan: ''/'library' = whole library,
  /// 'playlist:<name>' = one playlist, 'song:<query>' = one song.
  /// [poll] = true: read the current snapshot WITHOUT starting/restarting a
  /// scan (used by the progress poller so it can't kick a new scan each tick).
  Future<CheckSongsStatus> checkSongs(
      {String? scope, bool poll = false}) async {
    final j = _decode(await _client.get(
      _uri('/api/checksongs', {
        if (scope != null && scope.isNotEmpty) 'scope': scope,
        if (poll) 'poll': '1',
      }),
    ));
    return CheckSongsStatus.fromJson(j);
  }

  /// Scan every NAS song's lyrics against the provider (LRC Lib /
  /// lyrics.ovh). Flags ok / none (no lyrics) / mismatch (wrong song's
  /// lyrics). Returns the current snapshot; poll it while running.
  ///
  /// [scope] limits the scan: ''/'library' = whole library,
  /// 'playlist:<name>' = one playlist, 'song:<query>' = one song.
  /// [poll] = true: read the current snapshot WITHOUT starting/restarting a
  /// scan (used by the progress poller so it can't kick a new scan each tick).
  Future<LyricsStatus> checkLyrics(
      {String? scope, bool poll = false}) async {
    final j = _decode(await _client.get(
      _uri('/api/check-lyrics', {
        if (scope != null && scope.isNotEmpty) 'scope': scope,
        if (poll) 'poll': '1',
      }),
    ));
    return LyricsStatus.fromJson(j);
  }

  /// Diagnostics report for the artist-photo pipeline (Spotify creds test +
  /// what Spotify/Deezer return for [artist]). Returns the raw JSON so the
  /// Settings screen can render/export it.
  Future<Map<String, dynamic>> diagnostics(String artist) async {
    return _decode(
      await _client.get(_uri('/api/diagnostics', {'name': artist})),
    );
  }

  /// Version picker data for a flagged file: current/expected duration, the
  /// reason it was flagged, Deezer versions (studio first) + Spotify ref.
  Future<SongVersions> songVersions(String baseName) async {
    final j = _decode(
      await _client.get(_uri('/api/song-versions', {'f': baseName})),
    );
    return SongVersions.fromJson(j);
  }

  /// Replace a flagged NAS copy with another version, preserving the
  /// original's metadata. Returns the replacement job id for polling.
  /// [versionDuration]/[versionExplicit] identify the exact tapped version
  /// so the server downloads that cut (explicit vs clean, length) instead
  /// of re-converging on the same top search pick every retry.
  /// Bulk import a track list into a NAS playlist (server downloads each
  /// in order, one background worker). Returns {started, total}.
  Future<Map<String, dynamic>> importStart(
    String name,
    List<Map<String, String>> tracks, {
    String cover = '',
    String source = '',
  }) async {
    return _decode(
      await _client.post(
        _uri('/api/import'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': name,
          'tracks': tracks,
          if (cover.isNotEmpty) 'cover': cover,
          if (source.isNotEmpty) 'source': source,
        }),
      ),
    );
  }

  /// Import progress: {running, playlist, total, done, failed}.
  Future<Map<String, dynamic>> importStatus() async {
    return _decode(await _client.get(_uri('/api/import')));
  }

  /// Batch import: many playlists in ONE request (one rate-limit hit).
  /// The server runs them in order with the app closed. Shape:
  /// {playlists: [{name, tracks: [{artist, title}]}]}.
  Future<Map<String, dynamic>> importBatch(
    List<Map<String, dynamic>> playlists,
  ) async {
    return _decode(
      await _client.post(
        _uri('/api/import'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'playlists': playlists}),
      ),
    );
  }

  /// Published events: Wrapped season flag + notification cards.
  Future<Map<String, dynamic>> announcements() async {
    return _decode(await _client.get(_uri('/api/announcements')));
  }

  /// Owner-only: broadcast a card to all devices. Optional url opens on tap.
  Future<Map<String, dynamic>> publishAnnouncement(
    String title,
    String body, [
    String url = '',
  ]) async {
    return _decode(
      await _client.post(
        _uri('/api/announcements'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'title': title,
          'body': body,
          if (url.isNotEmpty) 'url': url,
        }),
      ),
    );
  }

  /// Owner-only: remove all broadcast cards.
  Future<void> clearAnnouncements() async {
    _decode(await _client.delete(_uri('/api/announcements')));
  }

  /// Direct download URL for the latest APK (tap-to-update target).
  String get apkUrl => '$serverBase/staging/app.apk';

  /// Owner-only: flip the automatic app-update notices kill switch.
  Future<bool> setAppUpdates(bool enabled) async {
    final j = _decode(
      await _client.post(
        _uri('/api/announcements'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'app_updates': enabled}),
      ),
    );
    return j['app_updates'] == true;
  }

  /// YouTube login (TV device flow): start -> {url, user_code},
  /// poll until approved. Tokens stay per-user on the server.
  Future<Map<String, dynamic>> ytmAuthStart() async {
    return _decode(await _client.post(_uri('/api/ytm-auth-start')));
  }

  Future<Map<String, dynamic>> ytmAuthPoll() async {
    return _decode(await _client.get(_uri('/api/ytm-auth-poll')));
  }

  Future<Map<String, dynamic>> ytmAuthStatus() async {
    return _decode(await _client.get(_uri('/api/ytm-auth-status')));
  }

  Future<void> ytmAuthLogout() async {
    _decode(await _client.delete(_uri('/api/ytm-auth')));
  }

  /// Store a pasted browser login (curl of an authed youtubei/v1/browse
  /// request) as this user's YouTube credential. Fallback when Google
  /// rejects TV-client library calls.
  Future<Map<String, dynamic>> ytmCookie(String curl) async {
    return _decode(
      await _client.post(
        _uri('/api/ytm-cookie'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'curl': curl}),
      ),
    );
  }

  /// Authed YTM library: {playlists:[{id,name,total}], liked:N}
  /// (private included — 401 when logged out).
  Future<Map<String, dynamic>> ytmLibrary() async {
    return _decode(await _client.get(_uri('/api/ytm-library')));
  }

  /// Full track order [{artist,title}] for a library playlist id
  /// (or 'liked' for Liked Songs).
  Future<Map<String, dynamic>> ytmLibraryPlaylist(String id) async {
    final j = _decode(
        await _client.get(_uri('/api/ytm-library-playlist', {'id': id})));
    return {
      'tracks': (j['tracks'] as List? ?? []),
      'cover': (j['cover'] ?? '').toString(),
    };
  }

  /// Public channel (@handle, name, or UC id) -> its playlists
  /// {channel, channel_id, playlists:[{id,name,subtitle}]}. No login.
  Future<Map<String, dynamic>> ytmChannel(String q) async {
    return _decode(await _client.get(_uri('/api/ytm-channel', {'q': q})));
  }

  /// YouTube Music playlist link -> [{artist, title, duration_s}] in order
  /// (public playlists; private ones fail with a clear message).
  Future<Map<String, dynamic>> ytmusicPlaylist(String url) async {
    return _decode(
      await _client.get(_uri('/api/ytmusic-playlist', {'url': url})),
    );
  }

  Future<String> checkReplace(
    String baseName,
    String versionArtist,
    String versionTitle, {
    int? versionDuration,
    bool? versionExplicit,
    String? versionImage,
  }) async {
    final j = _decode(
      await _client.post(
        _uri('/api/check-replace'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'base_name': baseName,
          'version_artist': versionArtist,
          'version_title': versionTitle,
          if (versionDuration != null) 'version_duration': versionDuration,
          if (versionExplicit != null) 'version_explicit': versionExplicit,
          if (versionImage != null && versionImage.isNotEmpty)
            'version_image': versionImage,
        }),
      ),
    );
    return (j['id'] ?? '').toString();
  }

  /// Fingerprint a NAS file and return what the audio ACTUALLY is
  /// (Chromaprint/AcoustID). Needs ACOUSTID_API_KEY + fpcalc on the server.
  Future<Map<String, dynamic>> identify(String baseName) async {
    return _decode(await _client.get(_uri('/api/identify', {'f': baseName})));
  }

  /// Find + resolve a track by artist/title (internet; used by the career
  /// and album pages for songs not on the NAS yet).
  Future<ResolvedName> resolveByName({
    required String artist,
    required String title,
    int maxTries = 60,
    Duration pollWait = const Duration(milliseconds: 400),
  }) async {
    // Cold hits run a SHARED background job on the server (so taps never
    // block on yt-dlp) and return {"status":"pending"} until its 14-day cache
    // is filled. Poll a bounded number of times, then give up cleanly.
    for (var n = 0; ; n++) {
      Map<String, dynamic> j;
      try {
        j = _decode(
          await _client.get(
            _uri('/api/resolvename', {'artist': artist, 'title': title}),
          ),
        );
      } catch (_) {
        throw ApiException(502, 'resolve failed');
      }
      if (j['status'] != 'pending') {
        final r = ResolvedName.fromJson(j);
        // Relay stream URLs pass the multi-user gate ONLY with ?token=
        // (players/<audio> tags can't set headers). Rebuild from our OWN
        // base: the server-minted URL hardcodes http:// + bare host, which
        // 404s (port 80) whenever the app uses the funnel URL or any
        // non-default port. Single choke point for all internet playback
        // (main queue, version-picker previews, deep links). Direct
        // googlevideo URLs are untouched.
        final url = r.url.contains('/staging/api/stream') &&
                r.videoId.isNotEmpty
            ? relayUrl(r.videoId)
            : r.url.contains('/staging/api/stream')
                ? _tok(r.url)
                : r.url;
        return ResolvedName(
          url: url,
          videoId: r.videoId,
          thumb: r.thumb,
          artist: r.artist,
          title: r.title,
          resolvedArtist: r.resolvedArtist,
          resolvedTitle: r.resolvedTitle,
        );
      }
      if (n >= maxTries) throw ApiException(504, 'resolve timed out');
      await Future<void>.delayed(pollWait);
    }
  }

  /// Identity of a song opened from a Spotify / YT-Music share link. The
  /// server parses the link (kind: youtube → video_id; spotify → artist+title)
  /// and the caller then streams it like any internet track.
  Future<OpenLink> openUrl(String url) async {
    final j = _decode(
      await _client.get(_uri('/api/open-url', {'url': url})),
    );
    return OpenLink.fromJson(j);
  }

  /// A real `open.spotify.com/track/<id>` URL for artist+title, so a shared
  /// Spotify link AUTOPLAYS (the server mirrors the web player's search). Falls
  /// back to the server's search URL, and to '' if the call fails entirely.
  Future<String> spotifyLink({
    required String artist,
    required String title,
  }) async {
    try {
      final j = _decode(
        await _client.get(
          _uri('/api/spotify-link', {'artist': artist, 'title': title}),
        ),
      );
      return (j['url'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  /// Remove the playlist cover (falls back to gradient art).
  Future<void> deletePlaylistCover(String name) async {
    final r = await _client.delete(
      Uri.parse(_tok(
        '$_base/staging/api/playlists/${Uri.encodeComponent(name)}/cover',
      )),
    );
    if (r.statusCode >= 400) {
      if (r.statusCode == 401) _notifyAuthFailure();
      throw ApiException(r.statusCode, r.body);
    }
  }

  /// Relay stream URL built from OUR OWN working base (never trust the
  /// server-minted one: it hardcodes http:// + a bare host, which dies
  /// (port 80/404) when the app talks to the server over the funnel URL
  /// or any non-default port — instant player-error, zero server trace).
  String relayUrl(String videoId) =>
      _tok('$serverBase/staging/api/stream?vid=$videoId');

  /// YouTube thumbnail proxied through the server (for discovery tracks).
  String thumbUrl(String videoId) =>
      _tok('$_base/staging/api/cover?vid=$videoId');

  /// Any external image proxied through the server (Wrapped artist
  /// photos). Direct CDN bytes often fail on the phone; the server
  /// fetches with a browser UA and caches. Token attached like the rest.
  String imageProxy(String raw) =>
      _tok('$_base/staging/api/cover?u=${Uri.encodeComponent(raw)}');

  /// Lyrics for a track: synced (position-synced karaoke lines) when the
  /// server had an LRC source, plain lines otherwise.
  Future<LyricsData?> lyrics(String baseName) async {
    try {
      final j = _decode(
        await _client.get(_uri('/api/lyrics', {'base': baseName})),
      );
      return LyricsData.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  /// Lyrics for an explicitly-resolved identity (artist + title) — used for
  /// internet queue items whose actual audio is a specific YouTube video, so
  /// the lyrics match what is really playing, not the discovery identity.
  Future<LyricsData?> lyricsBy(String artist, String title) async {
    try {
      final j = _decode(
        await _client.get(
          _uri('/api/lyrics', {
            'base': '$artist - $title',
            'artist': artist,
            'title': title,
          }),
        ),
      );
      return LyricsData.fromJson(j);
    } catch (_) {
      return null;
    }
  }
}

/// Bumped whenever a playlist cover is uploaded/deleted so cached images
/// with the same URL stop showing the old picture.
final ValueNotifier<int> coverRevNotifier = ValueNotifier(0);
