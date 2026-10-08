import 'dart:async';

import 'package:flutter/material.dart';

import 'api_client.dart';
import 'lang.dart';
import 'screens/my_ytmusic_screen.dart';
import 'toast.dart';

/// Guided playlist import (Settings → Import music): pick a source, paste
/// a PUBLIC playlist link, preview, name it, import. No logins, no keys —
/// the server reads public Spotify embeds / public YouTube Music pages
/// with its own anonymous access.
/// Retry mode (verify-against-source): pass [initialName] + [onlyTracks]
/// to append into the SAME playlist with no rename prompt — the name dialog
/// is skipped and only the missing tracks are queued (server appends).
Future<void> openImportSheet(BuildContext context,
    {required ApiClient api,
    String initialLink = '',
    String initialName = '',
    List<String> onlyTracks = const []}) async {
  // Retry path (verify-against-source) hands us the link directly:
  // infer the source from the host and skip straight to the preview.
  final prelink = initialLink.trim();
  final prespotify =
      prelink.isNotEmpty && (Uri.tryParse(prelink)?.host.toLowerCase() ?? '')
          .contains('spotify');
  // Centered floating menu (not a bottom sheet): the three import
  // sources side by side in the middle of the screen.
  final source = prelink.isNotEmpty
      ? (prespotify ? 'spotify' : 'ytmusic')
      : await showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(tr('Import a playlist')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.music_note_outlined),
            title: Text(tr('From Spotify')),
            subtitle: Text(tr('Paste a playlist link')),
            onTap: () => Navigator.pop(context, 'spotify'),
          ),
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: Text(tr('From YouTube Music')),
            subtitle: Text(tr('Paste a playlist link')),
            onTap: () => Navigator.pop(context, 'ytmusic'),
          ),
          ListTile(
            leading: const Icon(Icons.library_music_outlined),
            title: Text(tr('My YT Music Library')),
            subtitle: Text(tr('Log in, tick playlists, import all')),
            onTap: () => Navigator.pop(context, 'myytmusic'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('Cancel')),
        ),
      ],
    ),
  );
  if (source == null || !context.mounted) return;
  if (source == 'myytmusic') {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MyYtMusicScreen(api: api)),
    );
    return;
  }
  final isSpotify = prespotify || source == 'spotify';
  final linkCtrl = TextEditingController(text: prelink);
  final link = prelink.isNotEmpty
      ? prelink
      : await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(isSpotify ? 'Import from Spotify' : 'Import from YouTube Music'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isSpotify
                ? '1. Open Spotify\n'
                    '2. Open the playlist\n'
                    '3. Share → Copy link\n'
                    '4. Paste it below\n\n'
                    'The playlist must be public.'
                : '1. Open YouTube Music\n'
                    '2. Open the playlist\n'
                    '3. Share → Copy link\n'
                    '4. Paste it below\n\n'
                    'The playlist must be public (unlisted works too).',
            style: const TextStyle(fontSize: 13, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: linkCtrl,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: tr('Playlist link'),
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr('Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, linkCtrl.text.trim()),
          child: Text(tr('Preview')),
        ),
      ],
    ),
  );
  if (link == null || link.isEmpty || !context.mounted) return;
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(child: Text(tr('Reading playlist…'))),
        ],
      ),
    ),
  );
  String listName = '';
  String listCover = '';
  List<Map<String, String>> tracks = [];
  try {
    if (isSpotify) {
      final res = await api.spotifyPlaylistOrder(link, full: true);
      listName = (res['name'] ?? '').toString();
      listCover = (res['cover'] ?? '').toString();
      for (final t in (res['tracks'] as List? ?? [])) {
        if (t is! Map<String, dynamic>) continue;
        final title = (t['title'] ?? '').toString();
        if (title.isEmpty) continue;
        tracks.add({
          'artist': (t['artist'] ?? '').toString(),
          'title': title,
        });
      }
    } else {
      final res = await api.ytmusicPlaylist(link);
      listName = (res['name'] ?? '').toString();
      listCover = (res['cover'] ?? '').toString();
      for (final t in (res['tracks'] as List? ?? [])) {
        if (t is! Map<String, dynamic>) continue;
        final title = (t['title'] ?? '').toString();
        if (title.isEmpty) continue;
        tracks.add({
          'artist': (t['artist'] ?? '').toString(),
          'title': title,
        });
      }
    }
  } catch (e) {
    api.logClientError('import', 'preview $link: $e');
    if (context.mounted) {
      Navigator.pop(context);
      toast(context, "${tr('Could not read playlist')}: $e",
          icon: Icons.error_outline);
    }
    return;
  }
  if (!context.mounted) return;
  Navigator.pop(context);
  if (tracks.isEmpty) {
    toast(context, tr('No tracks found (private playlist?)'),
        icon: Icons.info_outline);
    return;
  }
  // Retry mode: keep only the missing tracks (match on "artist - title",
  // case-insensitive; fall back to the full list if nothing matches).
  if (onlyTracks.isNotEmpty) {
    final want = onlyTracks.map((e) => e.trim().toLowerCase()).toSet();
    final kept = tracks.where((t) {
      final a = (t['artist'] ?? '').trim();
      final ti = (t['title'] ?? '').trim();
      final full = a.isEmpty ? ti : '$a - $ti';
      return want.contains(full.toLowerCase()) ||
          want.contains(ti.toLowerCase());
    }).toList();
    if (kept.isNotEmpty) tracks = kept;
  }
  final retryMode = initialName.trim().isNotEmpty;
  final nameCtrl = TextEditingController(text: retryMode ? initialName.trim() : listName);
  final name = retryMode
      ? initialName.trim()
      : await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('Import playlist')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${tracks.length} songs — they download to the NAS one by '
            'one in order. This takes a while for big lists; progress '
            'lives on the Downloads screen.',
            style: const TextStyle(fontSize: 13, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          Text(
            'First: ${tracks.first['artist']} - ${tracks.first['title']}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: nameCtrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: tr('NAS playlist name'),
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr('Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
          child: Text(tr('Import')),
        ),
      ],
    ),
  );
  if (name == null || name.isEmpty || !context.mounted) return;
  try {
    final res = await api.importStart(name, tracks,
        cover: listCover, source: link);
    if (!context.mounted) return;
    toast(
      context,
      retryMode
          ? "${tr('Adding to')} \"$name\"… (${res['total']})"
          : "${tr('Importing')} ${res['total']} ${tr('songs into')} \"$name\"…",
      icon: Icons.downloading,
    );
  } catch (e) {
    api.logClientError('import', 'start "$name": $e');
    if (context.mounted) {
      toast(context, "${tr('Import failed')}: $e", icon: Icons.error_outline);
    }
  }
}

