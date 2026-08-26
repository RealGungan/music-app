import 'package:flutter/material.dart';

import '../api_client.dart';
import '../queue_player.dart';
import '../theme.dart';
import '../widgets.dart';
import 'keep_dialog.dart';

/// Grouped-by-primary-artist browse view, shared by Home + Library.
class ArtistsView extends StatelessWidget {
  const ArtistsView({super.key, required this.api});

  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<LocalResult>>(
      future: api.allTracks(),
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final tracks = snap.data ?? [];
        final byArtist = <String, List<LocalResult>>{};
        for (final t in tracks) {
          final raw = t.baseName.contains(' - ')
              ? t.baseName.split(' - ').first.trim()
              : '';
          // primary artist = first comma-separated name
          final primary =
              raw.isEmpty ? '' : raw.split(',').first.trim();
          if (primary.isEmpty) continue;
          byArtist.putIfAbsent(primary, () => []).add(t);
        }
        final artists = byArtist.keys.toList()..sort();
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          itemCount: artists.length,
          itemBuilder: (ctx, i) {
            final a = artists[i];
            final songs = byArtist[a]!;
            return ListTile(
              leading: CircleAvatar(
                radius: 24,
                backgroundColor: Spots.subtle,
                child: Text(a.isEmpty ? '?' : a[0].toUpperCase(),
                    style: const TextStyle(color: Colors.white70)),
              ),
              title: Text(a,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle:
                  Text('${songs.length} songs',
                      style: const TextStyle(fontSize: 12)),
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => ArtistPage(
                          api: api, artist: a, tracks: songs))),
            );
          },
        );
      },
    );
  }
}

/// Playlist-styled artist page: header, shuffle pill, all their tracks.
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
      backgroundColor: Spots.base,
      appBar: AppBar(title: Text(artist)),
      body: ListView(padding: const EdgeInsets.only(bottom: 100), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(children: [
            CircleAvatar(
              radius: 42,
              backgroundColor: Spots.subtle,
              child: Text(artist.isEmpty ? '?' : artist[0].toUpperCase(),
                  style: const TextStyle(
                      fontSize: 30, color: Colors.white70)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Artist',
                        style: TextStyle(
                            fontSize: 12, color: Colors.white54)),
                    Text('${tracks.length} songs in your library',
                        style: const TextStyle(fontSize: 13)),
                  ]),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: Spots.green,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 12)),
              onPressed: queue.isEmpty
                  ? null
                  : () => QueuePlayer.instance.playList(queue,
                      startShuffled: true),
              icon: const Icon(Icons.shuffle),
              label: const Text('Shuffle play'),
            ),
          ),
        ),
        for (final (i, t) in tracks.indexed)
          ListTile(
            leading:
                CoverArt(seed: t.baseName, size: 44, rounded: 6,
                    networkUrl: api.coverUrl(t.url)),
            title: Text(
                t.baseName.split(' - ').skip(1).join(' - '),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () => QueuePlayer.instance
                      .playList(queue, startIndex: i)),
              IconButton(
                  icon: const Icon(Icons.playlist_add, size: 20),
                  onPressed: () =>
                      showKeepDialog(context, api, baseName: t.baseName)),
            ]),
          ),
      ]),
    );
  }
}
