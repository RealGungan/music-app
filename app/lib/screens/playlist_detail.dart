import 'package:flutter/material.dart';

import '../api_client.dart';
import '../queue_player.dart';
import 'queue_page.dart';
import '../theme.dart';
import '../widgets.dart';
import 'keep_dialog.dart';

class PlaylistDetailScreen extends StatefulWidget {
  const PlaylistDetailScreen(
      {super.key, required this.api, required this.playlist, this.onPop});

  final ApiClient api;
  final PlaylistInfo playlist;
  final VoidCallback? onPop;

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  late Future<List<PlaylistEntry>> _future;
  String _filter = '';
  int _sortCol = 0; // 0 title · 1 date added
  bool _asc = true;
  bool get _hasDates => _lastEntries.any((e) => e.addedAt != null);
  List<PlaylistEntry> _lastEntries = const [];

  String _norm(String x) => x
      .toLowerCase()
      .replaceAll(RegExp(r'[áàäâ]'), 'a')
      .replaceAll(RegExp(r'[éèëê]'), 'e')
      .replaceAll(RegExp(r'[íìïî]'), 'i')
      .replaceAll(RegExp(r'[óòöô]'), 'o')
      .replaceAll(RegExp(r'[úùüû]'), 'u')
      .replaceAll(RegExp(r'ñ'), 'n')
      .replaceAll(RegExp(r'[^a-z0-9 ]'), '');

  bool _matches(PlaylistEntry e) {
    if (_filter.isEmpty) return true;
    final hay = _norm(e.baseName);
    return _filter
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .every((w) => hay.contains(_norm(w)));
  }

  @override
  void initState() {
    super.initState();
    _future = widget.api.playlistEntries(widget.playlist.name);
  }

  void _refresh() =>
      setState(() => _future = widget.api.playlistEntries(widget.playlist.name));

  /// Playable queue + per-entry position (fixes play-from-here).
  (List<QueueItem>, Map<int, int>) _buildQueue(List<PlaylistEntry> entries) {
    final q = <QueueItem>[];
    final pos = <int, int>{};
    for (final (i, e) in entries.indexed) {
      if (e.exists && e.url != null) {
        pos[i] = q.length;
        q.add(QueueItem(e.baseName, widget.api.fileUrl(e.url!),
            thumbUrl: e.albumImage ?? widget.api.coverUrl(e.url!),
            genreHint: widget.playlist.name,
            filePath: e.url));
      }
    }
    return (q, pos);
  }

