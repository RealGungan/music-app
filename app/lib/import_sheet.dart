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
  // Live feedback while the import runs. The old toast appeared only AFTER
  // importStart resolved, so the user saw nothing at all for the whole
  // server-side download. This dialog is on screen from the start and shows
  // the real per-item counter.
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ImportProgressDialog(
      api: api,
      name: name,
      tracks: tracks,
      cover: listCover,
      source: link,
    ),
  );
}

/// Non-dismissible import progress dialog. Polls the same `/api/import`
/// snapshot as [ImportProgressCard] (`api.importStatus()`), so the counter
/// here and the card on the Downloads screen always agree.
class _ImportProgressDialog extends StatefulWidget {
  const _ImportProgressDialog({
    required this.api,
    required this.name,
    required this.tracks,
    required this.cover,
    required this.source,
  });

  final ApiClient api;
  final String name;
  final List<Map<String, String>> tracks;
  final String cover;
  final String source;

  @override
  State<_ImportProgressDialog> createState() => _ImportProgressDialogState();
}

class _ImportProgressDialogState extends State<_ImportProgressDialog> {
  Timer? _timer;
  int _done = 0;
  int _total = 0;
  int _failed = 0;
  bool _finished = false;
  bool _seenRunning = false;
  final DateTime _startedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final res = await widget.api.importStart(widget.name, widget.tracks,
          cover: widget.cover, source: widget.source);
      if (!mounted) return;
      setState(() => _total = (res['total'] as num? ?? 0).toInt());
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    } catch (e) {
      widget.api.logClientError('import', 'start "${widget.name}": $e');
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, "${tr('Import failed')}: $e", icon: Icons.error_outline);
    }
  }

  Future<void> _tick() async {
    Map<String, dynamic> s;
    try {
      s = await widget.api.importStatus();
    } catch (_) {
      return; // transient network blip — the next tick retries
    }
    if (!mounted) return;
    final done = (s['done'] as num? ?? 0).toInt();
    final total = (s['total'] as num? ?? 0).toInt();
    final running = s['running'] == true;
    // The server can report running=false for a tick or two while it spins
    // the job up, so don't end on the first non-running read unless we
    // already watched it run, it clearly completed, or 15s have passed.
    final finished = !running &&
        (_seenRunning ||
            (total > 0 && done >= total) ||
            DateTime.now().difference(_startedAt).inSeconds > 15);
    setState(() {
      _done = done;
      _total = total > 0 ? total : _total;
      _failed = (s['failed'] as num? ?? 0).toInt();
      _seenRunning = _seenRunning || running;
      _finished = finished;
    });
    if (finished) _timer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final done = _finished;
    return PopScope(
      // No back-dismiss while running (the import keeps going invisibly
      // otherwise); the Done state closes on OK or back.
      canPop: done,
      child: AlertDialog(
        title: Text(done ? tr('Done') : '${tr('Importing')}…'),
        content: Row(
          children: [
            if (done)
              const Icon(Icons.check_circle, color: Colors.green, size: 32)
            else
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '"${widget.name}"',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                  const SizedBox(height: 4),
                  Text(done
                      ? '$_done/$_total${_failed > 0 ? ' ($_failed ${tr('failed')})' : ''}'
                      : '$_done/$_total…'),
                ],
              ),
            ),
          ],
        ),
        actions: done
            ? [
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('OK')),
                ),
              ]
            : null,
      ),
    );
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
  // Import the missing-popup already fired for (playlist|done|count).
  String _missingShownFor = '';

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
          _maybeMissingPopup(s);
          return;
        }
        _missingShownFor = '';
      } catch (_) {
        return;
      }
      await Future.delayed(const Duration(seconds: 10));
    }
  }

  /// Once an import finishes with missing songs, pop a dialog listing
  /// them (Retry-missing + Dismiss) — once per import, not just the card.
  void _maybeMissingPopup(Map<String, dynamic> s) {
    final missing =
        ((s['missing'] as List?) ?? []).map((e) => '$e').toList();
    if (missing.isEmpty) return;
    final key = "${s['playlist']}|${s['done']}|${missing.length}";
    if (_missingShownFor == key) return;
    _missingShownFor = key;
    final playlist = "${s['playlist'] ?? ''}";
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showMissingDialog(playlist, missing);
    });
  }

  Future<void> _showMissingDialog(
      String playlist, List<String> missing) async {
    final retry = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${missing.length} ${tr('missing')}'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final m in missing)
                  Text('• $m',
                      style: const TextStyle(
                          fontSize: 13, color: Colors.orangeAccent)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Dismiss')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Retry in same playlist')),
          ),
        ],
      ),
    );
    if (retry != true || !mounted) return;
    String src = '';
    try {
      src = await widget.api.playlistSource(playlist);
    } catch (_) {}
    if (!mounted) return;
    if (src.isEmpty) {
      toast(context, tr('Could not read playlist'),
          icon: Icons.error_outline);
      return;
    }
    await openImportSheet(context,
        api: widget.api,
        initialLink: src,
        initialName: playlist,
        onlyTracks: missing);
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
