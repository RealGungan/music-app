import 'package:flutter/material.dart';

import '../api_client.dart';
import '../queue_player.dart';
import '../theme.dart';

/// Spotify-desktop left rail: black, two stacked cards.
class SideBar extends StatelessWidget {
  const SideBar({
    super.key,
    required this.api,
    required this.serverUrl,
    required this.onEditServer,
    required this.rootIndex,
    required this.onSelectRoot,
    required this.onOpenPlaylist,
    required this.refreshKey,
    required this.onLibraryChanged,
    required this.onPlayPlaylist,
    this.buildId = 'dev',
  });

  final ApiClient api;
  final String serverUrl;
  final VoidCallback onEditServer;
  final int rootIndex;
  final ValueChanged<int> onSelectRoot;
  final void Function(PlaylistInfo p) onOpenPlaylist;
  final Key refreshKey;
  final VoidCallback onLibraryChanged;
  final void Function(PlaylistInfo p, {required bool shuffled}) onPlayPlaylist;
  final String buildId;

  Future<void> _create(BuildContext context) async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Create')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      try {
        await api.createPlaylist(name);
        onLibraryChanged();
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Create failed: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 264,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
        child: Column(children: [
          // ---- nav card
          Container(
            decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(children: [
              _navItem(Icons.home_outlined, 'Home', 0, icon2: Icons.home_filled),
              _navItem(Icons.search, 'Search', 1),
              _navItem(Icons.download_outlined, 'Staging', 2,
                  icon2: Icons.download_rounded),
            ]),
          ),
          const SizedBox(height: 8),
          // ---- library card
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.library_music,
                          size: 20, color: Colors.white54),
                      const SizedBox(width: 10),
                      const Text('Your Library',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5)),
                      const Spacer(),
                      InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => _create(context),
                        child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.add, size: 20)),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Expanded(
                      child: FutureBuilder<List<PlaylistInfo>>(
                        key: refreshKey,
                        future: api.playlists(),
                        builder: (ctx, snap) {
                          final lists = snap.data ?? [];
                          return ListView.builder(
                            itemCount: lists.length,
                            itemBuilder: (ctx, i) {
                              final p = lists[i];
                              return InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: () => onOpenPlaylist(p),
                                onSecondaryTapUp: (d) async {
                                  final overlay = Overlay.of(context).context
                                      .findRenderObject() as RenderBox;
                                  final action = await showMenu<String>(
                                    context: context,
                                    position: RelativeRect.fromLTRB(
                                        d.globalPosition.dx,
                                        d.globalPosition.dy,
                                        overlay.size.width -
                                            d.globalPosition.dx,
                                        overlay.size.height -
                                            d.globalPosition.dy),
                                    color: Spots.elevated,
                                    items: const [
                                      PopupMenuItem(
                                          value: 'shuffle',
                                          child: ListTile(dense: true,
                                              leading: Icon(Icons.shuffle,
                                                  size: 18),
                                              title:
                                                  Text('Shuffle play'))),
                                      PopupMenuItem(
                                          value: 'play',
                                          child: ListTile(dense: true,
                                              leading: Icon(Icons.play_arrow,
                                                  size: 18),
                                              title: Text('Play'))),
                                      PopupMenuItem(
                                          value: 'delete',
                                          child: ListTile(dense: true,
                                              leading: Icon(Icons.delete_outline,
                                                  size: 18,
                                                  color: Colors.redAccent),
                                              title: Text('Delete',
                                                  style: TextStyle(
                                                      color: Colors
                                                          .redAccent)))),
                                    ],
                                  );
                                  if (!context.mounted || action == null) {
                                    return;
                                  }
                                  if (action == 'delete') {
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (dctx) => AlertDialog(
                                        title: Text('Delete "${p.name}"?'),
                                        content: const Text(
                                            'The playlist is removed. Songs stay in your library.'),
                                        actions: [
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(dctx, false),
                                              child: const Text('Cancel')),
                                          FilledButton(
                                              style: FilledButton.styleFrom(
                                                  backgroundColor:
                                                      Colors.redAccent),
                                              onPressed: () =>
                                                  Navigator.pop(dctx, true),
                                              child: const Text('Delete')),
                                        ],
                                      ),
                                    );
                                    if (ok == true) {
                                      await api.deletePlaylist(p.name);
                                      onLibraryChanged();
                                    }
                                    return;
                                  }
                                  // shuffle / play
                                  try {
                                    final entries =
                                        await api.playlistEntries(p.name);
                                    final q = [
                                      for (final e in entries)
                                        if (e.exists && e.url != null)
                                          QueueItem(e.baseName,
                                              api.fileUrl(e.url!),
                                              thumbUrl:
                                                  api.coverUrl(e.url!),
                                              genreHint: p.name)
                                    ];
                                    if (q.isNotEmpty) {
                                      QueuePlayer.instance.playList(q,
                                          startShuffled: action == 'shuffle');
                                    }
                                  } catch (_) {}
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(6),
                                  child: Row(children: [
                                    Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        gradient: Spots.coverGradient(
                                            p.name),
                                        borderRadius:
                                            BorderRadius.circular(4),
                                      ),
                                      child: Icon(
                                          p.name.toLowerCase() == 'saved'
                                              ? Icons.favorite
                                              : Icons.queue_music,
                                          size: 18,
                                          color: Colors.white70),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize:
                                            MainAxisSize.min,
                                        children: [
                                          Text(p.name,
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 13.5,
                                                  fontWeight:
                                                      FontWeight
                                                          .w600)),
                                          Text('Playlist · ${p.tracks}',
                                              style: TextStyle(
                                                  fontSize: 11.5,
                                                  color: Colors
                                                      .white54)),
                                        ],
                                      ),
                                    ),
                                  ]),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ]),
            ),
          ),
          const SizedBox(height: 8),
          // server chip
          InkWell(
            onTap: onEditServer,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                const Icon(Icons.dns, size: 16, color: Colors.white38),
                const SizedBox(width: 8),
                Expanded(child: Text('$serverUrl · build $buildId',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.white38))),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _navItem(IconData icon, String label, int idx,
      {IconData? icon2}) {
    final selected = rootIndex == idx;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => onSelectRoot(idx),
      child: SizedBox(
        height: 40,
        child: Row(children: [
          const SizedBox(width: 12),
          Icon(selected ? (icon2 ?? icon) : icon,
              size: 22,
              color: selected ? Colors.white : Colors.white54),
          const SizedBox(width: 14),
          Text(label,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? Colors.white : Colors.white54)),
        ]),
      ),
    );
  }
}