  static String _fmtDate(int secs) {
    final d = DateTime.fromMillisecondsSinceEpoch(secs * 1000);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Spots.base,
      body: FutureBuilder<List<PlaylistEntry>>(
        future: _future,
        builder: (ctx, snap) {
          final all = snap.data ?? [];
          _lastEntries = all;
          final entries =
              all.where(_matches).toList(growable: false)
                ..sort((a, b) {
                  switch (_sortCol) {
                    case 1:
                      final ad = a.addedAt ?? 0;
                      final bd = b.addedAt ?? 0;
                      return _asc ? ad.compareTo(bd) : bd.compareTo(ad);
                    default:
                      final c = a.baseName
                          .toLowerCase()
                          .compareTo(b.baseName.toLowerCase());
                      return _asc ? c : -c;
                  }
                });

          final (queue, posMap) = _buildQueue(all); // queue keeps full list
          
          return CustomScrollView(slivers: [
            SliverAppBar(
              pinned: true,
              leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    final f = widget.onPop;
                    if (f != null) {
                      f();
                    } else {
                      Navigator.maybePop(context);
                    }
                  }),
              actions: [
                IconButton(
                  tooltip: 'Queue',
                  icon: const Icon(Icons.queue_music_outlined),
                  onPressed: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const QueuePage())),
                ),
                IconButton(
                  icon: const Icon(Icons.more_vert),
                  tooltip: 'Delete playlist',
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (dctx) => AlertDialog(
                        title: Text('Delete "${widget.playlist.name}"?'),
                        content: const Text(
                            'The playlist is removed. Songs stay in your library.'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(dctx, false),
                              child: const Text('Cancel')),
                          FilledButton(
                              style: FilledButton.styleFrom(
                                  backgroundColor: Colors.redAccent),
                              onPressed: () => Navigator.pop(dctx, true),
                              child: const Text('Delete')),
                        ],
                      ),
                    );
                    if (ok == true) {
                      try {
                        await widget.api.deletePlaylist(widget.playlist.name);
                      } catch (_) {}
                      if (context.mounted) {
                        if (widget.onPop != null) {
                          widget.onPop!();
                        } else if (context.mounted) {
                          Navigator.pop(context);
                        }
                      }
                    }
                  },
                ),
              ],
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                  CoverArt(seed: widget.playlist.name,
                      size: 116, rounded: 10,
                      icon: widget.playlist.name.toLowerCase() == 'saved'
                          ? Icons.favorite
                          : Icons.queue_music),
                  const SizedBox(width: 16),
                  Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.playlist.name, maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 26, fontWeight: FontWeight.w900)),
                        const SizedBox(height: 6),
                        Text('${entries.where((e) => e.exists).length} songs',
                            style: const TextStyle(color: Colors.white54)),
                      ])),
                ]),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: TextField(
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    hintText:
                        'Search in ${widget.playlist.name}',
                    hintStyle: const TextStyle(color: Colors.white38),
                    prefixIcon: const Icon(Icons.search,
                        size: 20, color: Colors.white54),
                    isDense: true,
                    filled: true,
                    fillColor: Spots.elevated,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: Spots.green,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 12)),
                    icon: const Icon(Icons.shuffle, size: 22),
                    label: const Text('Shuffle play',
                        style: TextStyle(fontSize: 15)),
                    onPressed: queue.isEmpty
                        ? null
                        : () => QueuePlayer.instance.playList(queue,
                            startShuffled: true),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Row(children: [
                  const SizedBox(width: 56),
                  InkWell(
                    onTap: () => setState(() {
                      if (_sortCol == 0) {
                        _asc = !_asc;
                      } else {
                        _sortCol = 0;
                        _asc = true;
                      }
                    }),
                    child: Row(children: [
                      const Text('TITLE',
                          style: TextStyle(
                              fontSize: 11,
                              letterSpacing: .8,
                              color: Colors.white38)),
                      Icon(
                          _sortCol == 0
                              ? (_asc
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward)
                              : Icons.unfold_more,
                          size: 13,
                          color: _sortCol == 0
                              ? Spots.green
                              : Colors.white24),
                    ]),
                  ),
                  const Spacer(),
                  if (_hasDates)
                    InkWell(
                      onTap: () => setState(() {
                        if (_sortCol == 1) {
                          _asc = !_asc; // default newest-first on first use
                        } else {
                          _sortCol = 1;
                          _asc = false;
                        }
                      }),
                      child: Row(children: [
                        const Text('DATE ADDED',
                            style: TextStyle(
                                fontSize: 11,
                                letterSpacing: .8,
                                color: Colors.white38)),
                        Icon(
                            _sortCol == 1
                                ? (!_asc
                                    ? Icons.arrow_downward
                                    : Icons.arrow_upward)
                                : Icons.unfold_more,
                            size: 13,
                            color: _sortCol == 1
                                ? Spots.green
                                : Colors.white24),
                      ]),
                    ),
                  const SizedBox(width: 8),
                ]),
              ),
            ),
            SliverList.builder(
              itemCount: entries.length,
              itemBuilder: (ctx, i) {
                final e = entries[i];
                final qi = e.exists && e.url != null
                    ? QueueItem(e.baseName, widget.api.fileUrl(e.url!),
                        thumbUrl:
                            e.albumImage ?? widget.api.coverUrl(e.url!),
                        genreHint: widget.playlist.name,
                        filePath: e.url)
                    : null;
                return GestureDetector(
                  onSecondaryTapUp: (d) async {
                    final action = await showTrackMenu<String>(
                        context,
                        e.baseName,
                        [
                          TrackAction('Play from here',
                              Icons.play_arrow, 'play'),
                          TrackAction('Add to another playlist',
                              Icons.playlist_add, 'keep'),
                          TrackAction('Remove from this playlist',
                              Icons.playlist_remove, 'rm',
                              destructive: true),
                        ]);
                    if (!mounted || action == null) return;
                    switch (action) {
                      case 'play':
                        final p2 = posMap[i];
                        if (p2 != null) {
                          QueuePlayer.instance
                              .playList(queue, startIndex: p2);
                        } else {
                          _snack('File missing on the server');
                        }
                      case 'keep':
                        showKeepDialog(context, widget.api,
                                baseName: e.baseName)
                            .then((_) => _refresh());
                      case 'rm':
                        try {
                          await widget.api.removeFromPlaylist(
                              widget.playlist.name,
                              baseName: e.baseName);
                          _refresh();
                        } catch (err) {
                          _snack('Failed: $err');
                        }
                    }
                  },
                  child: ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16),
                    horizontalTitleGap: 12,
                    leading: e.exists
                        ? CoverArt(
                            seed: e.baseName,
                            size: 44,
                            rounded: 6,
                            networkUrl: e.albumImage ??
                                (e.url != null
                                    ? widget.api.coverUrl(e.url!)
                                    : null))
                        : const Icon(Icons.cloud_off_outlined,
                            size: 18, color: Colors.white38),
                    title: Text(e.baseName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color:
                                e.exists ? null : Colors.white38,
                            decoration: e.exists
                                ? null
                                : TextDecoration.lineThrough)),
                    subtitle: e.addedAt != null
                        ? Text(_fmtDate(e.addedAt!),
                            style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white38))
                        : null,
                    trailing: Row(mainAxisSize: MainAxisSize.min,
                      children: [
                      if (qi != null)
                        IconButton(
                          icon: const Icon(Icons.play_arrow),
                          tooltip: 'Play from here',
                          onPressed: () => QueuePlayer.instance
                              .playList(queue, startIndex: posMap[i] ?? 0),
                        ),
                      IconButton(
                        icon: const Icon(Icons.playlist_add, size: 20),
                        tooltip: 'Add to another playlist',
                        onPressed: () => showKeepDialog(context, widget.api,
                                baseName: e.baseName)
                            .then((_) => _refresh()),
                      ),
                    ]),
                  ),
                );
              },
            ),
            if (entries.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                      child: Text('No matching songs.',
                          style: TextStyle(color: Colors.white38))),
                ),
              ),
            const SliverToBoxAdapter(
                child: SizedBox(height: 90)),
          ]);
        },
      ),
    );
  }
}
