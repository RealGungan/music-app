import 'package:flutter/material.dart';

import '../api_client.dart';
import '../queue_player.dart';
import '../theme.dart';
import '../widgets.dart';
import 'keep_dialog.dart';

class PlaylistDetailScreen extends StatefulWidget {
  const PlaylistDetailScreen(
      {super.key, required this.api, required this.playlist});

  final ApiClient api;
  final PlaylistInfo playlist;

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  late Future<List<PlaylistEntry>> _future;

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
            thumbUrl: widget.api.coverUrl(e.url!)));
      }
    }
    return (q, pos);
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
          final entries = snap.data ?? [];
          final (queue, posMap) = _buildQueue(entries);
          return CustomScrollView(slivers: [
            SliverAppBar(
              pinned: true,
              leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.pop(context)),
              actions: [
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
                      if (context.mounted) Navigator.pop(context);
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
            SliverList.builder(
              itemCount: entries.length,
              itemBuilder: (ctx, i) {
                final e = entries[i];
                return ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16),
                  horizontalTitleGap: 12,
                  leading: e.exists
                      ? CoverArt(
                          seed: e.baseName,
                          size: 44,
                          rounded: 6,
                          networkUrl: e.url != null
                              ? widget.api.coverUrl(e.url!)
                              : null)
                      : const Icon(Icons.cloud_off_outlined,
                          size: 18, color: Colors.white38),
                  title: Text(e.baseName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: e.exists
                              ? null
                              : Colors.white38,
                          decoration: e.exists
                              ? null
                              : TextDecoration.lineThrough)),
                  onTap: () {
                    final p = posMap[i];
                    if (p != null) {
                      QueuePlayer.instance.playList(queue, startIndex: p);
                    } else {
                      _snack('File missing on the server');
                    }
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.more_vert, size: 20),
                    onPressed: () async {
                      final a = await showTrackMenu<String>(context,
                          e.baseName, [
                        TrackAction('Play from here', Icons.play_arrow, 'play'),
                        TrackAction('Add to another playlist',
                            Icons.playlist_add, 'keep'),
                        TrackAction('Remove from this playlist',
                            Icons.playlist_remove, 'rm',
                            destructive: true),
                      ]);
                      if (!mounted || a == null) return;
                      switch (a) {
                        case 'play':
                          final p = posMap[i];
                          if (p != null) {
                            QueuePlayer.instance
                                .playList(queue, startIndex: p);
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
                  ),
                );
              },
            ),
            const SliverToBoxAdapter(
                child: SizedBox(height: 90)),
          ]);
        },
      ),
    );
  }
}
