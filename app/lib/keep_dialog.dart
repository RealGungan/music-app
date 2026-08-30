import 'package:flutter/material.dart';

import '../api_client.dart';
import '../theme.dart';

/// Bottom sheet to pick an existing playlist or create a new one.
class KeepPlaylistSheet extends StatefulWidget {
  const KeepPlaylistSheet({super.key, this.api});
  final ApiClient? api;

  @override
  State<KeepPlaylistSheet> createState() => _KeepPlaylistSheetState();
}

class _KeepPlaylistSheetState extends State<KeepPlaylistSheet> {
  late Future<List<PlaylistInfo>> _future;
  final _newName = TextEditingController();

  @override
  void initState() {
    super.initState();
    _future = _api.playlists();
  }

  ApiClient get _api => widget.api ?? ServerContext.of(context);

  Future<void> _createNew() async {
    final name = _newName.text.trim();
    if (name.isEmpty) return;
    await _api.createPlaylist(name);
    if (mounted) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Save to playlist',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          TextField(
            controller: _newName,
            decoration: InputDecoration(
              hintText: 'New playlist name…',
              filled: true,
              fillColor: Spots.subtle,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
              suffixIcon: TextButton(
                onPressed: _createNew,
                child: const Text('Create',
                    style: TextStyle(color: Spots.green)),
              ),
            ),
            onSubmitted: (_) => _createNew(),
          ),
          const SizedBox(height: 8),
          FutureBuilder<List<PlaylistInfo>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final pls = snap.data ?? [];
              if (pls.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No playlists yet.',
                      style: TextStyle(color: Colors.white54)),
                );
              }
              return Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: pls.length,
                  itemBuilder: (_, i) => ListTile(
                    leading: const Icon(Icons.queue_music,
                        color: Colors.white70),
                    title: Text(pls[i].name),
                    subtitle: Text('${pls[i].tracks} tracks'),
                    onTap: () => Navigator.pop(context, pls[i].name),
                  ),
                ),
              );
            },
          ),
        ]),
      ),
    );
  }
}

/// InheritedWidget exposing the server base URL to any subtree.
class ServerContext extends InheritedWidget {
  const ServerContext({super.key, required this.api, required super.child});
  final ApiClient api;

  static ApiClient of(BuildContext context) =>
      (context.dependOnInheritedWidgetOfExactType<ServerContext>()!).api;

  @override
  bool updateShouldNotify(ServerContext oldWidget) => api != oldWidget.api;
}
