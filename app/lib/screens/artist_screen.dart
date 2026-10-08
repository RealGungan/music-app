import 'package:flutter/material.dart';

import '../api_client.dart';
import '../lang.dart';
import '../queue_player.dart';
import '../song_context.dart';
import '../theme.dart';
import '../toast.dart';
import '../widgets.dart';
import 'album_screen.dart';

/// Spotify-style artist page: all this artist's songs, albums and singles.
class ArtistScreen extends StatefulWidget {
  const ArtistScreen({super.key, required this.api, required this.name});
  final ApiClient api;
  final String name;

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  ArtistPage? _page;
  final Set<String> _preparing = {};
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _titleOf(String baseName) {
    final i = baseName.indexOf(' - ');
    return i > 0 ? baseName.substring(i + 3) : baseName;
  }

  /// Sync: NAS file rows play directly; online rows are lazy placeholders
  /// (the engine resolves NAS-first bounded, then streams). NO network
  /// await — the tap plays instantly and never parks (bounded auto-skip).
  QueueItem? _streamItem(ArtistSong s) {
    if (s.exists && s.url != null) {
      return QueueItem(
        s.baseName,
        widget.api.fileUrl(s.url!),
        thumbUrl: widget.api.coverUrl(s.url!),
      );
    }
    final title = _titleOf(s.baseName);
    if (title.isEmpty) return null;
    return QueueItem(
      s.baseName,
      '',
      resolveName: (artist: widget.name, title: title),
      lyricsArtist: widget.name,
      lyricsTitle: title,
    );
  }

