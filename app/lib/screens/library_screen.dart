import 'package:flutter/material.dart';

import '../api_client.dart';
import '../theme.dart';
import 'playlist_detail.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late Future<List<PlaylistInfo>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.playlists();
  }

  void _refresh() => setState(() => _future = widget.api.playlists());

  Future<void> _create() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
            controller: c,
            autofocus: true,
            decoration:
                const InputDecoration(hintText: 'Give it a name')),
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
    return Scaffold(
      body: CustomScrollView(slivers: [
        SliverAppBar(
          pinned: true,
          toolbarHeight: 72,
          title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Your Library',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800)),
                Text('Playlists on your server',
                    style: TextStyle(fontSize: 12, color: Colors.white54)),
              ]),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.tonalIcon(
                onPressed: _create,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: Spots.subtle,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
        FutureBuilder<List<PlaylistInfo>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()));
            }
            if (snap.hasError) {
              return SliverFillRemaining(
                  child: Center(child: Text('${snap.error}')));
            }
            final lists = snap.data ?? [];
            if (lists.isEmpty) {
              return const SliverFillRemaining(
                  child: Center(
                      child: Text('No playlists yet — create one!',
                          style: TextStyle(color: Colors.white38))));
            }
            return SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: .82),
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) {
                    final p = lists[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => PlaylistDetailScreen(
                                  api: widget.api, playlist: p)),
                        );
                        _refresh();
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AspectRatio(
                            aspectRatio: 1,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: Spots.coverGradient(p.name),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                  p.name.toLowerCase() == 'saved'
                                      ? Icons.favorite
                                      : Icons.queue_music,
                                  size: 44,
                                  color: Colors.white70),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                          Text('${p.tracks} tracks',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white54)),
                        ],
                      ),
                    );
                  },
                  childCount: lists.length,
                ),
              ),
            );
          },
        ),
      ]),
    );
  }
}
