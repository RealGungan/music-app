import 'package:flutter/material.dart';

import '../api_client.dart';
import '../queue_player.dart';
import '../theme.dart';
import '../widgets.dart';
import 'keep_dialog.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.api, required this.onStageStarted});

  final ApiClient api;
  final void Function(String message) onStageStarted;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  SearchResultPage? _results;
  bool _loading = false;
  String? _resolvingId;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run(String q) async {
    if (q.trim().isEmpty) return;
    setState(() => _loading = true);
    try {
      final r = await widget.api.search(q);
      setState(() => _results = r);
    } catch (e) {
      widget.onStageStarted('Search failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _stream(DiscoveryResult d) async {
    setState(() => _resolvingId = d.videoId);
    try {
      final url = await widget.api.resolve(d.videoId);
      await QueuePlayer.instance.playOne(
          QueueItem('${d.artist} - ${d.title}', url));
    } catch (e) {
      widget.onStageStarted('Stream failed: $e');
    } finally {
      if (mounted) setState(() => _resolvingId = null);
    }
  }

  List<TrackAction<String>> _actions(
          {@required String? title,
          VoidCallback? play,
          VoidCallback? keep,
          VoidCallback? stage}) =>
      [
        if (play != null)
          TrackAction('Play now', Icons.play_arrow, 'play'),
        if (keep != null)
          TrackAction('Add to playlist', Icons.playlist_add, 'keep'),
        if (stage != null)
          TrackAction('Download to staging', Icons.download, 'stage'),
      ];

  Future<void> _handle(String action, DiscoveryResult d) async {
    switch (action) {
      case 'play':
        await _stream(d);
      case 'keep':
        await showKeepDialog(context, widget.api,
            baseName: '${d.artist} - ${d.title}');
      case 'stage':
        try {
          await widget.api.stage(d.artist, d.title);
          widget.onStageStarted('Staging "${d.artist} - ${d.title}"…');
        } catch (e) {
          widget.onStageStarted('Stage failed: $e');
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _results;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: TextField(
          controller: _controller,
          textInputAction: TextInputAction.search,
          onSubmitted: _run,
          style: const TextStyle(fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            hintText: 'Songs, artists…',
            hintStyle: TextStyle(color: Colors.white38),
            prefixIcon: const Icon(Icons.search, color: Colors.white54),
            filled: true,
            fillColor: Spots.elevated,
            contentPadding: EdgeInsets.zero,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
      if (_loading)
        const LinearProgressIndicator(minHeight: 2, color: Spots.green, backgroundColor: Spots.subtle),
      Expanded(
        child: r == null
            ? Center(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: const [
                Icon(Icons.travel_explore, size: 56, color: Colors.white24),
                SizedBox(height: 12),
                Text('Find songs here — even ones you don\u2019t own yet.',
                    style: TextStyle(color: Colors.white38)),
              ]))
            : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                if (r.local.isEmpty && r.discovery.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No results.',
                        style: TextStyle(color: Colors.white38))),
                  ),
                if (r.local.isNotEmpty) ...[
                  _section(context, 'In your library'),
                  for (final l in r.local)
                    ListTile(
                      leading: CoverArt(seed: l.baseName, icon: Icons.audiotrack,
                          networkUrl: widget.api.coverUrl(l.url)),
                      title: Text(l.baseName,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(l.folder.isEmpty ? 'Local' : l.folder,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => QueuePlayer.instance.playOne(QueueItem(
                          l.baseName, widget.api.fileUrl(l.url))),
                      trailing: IconButton(
                        icon: const Icon(Icons.more_vert),
                        onPressed: () async {
                          final a = await showTrackMenu<String>(context, l.baseName, [
                            TrackAction('Play now', Icons.play_arrow, 'play'),
                            TrackAction('Add to playlist', Icons.playlist_add, 'keep'),
                          ]);
                          if (a == 'play') {
                            QueuePlayer.instance.playOne(QueueItem(
                                l.baseName, widget.api.fileUrl(l.url)));
                          } else if (a == 'keep' && context.mounted) {
                            showKeepDialog(context, widget.api,
                                baseName: l.baseName);
                          }
                        },
                      ),
                    ),
                ],
                if (r.discovery.isNotEmpty) ...[
                  _section(context, 'Discover on YouTube'),
                  for (final d in r.discovery)
                    ListTile(
                      leading: Stack(alignment: Alignment.center, children: [
                        CoverArt(
                            seed: d.channel + d.title,
                            networkUrl:
                                'https://i.ytimg.com/vi/${d.videoId}/mqdefault.jpg'),
                        if (_resolvingId == d.videoId)
                          Container(width: 56, height: 56,
                              color: Colors.black54,
                              child: const Center(child: SizedBox(
                                  width: 22, height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2)))),
                      ]),
                      title: Text('${d.artist} - ${d.title}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Row(children: [
                        if (d.tier == 0)
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: Text('OFFICIAL',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: Spots.green)),
                          ),
                        Expanded(
                          child: Text('${d.channel} · ${_fmt(d.durationS)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white54)),
                        ),
                      ]),
                      onTap: () => _stream(d),
                      trailing: IconButton(
                        icon: const Icon(Icons.more_vert),
                        onPressed: () async {
                          final a = await showTrackMenu<String>(
                              context,
                              '${d.artist} - ${d.title}',
                              _actions(title: d.title, play: () {}, keep: () {}, stage: () {}));
                          if (a != null) await _handle(a, d);
                        },
                      ),
                    ),
                ],
              ]),
      ),
    ]);
  }

  static String _fmt(int s) =>
      '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  Widget _section(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                fontSize: 12.5,
                letterSpacing: .8,
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.primary)),
      );
}
