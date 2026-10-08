import 'package:flutter/material.dart';

import '../api_client.dart';
import '../lang.dart';
import '../queue_player.dart';
import '../song_context.dart';
import '../theme.dart';
import '../toast.dart';
import '../widgets.dart';

/// Spotify-style album page: one album's full track list.
class AlbumScreen extends StatefulWidget {
  const AlbumScreen({
    super.key,
    required this.api,
    required this.artist,
    required this.album,
    this.albumId,
    this.coverImage,
  });
  final ApiClient api;
  final String artist;
  final String album;
  final int? albumId;
  final String? coverImage;

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  AlbumPage? _page;
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
      resolveName: (artist: widget.artist, title: title),
      lyricsArtist: widget.artist,
      lyricsTitle: title,
    );
  }

  QueueItem? _lazyRow(ArtistSong s) {
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
      resolveName: (artist: widget.artist, title: title),
      lyricsArtist: widget.artist,
      lyricsTitle: title,
    );
  }

  /// Like Spotify: tap a track, it plays now and the rest of the album keeps
  /// playing after it. Downloaded tracks come from the NAS, the others stream.
  /// Only the tapped track is resolved up front; the rest resolve lazily as
  /// they come up (so the tap starts instantly, no whole-queue waiting).
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
      final queue = <QueueItem>[];
      QueuePlayer.instance.wireTapResolvers(widget.api);
      for (final s in songs) {
        if (s == tapped) {
          queue.add(first);
          continue;
        }
        final r = _lazyRow(s);
        if (r != null) queue.add(r);
      }
      if (queue.isEmpty) return;
      await QueuePlayer.instance.playList(
        queue,
        startIndex: queue.indexOf(first),
      );
    } finally {
      _preparing.remove(tapped.baseName);
      if (mounted) setState(() {});
    }
  }

  /// The server caches album tracklists in a background hydrate job. A cold
  /// album reply can arrive before that job lands, so keep re-polling briefly
  /// (same pattern as the artist page) until we get songs instead of forcing
  /// the user to leave and re-enter.
  Future<void> _load({int maxSeconds = 30}) async {
    setState(() {
      _loading = true;
      _error = '';
    });
    final stopwatch = Stopwatch()..start();
    var n = 0;
    while (mounted && stopwatch.elapsed.inSeconds < maxSeconds) {
      try {
        final page = await widget.api.album(
          widget.artist,
          widget.album,
          albumId: widget.albumId,
        );
        if (!mounted) return;
        if (!page.songs.isEmpty || stopwatch.elapsed.inSeconds >= 2) {
          setState(() {
            _page = page;
            _loading = false;
          });
          return;
        }
      } catch (e) {
        if (!mounted) return;
        if (stopwatch.elapsed.inSeconds >= 2) {
          setState(() {
            _loading = false;
            _error = e.toString();
          });
          return;
        }
      }
      n++;
      await Future<void>.delayed(
        Duration(milliseconds: n == 1 ? 300 : (n <= 5 ? 500 : 1000)),
      );
    }
    setState(() {
      _loading = false;
    });
  }

  Future<void> _playAll() => _playFrom(0);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.album)),
      bottomNavigationBar: const MiniPlayerBar(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
          ? Center(child: Text(_error))
          : _page == null || _page!.songs.isEmpty
          ? Center(
              child: Text(
                tr('No tracks.'),
                style: TextStyle(color: Colors.white54),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _header(_page!),
                for (var i = 0; i < _page!.songs.length; i++)
                  _trackTile(_page!.songs[i], i),
              ],
            ),
    );
  }

  Widget _header(AlbumPage page) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CoverArt(
                seed: page.album,
                icon: Icons.album,
                networkUrl: widget.coverImage ?? page.image,
                size: 96,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      page.album,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      page.artist ?? widget.artist,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      fmtTracks(page.songs.length),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
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
                tr('Play'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const Divider(height: 24, color: Colors.white12),
        ],
      ),
    );
  }

  Widget _trackTile(ArtistSong s, int i) {
    final exists = s.exists;
    final preparing = _preparing.contains(s.baseName);
    final feat =
        (s.artist != null && s.artist!.isNotEmpty && s.artist != widget.artist)
        ? s.artist!
        : null;
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
                  widget.coverImage ??
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
                  ? (feat != null ? feat : '')
                  : "${tr('stream from internet')}${feat != null ? " · $feat" : ""}",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white38),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isCurrent)
                  Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.graphic_eq, color: Spots.green, size: 16),
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
                else
                  IconButton(
                    icon: Icon(
                      Icons.play_arrow,
                      color: exists ? null : Spots.green,
                    ),
                    tooltip: exists ? null : tr('Stream from internet'),
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
