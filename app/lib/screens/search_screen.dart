import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../auth_store.dart';
import '../history.dart';
import '../keep_dialog.dart';
import '../lang.dart';
import '../meta_cache.dart';
import '../queue/text_norm.dart';
import '../queue_player.dart';
import '../song_context.dart';
import '../theme.dart';
import '../toast.dart';
import '../widgets.dart';
import 'artist_screen.dart';
import 'album_screen.dart';
import 'library_screen.dart' show offlineBanner;

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

/// Song-vs-group detect: a row counts as a SONG when it is structured
/// (explicit artist + title, or an "Artist - Title" base name); a bare
/// name is an artist/group. Songs always sort above artists/groups.
bool isSongRow(
    {String? artist, String? title, String? baseName, String? kind}) {
  if (kind != null && kind != 'song' && kind != 'local' && kind != 'virtual') {
    return false;
  }
  if ((artist ?? '').trim().isNotEmpty && (title ?? '').trim().isNotEmpty) {
    return true;
  }
  return (baseName ?? '').contains(' - ');
}

/// Duration clock that never drops: unknown/zero renders as –:–– so the
/// artist · album · duration triple stays complete on every row.
String durOrDash(int? s) => (s != null && s > 0) ? fmtClock(s) : '–:––';

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  SearchResultPage? _results;
  List<Suggestion> _suggests = [];
  Timer? _debounce;
  int _suggestSeq = 0;
  bool _loading = false;
  bool _resolving = false;
  String _error = '';
  List<String> _recent = [];
  // Single-flight guard: a double-tap (or tap-then-resume race) bumps this;
  // stale taps bail at every await instead of clobbering the winner.
  int _tapId = 0;

  @override
  void initState() {
    super.initState();
    AppHistory.loadSearch().then((l) {
      if (mounted) setState(() => _recent = l);
    });
  }

  void _runSearch(String q) {
    FocusScope.of(context).unfocus();
    if (q.trim().isNotEmpty) {
      AppHistory.recordSearch(q.trim());
      setState(() {
        _recent.removeWhere((x) => x == q.trim());
        _recent.insert(0, q.trim());
      });
    }
    _search(q);
  }

  void _onChanged(String v) {
    setState(() {
      _results = null;
      _error = '';
      _suggests = [];
    });
    _debounce?.cancel();
    if (v.trim().isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      final seq = ++_suggestSeq;
      try {
        final r = await widget.api.suggest(v.trim());
        if (!mounted || seq != _suggestSeq) return;
        setState(() => _suggests = _songsFirst(r));
      } catch (_) {
        // ignore transient failures; suggestions are best-effort
      }
    });
  }

  Future<void> _search([String? q]) async {
    _debounce?.cancel();
    final query = (q ?? _controller.text).trim();
    if (query.isEmpty) {
      setState(() {
        _results = null;
        _suggests = [];
        _error = '';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    // Offline fast path: cached library rows, no 30s network stall.
    if (QueuePlayer.instance.isOffline.value) {
      await _searchOffline(query);
      return;
    }
    try {
      final r = await widget.api
          .search(query)
          .timeout(const Duration(seconds: 6));
      if (!mounted) return;
      setState(() {
        _results = r;
        _suggests = [];
        _loading = false;
      });
      // Cold query: the server returns local hits instantly and builds the
      // online discovery (and artist rows/counts) in background threads.
      // Poll once shortly after so the online row fills in without the user
      // searching twice.
      if ((r.discovery.isEmpty && r.discoveryPending) || r.artistsPending) {
        _pollDiscovery(query);
      }
    } catch (e) {
      if (!mounted) return;
      // A dead route just proved offline: show cached rows + badge instead
      // of a spinner/error, and flag it so later taps go cache-first.
      if (e is TimeoutException) {
        QueuePlayer.instance.isOffline.value = true;
        await _searchOffline(query);
        return;
      }
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// Offline search: filter the MetaCache library index (all cached
  /// playlists' entries) and show matches as library rows + offline badge.
  Future<void> _searchOffline(String query) async {
    final user = AuthStore.instance.username ?? '';
    final hits = <LibraryTrack>[];
    try {
      final pls = await MetaCache.loadPlaylists(user);
      for (final p in pls) {
        final entries = await MetaCache.loadEntries(user, p.name);
        for (final e in MetaCache.searchEntries(entries, query)) {
          if (e.url != null) {
            hits.add(LibraryTrack(
                baseName: e.baseName, folder: p.name, url: e.url!));
          }
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _results = SearchResultPage(library: hits, discovery: const []);
      _suggests = [];
      _loading = false;
      _error = hits.isEmpty ? tr('Offline — nothing saved matches.') : '';
    });
    unawaited(widget.api
        .logClientError('offline-search', '$query (${hits.length} cached)'));
  }

  /// Re-fetches a search a moment later while discovery or the artist rows
  /// are still pending, so online hits + the corrected studio album counts
  /// appear without blocking the initial locals. Paints every poll response
  /// (so discovery shows the moment it lands — its visibility must NOT be held
  /// hostage to a slow/failing artists fetch), and stops only when BOTH are no
  /// longer pending, or after a few tries.
  Future<void> _pollDiscovery(String query, {int tries = 8}) async {
    for (var n = 0; n < tries; n++) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!mounted) return;
      try {
        final r = await widget.api.search(query);
        if (!mounted) return;
        setState(() {
          _results = r;
          _suggests = [];
          _loading = false;
        });
        // Prewarm NAS fileUrls so a tap starts progressively (206), not
        // after a cold full-file open.
        for (final t in r.library) {
          widget.api.prewarmFile(widget.api.fileUrl(t.url));
        }
        final rowsMissingAlbum = r.discovery.any(
          (d) => (d.album?.trim().isEmpty ?? true),
        );
        final done =
            (r.discovery.isNotEmpty || !r.discoveryPending) &&
            !r.artistsPending &&
            (!rowsMissingAlbum || n >= tries - 1);
        if (done) return;
      } catch (_) {
        return; // give up quietly on a transient failure
      }
    }
  }

  Future<void> _playDiscovery(SearchResultPage r, List<DiscoveryTrack> vis,
      int i) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final tap = ++_tapId;
    final t = vis[i];
    final sw = Stopwatch()..start();
    Future<void> slowLog(String track) async {
      if (sw.elapsedMilliseconds > 3000) {
        try {
          await widget.api.logClientError(
              'playback', '$track (slow tap ${sw.elapsedMilliseconds}ms)');
        } catch (_) {}
      }
    }
    // Fast path: library copy on this page plays immediately, no inNas round-trip.
    final local = _bestLocal(r, t);
    if (local != null) {
      // Awaited (not fire-and-forget): unawaited left the engine paused,
      // forcing an extra play tap. Slow taps auto-log to user-errors.
      await _playLibrary(local);
      unawaited(slowLog(local.baseName));
      return;
    }
    // Instant tap: the queue plays NOW with what the row already carries
    // (relay URL for the tapped video, placeholders behind it). NAS-first
    // upgrade + streaming resolve happen bounded inside the engine — no
    // inNas/resolve await before first audio, never parked.
    QueuePlayer.instance.wireTapResolvers(widget.api);
    setState(() => _resolving = true);
    try {
      String visThumb(DiscoveryTrack x) =>
          (x.albumImage?.isNotEmpty ?? false)
              ? x.albumImage!
              : (x.videoId.isNotEmpty
                  ? 'https://i.ytimg.com/vi/${x.videoId}/hqdefault.jpg'
                  : '');
      final q = List.generate(vis.length, (j) {
        final tj = vis[j];
        final th = visThumb(tj);
        if (tj.videoId.isNotEmpty) {
          return QueueItem(
            '${tj.artist} - ${tj.title}',
            widget.api.relayUrl(tj.videoId),
            thumbUrl: th.isEmpty ? null : th,
            videoId: tj.videoId,
            album: (tj.album?.isNotEmpty ?? false) ? tj.album : null,
            lyricsArtist: tj.artist,
            lyricsTitle: tj.title,
          );
        }
        return QueueItem(
          '${tj.artist} - ${tj.title}',
          '',
          thumbUrl: th.isEmpty ? null : th,
          resolveName: (artist: tj.artist, title: tj.title),
          album: (tj.album?.isNotEmpty ?? false) ? tj.album : null,
          lyricsArtist: tj.artist,
          lyricsTitle: tj.title,
        );
      });
      if (tap != _tapId || !mounted) return;
      if (q[i].url.isNotEmpty) widget.api.prewarmFile(q[i].url);
      unawaited(QueuePlayer.instance.playList(q, startIndex: i));
      unawaited(slowLog('${t.artist} - ${t.title}'));
    } catch (e) {
      if (mounted && tap == _tapId) {
        toast(context, "${tr('Play failed')}: $e", icon: Icons.error_outline);
      }
    } finally {
      if (mounted && tap == _tapId) setState(() => _resolving = false);
    }
  }

  /// A local library track that matches an internet result, so we can prefer
  /// the downloaded copy. EXACT norm_core match only: fuzzy containment here
  /// used to redirect a tap to a same-artist DIFFERENT song (and then play
  /// the wrong file). Anything inexact falls through to the tap-time NAS
  /// check below, which enforces the same exactness, else streams verbatim.
  LibraryTrack? _bestLocal(SearchResultPage r, DiscoveryTrack t) {
    if (r.library.isEmpty && t.library != 'nas') return null;
    final want = normCore('${t.artist} - ${t.title}');
    for (final lib in r.library) {
      if (normCore(lib.baseName) == want) return lib;
    }
    return null;
  }

  /// Discovery rows WITHOUT an exact local twin: an exact _bestLocal match
  /// already renders as a library row above, so showing both is a dupe.
  /// Stable songs-first: structured song rows above artist/group rows
  /// (the Artists section itself always renders last in build()).
  List<DiscoveryTrack> _visibleDiscovery(SearchResultPage r) {
    final vis = r.discovery.where((d) => _bestLocal(r, d) == null).toList();
    vis.sort((a, b) {
      final sa = isSongRow(artist: a.artist, title: a.title) ? 0 : 1;
      final sb = isSongRow(artist: b.artist, title: b.title) ? 0 : 1;
      return sa.compareTo(sb);
    });
    return vis;
  }

  /// Suggest rows, stable songs-first (same detect as discovery).
  List<Suggestion> _songsFirst(List<Suggestion> ss) {
    final out = [...ss];
    out.sort((a, b) {
      final sa = isSongRow(
        artist: a.artist,
        title: a.title ?? a.baseName,
        baseName: a.baseName,
        kind: a.kind,
      )
          ? 0
          : 1;
      final sb = isSongRow(
        artist: b.artist,
        title: b.title ?? b.baseName,
        baseName: b.baseName,
        kind: b.kind,
      )
          ? 0
          : 1;
      return sa.compareTo(sb);
    });
    return out;
  }

  /// Artist rows for the typeahead: server-sent kind=='artist' rows plus one
  /// synthesized row per distinct suggestion artist whose name matches the
  /// query (the suggest endpoint returns song rows only, so without this no
  /// artist row ever shows). Exact normalized match first.
  List<String> _suggestArtists(String q) {
    final qn = norm(q.trim());
    final seen = <String, String>{};
    void add(String n) {
      n = n.trim();
      if (n.isEmpty) return;
      final nn = norm(n);
      // Only query-matching artists: avoids a junk artist row per song on
      // generic queries. Exact and partial matches both qualify.
      if (qn.isNotEmpty && !(nn.contains(qn) || qn.contains(nn))) return;
      seen.putIfAbsent(nn, () => n);
    }

    for (final s in _suggests) {
      if (s.kind == 'artist') {
        add(s.artist?.isNotEmpty == true ? s.artist! : s.baseName);
      }
      add(s.artist ?? '');
    }
    final out = seen.values.toList();
    out.sort((a, b) {
      final ea = norm(a) == qn ? 0 : 1;
      final eb = norm(b) == qn ? 0 : 1;
      return ea != eb ? ea.compareTo(eb) : a.compareTo(b);
    });
    return out;
  }

  /// Song-only suggestions (artist rows render in their own section above).
  List<Suggestion> _suggestSongs() =>
      _suggests.where((s) => s.kind != 'artist').toList();

  Future<void> _playLibrary(LibraryTrack t) async {
    FocusManager.instance.primaryFocus?.unfocus();
    // Prewarm (no await) so the first Range GET goes out instantly.
    widget.api.prewarmFile(widget.api.fileUrl(t.url));
    try {
      await QueuePlayer.instance.playOne(
        QueueItem(
          t.baseName,
          widget.api.fileUrl(t.url),
          thumbUrl: widget.api.coverUrl(t.url),
        ),
      );
    } catch (e) {
      if (mounted) {
        toast(context, "${tr('Play failed')}: $e", icon: Icons.error_outline);
      }
    }
  }

  /// Best-effort YouTube id from a watch/youtu.be/shorts URL ('' if none).
  String _videoIdFromUrl(String url) {
    final m = RegExp(
      r'(?:[?&]v=|youtu\.be/|/shorts/)([\w-]{6,})',
    ).firstMatch(url);
    return m?.group(1) ?? '';
  }

  Future<void> _playSuggestion(Suggestion s) async {
    FocusManager.instance.primaryFocus?.unfocus();
    // Single-flight: stale taps (double-tap race) bail at every await.
    final tap = ++_tapId;
    // Local NAS row: play the file directly (awaited so cold errors toast).
    if (!s.isOnline && s.url.isNotEmpty) {
      await _playLibrary(
        LibraryTrack(baseName: s.baseName, url: s.url, folder: s.folder),
      );
      return;
    }
    // Online suggestion already flagged NAS-local: play it directly.
    if (s.inNas && (s.nasUrl?.isNotEmpty ?? false)) {
      widget.api.prewarmFile(widget.api.fileUrl(s.nasUrl!));
      try {
        await QueuePlayer.instance.playOne(
          QueueItem(
            s.baseName.isNotEmpty
                ? s.baseName
                : '${s.artist ?? ''} - ${s.title ?? ''}',
            widget.api.fileUrl(s.nasUrl!),
            thumbUrl: s.albumImage != null
                ? widget.api.coverUrl(s.nasUrl!)
                : null,
          ),
        );
      } catch (e) {
        if (mounted && tap == _tapId) {
          toast(
            context,
            "${tr('Could not play suggestion')}: $e",
            icon: Icons.error_outline,
          );
        }
      }
      return;
    }
    final artist = s.artist?.isNotEmpty == true ? s.artist! : '';
    final title = s.title?.isNotEmpty == true ? s.title! : s.baseName;
    // Instant tap: play the relay when the row carries a vid, else a lazy
    // placeholder. NAS-first upgrade + resolve run bounded in the engine.
    QueuePlayer.instance.wireTapResolvers(widget.api);
    setState(() => _resolving = true);
    try {
      if (tap != _tapId || !mounted) return;
      final vid = _videoIdFromUrl(s.url);
      final item = vid.isNotEmpty
          ? QueueItem(
              title,
              widget.api.relayUrl(vid),
              thumbUrl: widget.api.thumbUrl(vid),
              videoId: vid,
              album: (s.album?.isNotEmpty ?? false) ? s.album : null,
              lyricsArtist: artist,
              lyricsTitle: title,
            )
          : QueueItem(
              title,
              '',
              resolveName: (artist: artist, title: title),
              album: (s.album?.isNotEmpty ?? false) ? s.album : null,
              lyricsArtist: artist,
              lyricsTitle: title,
            );
      if (item.url.isNotEmpty) widget.api.prewarmFile(item.url);
      await QueuePlayer.instance.playOne(item);
    } catch (e) {
      if (mounted && tap == _tapId) {
        toast(
          context,
          "${tr('Could not play suggestion')}: $e",
          icon: Icons.error_outline,
        );
      }
    } finally {
      if (mounted && tap == _tapId) setState(() => _resolving = false);
    }
  }

  Future<void> _keep(DiscoveryTrack t) async {
    final pl = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => const KeepPlaylistSheet(),
    );
    if (pl == null || !mounted) return;
    try {
      await widget.api.addToPlaylist(
        baseName: '${t.artist} - ${t.title}',
        playlist: pl,
      );
      if (mounted) {
        toast(context, "${tr('Saved to')} \"$pl\" ${tr('(queued to download)')}");
      }
    } catch (e) {
      if (mounted) toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
    }
  }

  /// Long-press context menu for any song row in search results.
  void _showSongContext({
    required QueueItem queueItem,
    required String baseNameForPlaylist,
    bool queued = false,
  }) {
    showSongLongPressMenu(
      context,
      api: widget.api,
      queueItem: queueItem,
      baseNameForPlaylist: baseNameForPlaylist,
      queued: queued,
    );
  }

  /// Build a QueueItem for a library track (no resolve needed).
  QueueItem _queueItemFromLibrary(LibraryTrack t) => QueueItem(
    t.baseName,
    widget.api.fileUrl(t.url),
    thumbUrl: widget.api.coverUrl(t.url),
  );

  /// Build a QueueItem for a discovery track using the placeholder URL
  /// that will be lazily resolved by the player when it's time to play.
  QueueItem _queueItemFromDiscovery(DiscoveryTrack t) {
    QueuePlayer.instance.resolver = widget.api.resolve;
    QueuePlayer.instance.warm = widget.api.warm;
    QueuePlayer.instance.wireTapResolvers(widget.api);
    final th = (t.albumImage?.isNotEmpty ?? false)
        ? t.albumImage!
        : (t.videoId.isNotEmpty
            ? 'https://i.ytimg.com/vi/${t.videoId}/hqdefault.jpg'
            : '');
    return QueueItem(
      '${t.artist} - ${t.title}',
      '${widget.api.serverBase}/staging/resolve/${t.videoId}',
      thumbUrl: th.isEmpty ? null : th,
      videoId: t.videoId,
      album: (t.album?.isNotEmpty ?? false) ? t.album : null,
      lyricsArtist: t.artist,
      lyricsTitle: t.title,
    );
  }

  /// Build a QueueItem for a suggestion. Local NAS rows are direct;
  /// online suggestions use the resolveName lazy path.
  QueueItem _queueItemFromSuggestion(Suggestion s) {
    if (!s.isOnline && s.url.isNotEmpty) {
      return QueueItem(
        s.baseName,
        widget.api.fileUrl(s.url),
        thumbUrl: s.albumImage != null ? widget.api.coverUrl(s.url) : null,
      );
    }
    final artist = s.artist?.isNotEmpty == true ? s.artist! : '';
    final title = s.title?.isNotEmpty == true ? s.title! : s.baseName;
    QueuePlayer.instance.resolver = widget.api.resolve;
    QueuePlayer.instance.warm = widget.api.warm;
    QueuePlayer.instance.wireTapResolvers(widget.api);
    return QueueItem(
      title,
      'https://placeholder',
      resolveName: (artist: artist, title: title),
      album: (s.album?.isNotEmpty ?? false) ? s.album : null,
      lyricsArtist: artist,
      lyricsTitle: title,
    );
  }

  /// "Artist - Title" split helpers for NAS rows (baseName only).
  static String libArtist(String baseName) {
    final i = baseName.indexOf(' - ');
    return i > 0 ? baseName.substring(0, i).trim() : '';
  }

  void _openArtistPage(String name) {
    name = name.trim();
    if (name.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistScreen(api: widget.api, name: name),
      ),
    );
  }

  void _openAlbumPage(String artist, String? album, [String? cover]) {
    artist = artist.trim();
    album = (album ?? '').trim();
    if (artist.isEmpty || album.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AlbumScreen(
          api: widget.api,
          artist: artist,
          album: album!,
          coverImage: (cover?.isNotEmpty ?? false) ? cover : null,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Song-first always: library + discovery songs render before artists,
    // artists last. (A pure artist query has no song hits, so the artist
    // rows are still all there is to show.)
    final r0 = _results;
    final vis = r0 == null ? const <DiscoveryTrack>[] : _visibleDiscovery(r0);
    // Artists render LAST, after songs. Exact normalized match first
    // (client-side guarantee on top of the server's own ranking).
    List<Widget> artistSection(SearchResultPage r) {
      final qn = norm(_controller.text.trim());
      final ordered = [...r.artists];
      ordered.sort((a, b) {
        final ea = norm(a.name) == qn ? 0 : 1;
        final eb = norm(b.name) == qn ? 0 : 1;
        return ea != eb ? ea.compareTo(eb) : 0;
      });
      return [
        _sectionHeader(tr('Artists')),
        for (final a in ordered)
        ListTile(
          leading: CoverThumb(
            title: a.name,
            thumbUrl: a.image,
            size: 44,
            fallbackUrl: null,
          ),
          title: Text(
            a.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: a.albumCount != null
              ? Text(
                  '${a.albumCount} ${tr('albums')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : null,
          trailing: const Icon(
            Icons.chevron_right,
            color: Colors.white38,
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ArtistScreen(api: widget.api, name: a.name),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ];
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            onSubmitted: _runSearch,
            decoration: InputDecoration(
              hintText: tr('Search songs, artists…'),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (_, v, __) => v.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: tr('Clear'),
                        onPressed: () {
                          _controller.clear();
                          _onChanged('');
                        },
                      )
                    : IconButton(
                        icon: const Icon(Icons.send),
                        tooltip: tr('Search internet too'),
                        onPressed: () => _runSearch(_controller.text),
                      ),
              ),
              filled: true,
              fillColor: Spots.elevated,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(30),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (_resolving)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(
                  tr('Starting stream…'),
                  style: TextStyle(color: Colors.white54),
                ),
              ],
            ),
          ),
        if (_controller.text.trim().isEmpty &&
            _recent.isNotEmpty &&
            _results == null)
          Expanded(
            child: ListView(
              padding: EdgeInsets.only(
                  bottom: 12 + MediaQuery.of(context).viewInsets.bottom),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        tr('Recent searches'),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.white54,
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          await AppHistory.clearSearch();
                          if (mounted) setState(() => _recent = []);
                        },
                        child: Text(
                          tr('Clear'),
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                for (final q in _recent)
                  ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.history,
                      size: 20,
                      color: Colors.white38,
                    ),
                    title: Text(
                      q,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(
                      Icons.north_west,
                      size: 16,
                      color: Colors.white24,
                    ),
                    onTap: () {
                      _controller.text = q;
                      _runSearch(q);
                    },
                  ),
              ],
            ),
          ),
        if (_results != null)
          Expanded(
            child: ListView(
              padding: EdgeInsets.only(
                  bottom: 12 + MediaQuery.of(context).viewInsets.bottom),
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: QueuePlayer.instance.isOffline,
                  builder: (_, off, __) => off
                      ? Padding(
                          padding:
                              const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: offlineBanner(),
                        )
                      : const SizedBox.shrink(),
                ),
                if (_results!.resolved != null &&
                    _results!.resolved!.artist != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                    child: Row(
                      children: [
                        Icon(Icons.track_changes, size: 14, color: Spots.green),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            "${tr('Matched')} \"${_results!.resolved!.artist}"
                            ' - ${_results!.resolved!.title}" ${tr('via')} '
                            '${_results!.resolved!.provider}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_results!.library.isNotEmpty) ...[
                  _sectionHeader(tr('Your library')),
                  for (final t in _results!.library)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onLongPress: () => _showSongContext(
                        queueItem: _queueItemFromLibrary(t),
                        baseNameForPlaylist: t.baseName,
                      ),
                      child: ListTile(
                        leading: CoverThumb(
                          title: t.baseName,
                          thumbUrl: widget.api.coverUrl(t.url),
                        ),
                        title: Text(
                          t.baseName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${t.folder}  · ${tr('NAS')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if ((t.album ?? '').trim().isNotEmpty)
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.album_outlined,
                                    size: 20),
                                tooltip: tr('Albums'),
                                onPressed: () => _openAlbumPage(
                                  libArtist(t.baseName).isNotEmpty
                                      ? libArtist(t.baseName)
                                      : t.folder,
                                  t.album,
                                ),
                              ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.person_outline,
                                  size: 20),
                              tooltip: tr('Artist'),
                              onPressed: () => _openArtistPage(
                                libArtist(t.baseName).isNotEmpty
                                    ? libArtist(t.baseName)
                                    : t.folder,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.play_arrow),
                              onPressed: () => _playLibrary(t),
                            ),
                          ],
                        ),
                        onTap: () => _playLibrary(t),
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
                if (vis.isNotEmpty) ...[
                  _sectionHeader(
                    _results!.resolved != null &&
                            (_results!.resolved!.provider == 'Spotify' ||
                                _results!.resolved!.provider == 'Deezer')
                        ? tr('Search results · near matches')
                        : tr('Search results'),
                  ),
                  for (var i = 0; i < vis.length; i++)
                    _DiscoveryTile(
                      api: widget.api,
                      track: vis[i],
                      thumbUrl: vis[i].albumImage,
                      onPlay: () => _playDiscovery(_results!, vis, i),
                      onKeep: () => _keep(vis[i]),
                      onLongPress: () => _showSongContext(
                        queueItem: _queueItemFromDiscovery(vis[i]),
                        baseNameForPlaylist:
                            '${vis[i].artist}' ' - ${vis[i].title}',
                        queued: true,
                      ),
                    ),
                ],
                if (_results!.artists.isNotEmpty)
                  ...artistSection(_results!)
                else if (_results!.artistsPending)
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          tr('Loading artists…'),
                          style: TextStyle(
                              fontSize: 13, color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                if (_results!.library.isEmpty &&
                    vis.isEmpty &&
                    _results!.artists.isEmpty &&
                    !_results!.artistsPending)
                  Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        tr('No matches. Try another spelling.'),
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
              ],
            ),
          )
        else if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text(_error, textAlign: TextAlign.center)),
          )
        else if (_suggests.isNotEmpty)
          Expanded(
            child: Builder(
              builder: (context) {
                final artRows = _suggestArtists(_controller.text);
                final songSugs = _suggestSongs();
                return ListView(
                  padding: EdgeInsets.only(
                      bottom: 12 + MediaQuery.of(context).viewInsets.bottom),
                  children: [
                    if (artRows.isNotEmpty) ...[
                      _sectionHeader(tr('Artists')),
                      for (final a in artRows)
                        ListTile(
                          leading: const CircleAvatar(
                            radius: 22,
                            child: Icon(Icons.person, size: 24),
                          ),
                          title: Text(
                            a,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            tr('Artist'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(
                            Icons.chevron_right,
                            color: Colors.white38,
                          ),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ArtistScreen(
                                  api: widget.api, name: a),
                            ),
                          ),
                        ),
                    ],
                    if (songSugs.isNotEmpty) ...[
                      _sectionHeader(tr('Suggestions')),
                      for (final s in songSugs)
                        Builder(
                          builder: (context) {
                            final sugArtist = (s.artist ?? '').trim().isNotEmpty
                                ? s.artist!.trim()
                                : libArtist(s.baseName);
                            final sugAlbum = (s.album ?? '').trim();
                            return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onLongPress: () => _showSongContext(
                            queueItem: _queueItemFromSuggestion(s),
                            baseNameForPlaylist:
                                s.title?.isNotEmpty == true
                                    ? s.title!
                                    : s.baseName,
                            queued: s.isOnline,
                          ),
                          child: ListTile(
                            leading: CoverThumb(
                              title: s.title?.isNotEmpty == true
                                  ? s.title!
                                  : s.baseName,
                              thumbUrl: s.albumImage,
                              size: 44,
                              fallbackUrl: null,
                            ),
                            title: Text(
                              s.title?.isNotEmpty == true
                                  ? s.title!
                                  : s.baseName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: s.isOnline
                                ? Text(
                                    [
                                      s.artist ?? '',
                                      s.album ?? '',
                                      durOrDash(s.durationS),
                                      s.provider ?? '',
                                    ]
                                        .where((p) => p.isNotEmpty)
                                        .join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : Text(
                                    [
                                      s.artist ?? '',
                                      (s.album?.isNotEmpty ?? false)
                                          ? s.album!
                                          : (s.folder),
                                      durOrDash(s.durationS),
                                    ]
                                        .where((p) => p.isNotEmpty)
                                        .join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (sugAlbum.isNotEmpty &&
                                    sugArtist.isNotEmpty)
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(Icons.album_outlined,
                                        size: 20),
                                    tooltip: tr('Albums'),
                                    onPressed: () => _openAlbumPage(
                                        sugArtist, sugAlbum),
                                  ),
                                if (sugArtist.isNotEmpty)
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(Icons.person_outline,
                                        size: 20),
                                    tooltip: tr('Artist'),
                                    onPressed: () =>
                                        _openArtistPage(sugArtist),
                                  ),
                                IconButton(
                                  icon: Icon(
                                    Icons.play_arrow,
                                    color: s.isOnline ? Spots.green : null,
                                  ),
                                  onPressed: () => _playSuggestion(s),
                                ),
                              ],
                            ),
                            onTap: () => _playSuggestion(s),
                          ),
                        );
                          },
                        ),
                    ],
                    const SizedBox(height: 6),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        tr('Tip: press enter to refine the search.'),
                        style:
                            TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ),
                  ],
                );
              },
            ),
          )
        else
          Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  "${tr('Search your NAS library and the internet.')}\n\n"
                  "${tr('Play anything instantly; save what you like.')}",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _sectionHeader(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Text(
      t,
      style: const TextStyle(
        fontSize: 13,
        letterSpacing: 1.1,
        fontWeight: FontWeight.w700,
        color: Colors.white54,
      ),
    ),
  );
}

