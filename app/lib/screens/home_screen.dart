import 'package:flutter/material.dart';

import '../api_client.dart';
import '../queue_player.dart';
import '../theme.dart';
import '../widgets.dart' show CoverArt;
import 'keep_dialog.dart';

/// Spotify-style home: greeting + shortcut cards for playlists.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.api, required this.onOpenPlaylist});

  final ApiClient api;
  final void Function(PlaylistInfo) onOpenPlaylist;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0; // 0 playlists, 1 artists

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        child: Row(children: [
          Expanded(
            child: Text(_greeting(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w900)),
          ),
          const SizedBox(width: 12),
          ToggleButtons(
            isSelected: [_tab == 0, _tab == 1],
            onPressed: (i) => setState(() => _tab = i),
            borderRadius: BorderRadius.circular(20),
            selectedColor: Colors.black,
            fillColor: Spots.green,
            color: Colors.white70,
            constraints: const BoxConstraints(minHeight: 30),
            children: const [
              Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  child: Text('Playlists',
                      style: TextStyle(fontSize: 12.5))),
              Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  child: Text('Artists',
                      style: TextStyle(fontSize: 12.5))),
            ],
          ),
        ]),
      ),
      Expanded(
        child: _tab == 0
            ? _playlistsGrid()
            : _artistsList(),
      ),
    ]);
  }

  Widget _artistsList() {
    return FutureBuilder<List<LocalResult>>(
      future: widget.api.allTracks(),
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final tracks = snap.data ?? [];
        final byArtist = <String, List<LocalResult>>{};
        for (final t in tracks) {
          if (t.baseName.contains(' - ')) {
            byArtist.putIfAbsent(t.artist, () => []).add(t);
          }
        }
        final artists = byArtist.keys.toList()..sort();
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          itemCount: artists.length,
          itemBuilder: (ctx, i) {
            final a = artists[i];
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Spots.subtle,
                child: Text(a.isEmpty ? '?' : a[0].toUpperCase(),
                    style: const TextStyle(color: Colors.white70)),
              ),
              title: Text(a, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${byArtist[a]!.length} songs',
                  style: const TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => ArtistPage(
                          api: widget.api,
                          artist: a,
                          tracks: byArtist[a]!)),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _playlistsGrid() {
    return FutureBuilder<List<PlaylistInfo>>(
      future: widget.api.playlists(),
      builder: (ctx, snap) {
        final lists = snap.data ?? [];
        return CustomScrollView(slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 4)),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            sliver: SliverGrid(
              gridDelegate:
                  const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 260,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 2.6,
              ),
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  final p = lists[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => widget.onOpenPlaylist(p),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Spots.elevated,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(children: [
                        ClipRRect(
                          borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(6),
                              bottomLeft: Radius.circular(6)),
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              gradient: Spots.coverGradient(p.name),
                            ),
                            child: Icon(
                                p.name.toLowerCase() == 'saved'
                                    ? Icons.favorite
                                    : Icons.queue_music,
                                color: Colors.white70),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(p.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w800)),
                        ),
                        // hover play button (Spotify signature)
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: _HoverPlay(onTap: () => widget.onOpenPlaylist(p)),
                        ),
                      ]),
                    ),
                  );
                },
                childCount: lists.length,
              ),
            ),
          ),
        ]);
      },
    );
  }

  static String _greeting() {
    final h = DateTime.now().hour;
    if (h < 6) return 'Good night';
    if (h < 13) return 'Good morning';
    if (h < 19) return 'Good afternoon';
    return 'Good evening';
  }
}

class _HoverPlay extends StatefulWidget {
  const _HoverPlay({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_HoverPlay> createState() => _HoverPlayState();
}

class _HoverPlayState extends State<_HoverPlay> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: _hover ? 1 : 0,
        child: InkWell(
          onTap: widget.onTap,
          customBorder: const CircleBorder(),
          child: Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                  color: Spots.green, shape: BoxShape.circle),
              child: const Icon(Icons.play_arrow,
                  size: 26, color: Colors.black)),
        ),
      ),
    );
  }
}



/// Simple artist page: their songs with play + add-to-playlist.
class ArtistPage extends StatelessWidget {
  const ArtistPage(
      {super.key,
      required this.api,
      required this.artist,
      required this.tracks});
  final ApiClient api;
  final String artist;
  final List<LocalResult> tracks;

  @override
  Widget build(BuildContext context) {
    final queue = [
      for (final t in tracks)
        QueueItem(t.baseName, api.fileUrl(t.url),
            thumbUrl: api.coverUrl(t.url))
    ];
    return Scaffold(
      appBar: AppBar(title: Text(artist)),
      body: ListView(padding: const EdgeInsets.only(bottom: 90), children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: queue.isEmpty
                ? null
                : () => QueuePlayer.instance.playList(queue,
                    startShuffled: true),
            icon: const Icon(Icons.shuffle),
            label: const Text('Shuffle play'),
          ),
        ),
        for (final (i, t) in tracks.indexed)
          ListTile(
            leading: CoverArt(
                seed: t.baseName,
                size: 44,
                rounded: 6,
                networkUrl: api.coverUrl(t.url)),
            title: Text(t.baseName.split(' - ').skip(1).join(' - '),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () => QueuePlayer.instance
                      .playList(queue, startIndex: i)),
              IconButton(
                  icon: const Icon(Icons.playlist_add, size: 20),
                  onPressed: () => showKeepDialog(context, api,
                      baseName: t.baseName)),
            ]),
          ),
      ]),
    );
  }
}