/// Import progress card for the Downloads/staging area: polls /api/import.
class ImportProgressCard extends StatefulWidget {
  const ImportProgressCard({super.key, required this.api});
  final ApiClient api;

  @override
  State<ImportProgressCard> createState() => _ImportProgressCardState();
}

class _ImportProgressCardState extends State<ImportProgressCard> {
  Map<String, dynamic>? _snap;
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  /// A finished card lingers 6s, then goes away on its own.
  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _snap = null);
    });
  }

  @override
  void initState() {
    super.initState();
    _poll();
  }

  Future<void> _poll() async {
    for (var i = 0; i < 30; i++) {
      try {
        final s = await widget.api.importStatus();
        if (!mounted) return;
        setState(() => _snap = s);
        if (s['running'] != true) {
          _armHide();
          return;
        }
      } catch (_) {
        return;
      }
      await Future.delayed(const Duration(seconds: 10));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _snap;
    if (s == null) return const SizedBox.shrink();
    final total = (s['total'] as num? ?? 0).toInt();
    if (total == 0 && s['running'] != true) {
      return const SizedBox.shrink();
    }
    final done = (s['done'] as num? ?? 0).toInt();
    final failed = (s['failed'] as num? ?? 0).toInt();
    final running = s['running'] == true;
    // Server-verified absent tracks (snap["missing"]) — shown once done.
    final missing = ((s['missing'] as List?) ?? []).map((e) => '$e').toList();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: running
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_circle, color: Colors.green),
            title: Text("${tr('Import')} \"${s['playlist'] ?? ''}\""),
            subtitle: Text(running
                ? '$done/$total… ($failed ${tr('failed')})'
                : "${tr('Done')}: $done/$total ($failed ${tr('failed')})"
                    "${missing.isNotEmpty ? ' · ${missing.length} ${tr('missing')}' : ''}"),
            trailing: running
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      _hideTimer?.cancel();
                      setState(() => _snap = null);
                    },
                  ),
          ),
          if (!running && missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final m in missing.take(10))
                    Text('• $m',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.orangeAccent)),
                  if (missing.length > 10)
                    Text('+${missing.length - 10} ${tr('more')}…',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white38)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