class _DiscoveryTile extends StatelessWidget {
  const _DiscoveryTile({
    required this.api,
    required this.track,
    required this.onPlay,
    required this.onKeep,
    this.thumbUrl,
    this.onLongPress,
  });
  final ApiClient api;
  final DiscoveryTrack track;
  final String? thumbUrl;
  final VoidCallback onPlay;
  final VoidCallback onKeep;
  final VoidCallback? onLongPress;

  String get dur => durOrDash(track.durationS);

  /// Album segment that never drops: provider album first, else the
  /// channel (source label) so the artist · album · duration triple
  /// stays complete even on bare YouTube rows.
  String get albumSeg {
    final a = (track.album ?? '').trim();
    return a.isNotEmpty ? a : track.channel;
  }

  /// Same destinations as the NAS song rows: album page / artist page.
  void _openAlbum(BuildContext context) {
    final album = (track.album ?? '').trim();
    if (album.isEmpty || track.artist.trim().isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AlbumScreen(
          api: api,
          artist: track.artist.trim(),
          album: album,
          coverImage: (track.albumImage?.isNotEmpty ?? false)
              ? track.albumImage
              : null,
        ),
      ),
    );
  }

  void _openArtist(BuildContext context) {
    if (track.artist.trim().isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistScreen(api: api, name: track.artist.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasAlbum = (track.album ?? '').trim().isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: ListTile(
        onTap: onPlay,
        leading: CoverThumb(
          title: '${track.artist} - ${track.title}',
          // Provider album art first, else hi-res YouTube art: maxres
          // primary, hq fallback (some videos have no maxres). Decoded
          // at physical pixels (CoverThumb), never upscaled.
          thumbUrl: (thumbUrl?.isNotEmpty ?? false)
              ? thumbUrl
              : (track.videoId.isNotEmpty
                    ? 'https://i.ytimg.com/vi/${track.videoId}/maxresdefault.jpg'
                    : null),
          fallbackUrl: track.videoId.isNotEmpty
              ? 'https://i.ytimg.com/vi/${track.videoId}/hqdefault.jpg'
              : null,
          size: 44,
        ),
        title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            track.artist,
            albumSeg,
            dur,
            if (track.provider.isNotEmpty) track.provider,
            if (track.inNas) tr('in NAS'),
          ].where((p) => p.isNotEmpty).join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.white54),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (track.inNas)
              Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.cloud_done_outlined,
                  size: 16,
                  color: Spots.green,
                  semanticLabel: tr('Already in your NAS library'),
                ),
              ),
            if (hasAlbum)
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.album_outlined, size: 20),
                onPressed: () => _openAlbum(context),
                tooltip: tr('Albums'),
              ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.person_outline, size: 20),
              onPressed: () => _openArtist(context),
              tooltip: tr('Artist'),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_circle_outline),
              onPressed: onKeep,
              tooltip: tr('Save to playlist'),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.play_arrow),
              onPressed: onPlay,
            ),
          ],
        ),
      ),
    );
  }
}