  Future<void> _load() async {
    setState(() {
      // Keep the old page visible on refresh: only the first load spins.
      _loading = _page == null;
      _error = '';
    });
    try {
      final page = await widget.api
          .artist(widget.name)
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() {
        _page = page;
        _loading = false;
      });
      // Cold artist: the server returns local songs + cached parts instantly
      // and hydrates the rest in a background job. Songs/albums render NOW;
      // a photo-only remainder fills in async via the cheap photo endpoint
      // instead of holding the page in "Loading".
      if (page.pending) {
        _pollArtist();
        if (page.photo == null) _pollPhoto();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // A hung request must never blank an already-painted page.
        if (_page == null) _error = e.toString();
      });
    }
  }

  /// Re-fetches the artist page while the server flagged it "pending"
  /// (background hydration still warming its caches). Paints every content
  /// update immediately so songs/albums never wait on the photo; a
  /// photo-only remainder is left to [_pollPhoto] instead of spinning here
  /// forever (a missing photo stays null server-side indefinitely).
  Future<void> _pollArtist({int maxSeconds = 45}) async {
    final stopwatch = Stopwatch()..start();
    var n = 0;
    while (mounted && stopwatch.elapsed.inSeconds < maxSeconds) {
      await Future<void>.delayed(
        Duration(milliseconds: n == 0 ? 300 : (n <= 5 ? 500 : 1000)),
      );
      if (!mounted) return;
      try {
        final page = await widget.api
            .artist(widget.name)
            .timeout(const Duration(seconds: 20));
        if (!mounted) return;
        if (!page.pending) {
          setState(() {
            _page = page;
            _loading = false;
          });
          return;
        }
        // Content landed but only the photo is still pending: paint the
        // content now, let _pollPhoto chase the photo cheaply.
        if (page.photoOnlyPending &&
            (page.songs.isNotEmpty ||
                page.albums.isNotEmpty ||
                page.singles.isNotEmpty)) {
          setState(() {
            _page = page;
            _loading = false;
          });
          return;
        }
      } catch (_) {
        // Transient failure: keep polling rather than leaving an empty page.
      }
      n++;
    }
  }

  /// Photo-only catch-up: polls the cheap photo endpoint and paints the
  /// header image when it lands. Never touches songs/albums.
  Future<void> _pollPhoto({int tries = 10}) async {
    for (var i = 0; i < tries; i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!mounted || _page?.photo != null) return;
      try {
        final p = await widget.api
            .artistPhoto(widget.name)
            .timeout(const Duration(seconds: 10));
        if (!mounted) return;
        if (p != null && p.isNotEmpty) {
          setState(() => _page = _page?.withPhoto(p));
          return;
        }
      } catch (_) {
        // Best-effort: the fallback avatar stays until the photo exists.
      }
    }
  }

  QueueItem? _lazyRow(ArtistSong s) {
    // Local files play directly; online rows get a resolveName placeholder so
    // the queue resolves them lazily instead of blocking the whole album.
    if (s.exists && s.url != null) {
      return QueueItem(
        s.baseName,
        widget.api.fileUrl(s.url!),
        thumbUrl: widget.api.coverUrl(s.url!),
      );
    }
    final title = _titleOf(s.baseName);
    if (title.isEmpty) return null;
    return QueueItem(
      s.baseName,
      '',
      resolveName: (artist: widget.name, title: title),
      lyricsArtist: widget.name,
      lyricsTitle: title,
    );
  }

  /// Like Spotify: tap a song, it plays now and the infinite queue
  /// (related tracks via autoplay) fills up behind it — NOT the whole
  /// NAS song list of this page. Only the tapped song is resolved up
  /// front so the tap starts instantly, no whole-queue waiting.
  Future<void> _playFrom(int idx) async {
    final songs = _page?.songs ?? const <ArtistSong>[];
    if (songs.isEmpty || idx >= songs.length) return;
    final tapped = songs[idx];
    if (_preparing.contains(tapped.baseName)) return;
    _preparing.add(tapped.baseName);
    setState(() {});
    try {
      final first = _streamItem(tapped);
      if (first == null) {
        if (mounted) {
          toast(
            context,
            "${tr('Could not stream')} \"${tapped.baseName}\"",
            icon: Icons.error_outline,
          );
        }
        return;
      }
      QueuePlayer.instance.wireTapResolvers(widget.api);
      // Single-item start: autoplay's related-source refill tops the queue
      // back up to the keep-ahead horizon (infinite queue), instead of
      // pre-filling it with this artist's finite NAS list.
      await QueuePlayer.instance.playOne(first);
    } finally {
      _preparing.remove(tapped.baseName);
      if (mounted) setState(() {});
    }
  }

  Future<void> _playAll() => _playFrom(0);

  void _openAlbum(ArtistAlbum a) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AlbumScreen(
          api: widget.api,
          artist: a.albumArtist ?? widget.name,
          album: a.album,
          albumId: a.albumId,
          coverImage: a.image,
        ),
      ),
    );
  }

  Widget _albumTile(ArtistAlbum a) {
    final total = a.tracks;
    final owned = a.owned > total ? total : (a.owned < 0 ? 0 : a.owned);
    final subtitle = '$owned/$total';
    return ListTile(
      leading: CoverThumb(
        title: a.album,
        thumbUrl: a.image,
        size: 44,
        fallbackUrl: null,
      ),
      title: Text(a.album, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
      onTap: () => _openAlbum(a),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      bottomNavigationBar: const MiniPlayerBar(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
          ? Center(child: Text(_error))
          : _page == null
          ? Center(
              child: Text(
                tr('Nothing found.'),
                style: TextStyle(color: Colors.white54),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _header(_page!),
                // Pending shimmer only while there is NO content yet. Once
                // songs/albums paint, a photo-only remainder must not hold
                // a "Loading" banner over the page (photo fills in async).
                if (_page!.pending &&
                    _page!.songs.isEmpty &&
                    _page!.albums.isEmpty &&
                    _page!.singles.isEmpty) ...[
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 10),
                        Text(
                          tr('Loading songs & albums…'),
                          style: TextStyle(fontSize: 13, color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (_page!.songs.isNotEmpty)
                  ExpansionTile(
                    initiallyExpanded: true,
                    tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                    childrenPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.queue_music_rounded,
                      color: Colors.white54,
                    ),
                    title: Text(
                      "${tr('Songs')}  ·  ${_page!.songs.length}",
                      style: const TextStyle(
                        fontSize: 13,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w700,
                        color: Colors.white54,
                      ),
                    ),
                    children: [
                      for (var i = 0; i < _page!.songs.length; i++)
                        _songTile(_page!.songs[i], i),
                    ],
                  ),
                if (_page!.albums.isNotEmpty) ...[
                  _section(tr('Albums'), _page!.albums.length),
                  for (final a in _page!.albums.where((a) => a.type == 'album'))
                    _albumTile(a),
                  const SizedBox(height: 8),
                ],
                if (_page!.albums.where((a) => a.type == 'ep').isNotEmpty) ...[
                  _section(
                    tr('EPs'),
                    _page!.albums.where((a) => a.type == 'ep').length,
                  ),
                  for (final a in _page!.albums.where((a) => a.type == 'ep'))
                    _albumTile(a),
                  const SizedBox(height: 8),
                ],
                if (_page!.albums
                    .where((a) => a.type == 'single')
                    .isNotEmpty) ...[
                  _section(
                    tr('Singles'),
                    _page!.albums.where((a) => a.type == 'single').length,
                  ),
                  for (final a in _page!.albums.where(
                    (a) => a.type == 'single',
                  ))
                    _albumTile(a),
                ],
                if (_page!.singles.isNotEmpty) ...[
                  _section(tr('Other songs'), _page!.singles.length),
                  for (var i = 0; i < _page!.singles.length; i++)
                    _songTile(_page!.singles[i], i),
                ],
              ],
            ),
    );
  }

  Widget _avatarFallback(ArtistPage page) {
    return Container(
      width: 86,
      height: 86,
      decoration: BoxDecoration(
        gradient: Spots.coverGradient(page.name),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.person, size: 46, color: Colors.white70),
    );
  }

  Widget _header(ArtistPage page) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: page.photo != null
                    ? Image.network(
                        page.photo!,
                        width: 86,
                        height: 86,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _avatarFallback(page),
                      )
                    : _avatarFallback(page),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      page.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tr('Artist'),
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FloatingActionButton(
                heroTag: null,
                mini: true,
                backgroundColor: Spots.green,
                onPressed: _page!.songs.isNotEmpty ? _playAll : null,
                child: const Icon(
                  Icons.play_arrow,
                  size: 28,
                  color: Colors.black,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                tr('Play all'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (_page!.songs.any((s) => !s.exists))
                Text(
                  '  ${tr('(missing ones stream)')}',
                  style: TextStyle(fontSize: 12, color: Colors.white38),
                ),
            ],
          ),
          const Divider(height: 24, color: Colors.white12),
        ],
      ),
    );
  }

  Widget _section(String t, int n) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Text(
      '$t  ·  $n',
      style: const TextStyle(
        fontSize: 13,
        letterSpacing: 1.1,
        fontWeight: FontWeight.w700,
        color: Colors.white54,
      ),
    ),
  );

  Widget _songTile(ArtistSong s, int i) {
    final exists = s.exists;
    final preparing = _preparing.contains(s.baseName);
    return ValueListenableBuilder<String>(
      valueListenable: QueuePlayerShim.instance.title,
      builder: (context, currentTitle, _) {
        final isCurrent = exists && currentTitle == s.baseName;
        final lazy = _lazyRow(s);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: lazy == null
              ? null
              : () {
                  if (lazy.resolveName != null) {
                    QueuePlayer.instance.wireTapResolvers(widget.api);
                  }
                  showSongLongPressMenu(
                    context,
                    api: widget.api,
                    queueItem: lazy,
                    baseNameForPlaylist: s.baseName,
                    queued: !exists,
                  );
                },
          child: ListTile(
            leading: CoverThumb(
              title: s.baseName,
              thumbUrl:
                  s.albumImage ??
                  (s.url != null ? widget.api.coverUrl(s.url!) : null),
              size: 44,
            ),
            title: Text(
              s.title ?? _titleOf(s.baseName),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: isCurrent
                  ? TextStyle(color: Spots.green, fontWeight: FontWeight.w700)
                  : null,
            ),
            subtitle: Text(
              exists
                  ? '${s.album ?? ''}'
                  : "${tr('stream from internet')} · ${s.album ?? ''}",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: exists ? null : Colors.white54),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isCurrent)
                  Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.graphic_eq, color: Spots.green, size: 16),
                  ),
                // Person opens the ROW's artist (s.artist), never the song
                // title (e.g. "BULLSHIT 3" is a song, not an artist page).
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.person_outline, size: 20),
                  tooltip: tr('Artist'),
                  onPressed: () {
                    final a = (s.artist ?? '').trim();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ArtistScreen(
                          api: widget.api,
                          name: a.isNotEmpty ? a : widget.name,
                        ),
                      ),
                    );
                  },
                ),
                if (s.durationS != null)
                  Text(
                    fmtClock(s.durationS!),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (preparing)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (exists)
                  IconButton(
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () => _playFrom(i),
                  )
                else
                  IconButton(
                    icon: Icon(Icons.play_arrow, color: Spots.green),
                    tooltip: tr('Stream from internet'),
                    onPressed: () => _playFrom(i),
                  ),
              ],
            ),
            onTap: () => _playFrom(i),
          ),
        );
      },
    );
  }
}
