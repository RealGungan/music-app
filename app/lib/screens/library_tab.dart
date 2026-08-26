import 'package:flutter/material.dart';

import '../api_client.dart';
import '../theme.dart';
import 'artists_view.dart';
import 'playlist_detail.dart';

/// Your Library tab: pinned staging entry + Playlists/Artists chips.
class LibraryTab extends StatefulWidget {
  const LibraryTab({
    super.key,
    required this.api,
    required this.onOpenPlaylist,
    required this.onGotoStaging,
  });

  final ApiClient api;
  final void Function(PlaylistInfo p) onOpenPlaylist;
  final VoidCallback onGotoStaging;

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  int _chip = 0; // 0 playlists · 1 artists
  late Future<List<PlaylistInfo>> _future;
  Key _refreshKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    _future = widget.api.playlists();
  }

  void _refresh() {
    setState(() {
      _future = widget.api.playlists();
      _refreshKey = UniqueKey();
    });
  }

  Future<void> _create() async {
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
    if (name == null || name.isEmpty) return;
    try {
      await widget.api.createPlaylist(name);
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(slivers: [
      SliverAppBar(
        pinned: true,
        toolbarHeight: 64,
        title: const Text('Your Library',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(children: [
            _chipBtn('Playlists', 0),
            const SizedBox(width: 8),
            _chipBtn('Artists', 1),
            const Spacer(),
            IconButton(
                onPressed: _create,
                tooltip: 'New playlist',
                icon: const Icon(Icons.add, size: 20)),
          ]),
        ),
      ),
      // pinned staging entry
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onGotoStaging,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Spots.elevated,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                const Icon(Icons.download_for_offline_outlined,
                    size: 26, color: Spots.green),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text('Downloads & staging',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                        Text('7-day holding pen · tap to manage',
                            style: TextStyle(
                                fontSize: 11.5, color: Colors.white54)),
                      ]),
                ),
                const Icon(Icons.chevron_right, color: Colors.white38),
              ]),
            ),
          ),
        ),
      ),
      if (_chip == 0)
        FutureBuilder<List<PlaylistInfo>>(
          key: _refreshKey,
          future: _future,
          builder: (ctx, snap) {
            final lists = snap.data ?? [];
            return SliverList.builder(
              itemCount: lists.length,
              itemBuilder: (ctx, i) {
                final p = lists[i];
                return ListTile(
                  leading: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      gradient: Spots.coverGradient(p.name),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Icon(
                        p.name.toLowerCase() == 'saved' ||
                                p.name.toLowerCase() == 'liked'
                            ? Icons.favorite
                            : Icons.queue_music,
                        size: 20,
                        color: Colors.white70),
                  ),
                  title: Text(p.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('Playlist · ${p.tracks}'),
                  trailing: const Icon(Icons.chevron_right,
                      color: Colors.white38),
                  onTap: () async {
                    await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => PlaylistDetailScreen(
                                api: widget.api, playlist: p)));
                    _refresh();
                  },
                );
              },
            );
          },
        )
      else
        SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
                padding: const EdgeInsets.only(bottom: 40),
                child: ArtistsView(api: widget.api))),
      const SliverPadding(padding: EdgeInsets.only(bottom: 90)),
    ]);
  }

  Widget _chipBtn(String label, int idx) => InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => setState(() => _chip = idx),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: _chip == idx ? Spots.green : Spots.elevated,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: _chip == idx ? Colors.black : Colors.white70)),
        ),
      );
}
