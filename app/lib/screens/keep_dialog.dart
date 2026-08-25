import 'package:flutter/material.dart';

import '../api_client.dart';

/// Pick an existing playlist or type a new name; adds [baseName] to it.
/// Works whether the track is staged, downloading, kept or unknown —
/// the server handles staging/queueing transparently.
Future<void> showKeepDialog(
    BuildContext context, ApiClient api,
    {String? downloadId, required String baseName}) async {
  String? selected;
  final newController = TextEditingController();
  List<PlaylistInfo> playlists = [];
  try {
    playlists = await api.playlists();
  } catch (_) {}

  if (!context.mounted) return;
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text('Add "$baseName" to…'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: playlists.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('No playlists yet. Create one below.'),
                      )
                    : RadioGroup<String>(
                        groupValue: selected,
                        onChanged: (v) => setState(() {
                          selected = v;
                          newController.clear();
                        }),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: playlists.length,
                          itemBuilder: (ctx, i) => RadioListTile<String>(
                            dense: true,
                            value: playlists[i].name,
                            title: Text(
                                '${playlists[i].name} (${playlists[i].tracks})'),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: newController,
                decoration: const InputDecoration(
                  labelText: 'New playlist',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() => selected = null),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final typed = newController.text.trim();
              Navigator.pop(ctx, selected ?? (typed.isEmpty ? null : typed));
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );

  if (result == null || !context.mounted) return;
  try {
    await api.addToPlaylist(
        downloadId: downloadId, baseName: baseName, playlist: result);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added to "$result"')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    }
  }
}
