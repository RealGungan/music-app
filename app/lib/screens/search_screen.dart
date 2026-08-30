import 'package:flutter/material.dart';

import '../api_client.dart';
import '../keep_dialog.dart';
import '../queue_player.dart';
import '../theme.dart';
import '../widgets.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  SearchResultPage? _results;
  bool _loading = false;
  bool _resolving = false;
  String _error = '';

  Future<void> _search([String? q]) async {
    final query = (q ?? _controller.text).trim();
    if (query.isEmpty) {
      setState(() {
        _results = null;
        _error = '';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final r = await widget.api.search(query);
      if (!mounted) return;
      setState(() {
        _results = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _playDiscovery(SearchResultPage r, int i) async {
    final t = r.discovery[i];
    QueuePlayer.instance.resolver = widget.api.resolve;
    setState(() => _resolving = true);
    try {
      final url = await widget.api.resolve(t.videoId);
      final q = List.generate(r.discovery.length, (j) {
        final tj = r.discovery[j];
        final rel = '/staging/resolve/${tj.videoId}';
        return QueueItem('${tj.artist} - ${tj.title}',
            '${widget.api.baseUrl}$rel',
            thumbUrl: widget.api.thumbUrl(tj.videoId),
            videoId: tj.videoId);
      });
      q[i] = QueueItem('${t.artist} - ${t.title}', url,
          thumbUrl: q[i].thumbUrl, videoId: t.videoId);
      await QueuePlayer.instance.playList(q, startIndex: i);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Play failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  void _playLibrary(LibraryTrack t) {
    QueuePlayer.instance.playOne(QueueItem(
      t.baseName,
      widget.api.fileUrl(t.url),
      thumbUrl: widget.api.coverUrl(t.url),
    ));
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
          baseName: '${t.artist} - ${t.title}', playlist: pl);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Saved to "$pl" (queued to download)')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: TextField(
          controller: _controller,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          decoration: InputDecoration(
            hintText: 'Search songs, artists…',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              icon: const Icon(Icons.send),
              onPressed: _search,
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
      if (_loading)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_resolving)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Loading stream…', style: TextStyle(color: Colors.white54)),
          ])),
        )
      else if (_error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Center(child: Text(_error, textAlign: TextAlign.center)),
        )
      else if (_results == null)
        const Expanded(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text('Search your NAS library and the internet.\n\n'
                  'Play anything instantly; save what you like.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54)),
            ),
          ),
        )
      else
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              if (_results!.library.isNotEmpty) ...[
                _sectionHeader('Your library'),
                for (final t in _results!.library)
                  ListTile(
                    leading: CoverThumb(
                        title: t.baseName,
                        thumbUrl: widget.api.coverUrl(t.url)),
                    title: Text(t.baseName,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(t.folder,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: const Icon(Icons.play_arrow),
                      onPressed: () => _playLibrary(t),
                    ),
                    onTap: () => _playLibrary(t),
                  ),
                const SizedBox(height: 8),
              ],
              if (_results!.discovery.isNotEmpty) ...[
                _sectionHeader('Found online'),
                for (var i = 0; i < _results!.discovery.length; i++)
                  _DiscoveryTile(
                    track: _results!.discovery[i],
                    thumbUrl: widget.api
                        .thumbUrl(_results!.discovery[i].videoId),
                    onPlay: () => _playDiscovery(_results!, i),
                    onKeep: () => _keep(_results!.discovery[i]),
                  ),
              ],
              if (_results!.library.isEmpty && _results!.discovery.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                      child: Text('No matches. Try another spelling.',
                          style: TextStyle(color: Colors.white54))),
                ),
            ],
          ),
        ),
    ]);
  }

  Widget _sectionHeader(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Text(t,
            style: const TextStyle(
                fontSize: 13,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
                color: Colors.white54)),
      );
}

class _DiscoveryTile extends StatelessWidget {
  const _DiscoveryTile(
      {required this.track,
      required this.onPlay,
      required this.onKeep,
      this.thumbUrl});
  final DiscoveryTrack track;
  final String? thumbUrl;
  final VoidCallback onPlay;
  final VoidCallback onKeep;

  String get dur => track.durationS > 0
      ? '${track.durationS ~/ 60}:${(track.durationS % 60).toString().padLeft(2, '0')}'
      : '';

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CoverThumb(
        title: '${track.artist} - ${track.title}',
        thumbUrl: track.videoId.isNotEmpty
            ? (thumbUrl ?? 'https://i.ytimg.com/vi/${track.videoId}/mqdefault.jpg')
            : null,
        size: 44,
      ),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${track.artist} · $dur',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          icon: const Icon(Icons.add_circle_outline),
          onPressed: onKeep,
          tooltip: 'Save to playlist',
        ),
        IconButton(
            icon: const Icon(Icons.play_arrow), onPressed: onPlay),
      ]),
    );
  }
}
