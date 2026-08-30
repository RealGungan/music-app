import 'package:flutter/material.dart';

import '../api_client.dart';
import '../queue_player.dart';
import '../theme.dart';
import '../widgets.dart';
import 'settings_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.api, required this.onServer});
  final ApiClient api;
  final Future<String?> Function() onServer;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<PlaylistInfo> _playlists = [];
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final pls = await widget.api.playlists();
      if (!mounted) return;
      setState(() {
        _playlists = pls;
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

  Future<void> _create() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController();
        return AlertDialog(
          title: const Text('New playlist'),
          content: TextField(
            controller: c,
            autofocus: true,
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, c.text.trim()),
                child: const Text('Create')),
          ],
        );
      },
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await widget.api.createPlaylist(name);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _openPlaylist(PlaylistInfo pl) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => PlaylistDetailScreen(
                  api: widget.api,
                  name: pl.name,
                )));
    _load();
  }

  Future<void> _deletePlaylist(PlaylistInfo pl) async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text('Delete "${pl.name}"?'),
              content: const Text(
                  'Removes the playlist and its .m3u file. The music '
                  'files themselves are NOT deleted.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Delete')),
              ],
            ));
    if (confirm != true || !mounted) return;
    try {
      await widget.api.deletePlaylist(pl.name);
      await _load();
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
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => openSettings(context,
                baseUrl: widget.api.baseUrl, onServer: widget.onServer),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
              ? Center(child: Text(_error))
              : _playlists.isEmpty
                  ? const Center(
                      child: Text('No playlists yet.',
                          style: TextStyle(color: Colors.white54)))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _playlists.length,
                        itemBuilder: (_, i) {
                          final pl = _playlists[i];
                          return ListTile(
                            leading: Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                gradient: Spots.coverGradient(pl.name),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.queue_music,
                                  color: Colors.white70),
                            ),
                            title: Text(pl.name),
                            subtitle: Text('${pl.tracks} tracks'),
                            trailing: PopupMenuButton<String>(
                              onSelected: (v) {
                                if (v == 'delete') _deletePlaylist(pl);
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete playlist')),
                              ],
                            ),
                            onTap: () => _openPlaylist(pl),
                          );
                        },
                      ),
                    ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Spots.green,
        foregroundColor: Colors.black,
        onPressed: _create,
        child: const Icon(Icons.add),
      ),
    );
  }
}

class PlaylistDetailScreen extends StatefulWidget {
  const PlaylistDetailScreen(
      {super.key, required this.api, required this.name});
  final ApiClient api;
  final String name;

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  List<PlaylistEntry> _entries = [];
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final entries = await widget.api.playlistEntries(widget.name);
      if (!mounted) return;
      setState(() {
        _entries = entries;
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

  Future<void> _playAll() async {
    if (_entries.isEmpty) return;
    final q = _queueForAll();
    if (q.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nothing playable yet.')));
      return;
    }
    await QueuePlayer.instance.playList(q);
  }

  Future<void> _playFrom(int i) async {
    final q = _queueForAll();
    if (q.isEmpty) return;
    final start = _entries
        .take(i)
        .where((e) => e.url != null && e.exists)
        .length
        .clamp(0, q.length - 1);
    await QueuePlayer.instance.playList(q, startIndex: start);
  }

  List<QueueItem> _queueForAll() => [
        for (final e in _entries)
          if (e.url != null && e.exists)
            QueueItem(e.baseName, widget.api.fileUrl(e.url!),
                thumbUrl: widget.api.coverUrl(e.url!)),
      ];

  Future<void> _delete(PlaylistEntry e) async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text('Remove "${e.baseName}" from playlist?'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Remove')),
              ],
            ));
    if (confirm != true || !mounted) return;
    try {
      await widget.api
          .removeFromPlaylist(widget.name, baseName: e.baseName);
      await _load();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $err')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
              ? Center(child: Text(_error))
              : _entries.isEmpty
                  ? const Center(
                      child: Text('Empty playlist.',
                          style: TextStyle(color: Colors.white54)))
                  : Column(children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                                backgroundColor: Spots.green,
                                foregroundColor: Colors.black),
                            onPressed: _playAll,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Play all'),
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _entries.length,
                          itemBuilder: (_, i) {
                            final e = _entries[i];
                            final exists = e.exists;
                            return ListTile(
                              enabled: exists,
                              leading: CoverThumb(
                                title: e.baseName,
                                thumbUrl: e.url != null
                                    ? widget.api.coverUrl(e.url!)
                                    : null,
                              ),
                              title: Text(e.baseName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text(exists ? '' : 'missing on NAS'),
                              trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (exists)
                                      IconButton(
                                        icon: const Icon(Icons.play_arrow),
                                        onPressed: () => _playFrom(i),
                                      ),
                                    PopupMenuButton<String>(
                                      onSelected: (v) {
                                        if (v == 'remove') _delete(e);
                                      },
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                            value: 'remove',
                                            child: Text('Remove from playlist')),
                                      ],
                                    ),
                                  ]),
                              onTap: exists
                                  ? () => _playFrom(i)
                                  : null,
                            );
                          },
                        ),
                      ),
                    ]),
    );
  }
}
