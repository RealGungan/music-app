import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:math';
import 'dart:typed_data';

import '../api_client.dart';
import '../auth_store.dart';
import '../import_sheet.dart';
import '../lang.dart';
import '../meta_cache.dart';
import '../offline_store.dart';
import '../prefetch_store.dart';
import '../queue/text_norm.dart';
import '../queue_player.dart';
import '../song_context.dart';
import '../theme.dart';
import '../toast.dart';
import '../widgets.dart';
import 'my_ytmusic_screen.dart';
import 'settings_screen.dart';
import 'user_errors_screen.dart';

/// Slim offline notice: metadata is last-known, grey songs need a
/// connection. Shared by the library list and playlist detail headers.
Widget offlineBanner() => Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.wifi_off_outlined,
              size: 15, color: Colors.white54),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tr('Offline — saved lists. Grey songs need connection.'),
              style:
                  const TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ),
        ],
      ),
    );

/// A dead route learned the hard way: transport probes can't see a
/// WiFi-without-internet, but a failed server call proves it. Flip the
/// shared flag so banners, popups and the downloaded-only filter engage
/// correctly from here on (a reconnect flips it back via the listener).
/// File-level so both the library list and the playlist detail states
/// share it.
void _learnOffline(Object e) {
  if (e is SocketException ||
      e is TimeoutException ||
      e is HttpException) {
    QueuePlayer.instance.isOffline.value = true;
  }
}

/// Verify a NAS playlist against the public link it was imported from.
/// File-level so the library list menu, the list ⋮ menu and the playlist
/// detail screen all share it: auto source (detail carries the remembered
/// link, /api/playlist-source is the fallback), else a paste prompt;
/// then a norm-compare (same recipe as match-Spotify-order) showing the
/// missing tracks with Retry (re-import from the same link) + Cancel.
Future<void> _verifyAgainstSource(
    BuildContext context, ApiClient api, String playlistName) async {
  String src = '';
  List<PlaylistEntry> have = [];
  try {
    final d = await api.playlistEntries(playlistName);
    src = d.source;
    have = d.entries;
  } catch (_) {}
  if (src.isEmpty) {
    try {
      src = await api.playlistSource(playlistName);
    } catch (_) {}
  }
  if (!context.mounted) return;
  if (src.isEmpty) {
    final c = TextEditingController();
    src = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('Verify against source')),
            content: TextField(
              controller: c,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                  hintText: 'music.youtube.com / open.spotify.com'),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, c.text.trim()),
                child: Text(tr('Verify against source')),
              ),
            ],
          ),
        ) ??
        '';
    if (!context.mounted) return;
  }
  if (src.isEmpty) return;
  // Source order via the same resolvers the importer uses (no auth either
  // way): Spotify links keep their full order, YTM links theirs.
  List<dynamic> tracks = [];
  try {
    final host = Uri.tryParse(src)?.host.toLowerCase() ?? '';
    final res = host.contains('spotify')
        ? await api.spotifyPlaylistOrder(src)
        : await api.ytmusicPlaylist(src);
    tracks = (res['tracks'] as List?) ?? [];
  } catch (e) {
    if (context.mounted) {
      toast(context, "${tr('Could not read playlist')}: $e",
          icon: Icons.error_outline);
    }
    return;
  }
  if (!context.mounted) return;
  final remaining = have.map((e) => e.baseName).toList();
  final missing = <String>[];
  for (final t in tracks) {
    if (t is! Map) continue;
    final st = normCore((t['title'] ?? '').toString());
    if (st.isEmpty) continue;
    final sa = normArtist((t['artist'] ?? '').toString());
    String? hit;
    for (final b in remaining) {
      final parts = b.split(' - ');
      final bt = parts.length > 1
          ? normCore(parts.sublist(1).join(' - '))
          : normCore(b);
      if (bt != st) continue;
      if (sa.isNotEmpty && parts.isNotEmpty) {
        final ba = normArtist(parts.first);
        if (ba.isNotEmpty && sa.isNotEmpty && ba != sa) continue;
      }
      hit = b;
      break;
    }
    if (hit != null) {
      remaining.remove(hit);
    } else {
      final a = (t['artist'] ?? '').toString().trim();
      final ti = (t['title'] ?? '').toString().trim();
      missing.add(a.isEmpty ? ti : '$a - $ti');
    }
  }
  if (!context.mounted) return;
  final retry = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(missing.isEmpty
          ? tr('Verify against source')
          : '${missing.length} ${tr('missing')}'),
      content: SizedBox(
        width: double.maxFinite,
        child: missing.isEmpty
            ? Text(tr('Done'))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final m in missing.take(15))
                    Text('• $m',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.orangeAccent)),
                  if (missing.length > 15)
                    Text('+${missing.length - 15} ${tr('more')}…',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white38)),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(tr('Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('Retry in same playlist')),
        ),
      ],
    ),
  );
  if (retry == true && context.mounted && missing.isNotEmpty) {
    await openImportSheet(context,
        api: api,
        initialLink: src,
        initialName: playlistName,
        onlyTracks: missing);
  }
}

class LibraryScreen extends StatefulWidget {  const LibraryScreen({super.key, required this.api, required this.onServer});
  final ApiClient api;
  final Future<String?> Function() onServer;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<PlaylistInfo> _playlists = [];
  bool _loading = true;
  String _error = '';
  // 0 = full list (reorderable), 1 = covers grid, 2 = compact list.
  int _view = 0;
  // Reconnect: refresh the list silently (offline snapshot may be stale).
  // Edge-triggered: the emitter fires on every emission, not transitions.
  bool _wasOffline = false;
  void _syncOnline() async {
    final off = QueuePlayer.instance.isOffline.value;
    if (!off && _wasOffline) {
      // We know we're back online - force a full server refresh without
      // re-checking ping (which could flap and cause offline filtering).
      _load(forceOnline: true);
      // Backfill covers for old downloads when coming back online.
      unawaited(OfflineStore.backfillCovers().then((_) {
        if (mounted) setState(() {});
      }));
      // Backfill playlist covers for playlists with covers but no local cache.
      unawaited(_backfillPlaylistCovers().then((_) {
        if (mounted) setState(() {});
      }));
    }
    _wasOffline = off;
  }

  /// Backfill missing playlist covers from server URLs to local cache.
  Future<void> _backfillPlaylistCovers() async {
    for (final pl in _playlists) {
      if (pl.hasCover) {
        final local = OfflineStore.playlistCoverFileFor(pl.name);
        if (local == null) {
          await OfflineStore.cachePlaylistCover(pl.name, widget.api.playlistCoverUrl(pl.name));
        }
      }
    }
  }

  @override
  void initState() {
    super.initState();
    QueuePlayer.instance.isOffline.addListener(_syncOnline);
    _load();
    // Backfill covers for downloads made before pre-caching existed.
    // Gated on actual NAS reachability (not just connectivity flag): with
    // no NAS reachable every fetch would fail and no cover would land.
    // Silent, bounded — rows repaint with art as files land.
    unawaited(widget.api.ping().then((reachable) {
      if (reachable && mounted) {
        OfflineStore.backfillCovers().then((_) {
          if (mounted) setState(() {});
        });
        // Also backfill playlist covers for playlists with covers set.
        _backfillPlaylistCovers().then((_) {
          if (mounted) setState(() {});
        });
      }
    }));
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() => _view = prefs.getInt('library.view') ?? 0);
      }
    });
  }

  @override
  void dispose() {
    QueuePlayer.instance.isOffline.removeListener(_syncOnline);
    super.dispose();
  }

Future<void> _load({bool forceOnline = false}) async {
    // 1. Fast reachability probe FIRST (avoids 20s server timeout when
    //    WiFi is up but NAS is down). Flag-true short-circuits with zero delay.
    //    Skip ping if forceOnline=true (e.g., coming back from offline sync).
    final offline = forceOnline
        ? false
        : (QueuePlayer.instance.isOffline.value ||
            await widget.api.ping().then((online) => !online));
    if (!mounted) return;

    // 2. Instant local: snapshot cache, else downloads. Filter OFFLINE playlists
    //    BEFORE render so there's no flash of all playlists.
    List<PlaylistInfo> local = [];
    try {
      local = await MetaCache.loadPlaylists(
          AuthStore.instance.username ?? '');
      if (local.isEmpty) local = _downloadsFallback();
    } catch (_) {}
    if (!mounted) return;

    if (offline) {
      // Filter to downloaded-only playlists BEFORE first render
      local = local.where((p) =>
          p.name == tr('Downloads') ||
          OfflineStore.songsIn(p.name).isNotEmpty).toList();
    }

    setState(() {
      _loading = local.isEmpty;
      _error = '';
      if (local.isNotEmpty) _playlists = local;
    });
    if (offline) {
      // Offline with nothing cached used to spin forever (_loading stuck
      // true). Show the error instead; cached rows show with the badge.
      QueuePlayer.instance.isOffline.value = true;
      setState(() {
        _loading = false;
        if (_playlists.isEmpty) {
          _error = tr('No connection and nothing saved yet.');
        }
      });
      return;
    }

    // 3. Server refresh when reachable (silent — never flashes a spinner).
    // Capped at 6s: a reachable-looking route with a dead server must fall
    // back to the cached rows, not spin on the 20s API timeout.
    try {
      // Server returns playlists in the persisted display order (respects a
      // user drag-reorder); a fresh custom order from the server wins.
      final pls = await widget.api
          .playlists()
          .timeout(const Duration(seconds: 6));
      if (!mounted) return;
      setState(() {
        _playlists = pls;
        _loading = false;
        _error = '';
      });
      MetaCache.savePlaylists(
          AuthStore.instance.username ?? '', pls);
    } catch (e) {
      if (!mounted) return;
      _learnOffline(e);
      setState(() {
        _loading = false;
        if (_playlists.isEmpty) {
          _error = tr('No connection and nothing saved yet.');
        }
        // else: keep showing the local lists (already on screen).
      });
    }
  }

  /// Offline library from what's actually on the phone (bucket name for
  /// loose downloads). Empty when nothing is saved.
  List<PlaylistInfo> _downloadsFallback() {
    final names =
        OfflineStore.playlists().where((p) => p.isNotEmpty).toList();
    final loose = OfflineStore.songsIn('').length;
    if (names.isEmpty && loose == 0) return const [];
    return [
      for (final p in names)
        PlaylistInfo(name: p, tracks: OfflineStore.songsIn(p).length),
      if (loose > 0) PlaylistInfo(name: tr('Downloads'), tracks: loose),
    ];
  }

  void _reorderPlaylists(int oldIndex, int newIndex) {
    // The reorderable list carries a header at index 0, so a playlist at
    // _playlists[p] sits at list index p+1. Convert back to playlist indices.
    final o = oldIndex - 1;
    var n = newIndex - 1;
    if (o < 0 || o >= _playlists.length) return;
    if (n < 0) return;
    if (n > _playlists.length) n = _playlists.length;
    if (o == n) return;
    setState(() {
      final it = _playlists.removeAt(o);
      _playlists.insert(n, it);
    });
    // Persist the new order to the server (best-effort).
    widget.api
        .reorderPlaylists(_playlists.map((p) => p.name).toList())
        .catchError((_) {});
  }

  Future<void> _create() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController();
        return AlertDialog(
          title: Text(tr('New playlist')),
          content: TextField(
            controller: c,
            autofocus: true,
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: Text(tr('Create')),
            ),
          ],
        );
      },
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await widget.api.createPlaylist(name);
      await _load();
    } catch (e) {
      if (mounted) toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
    }
  }

  Future<void> _openPlaylist(PlaylistInfo pl) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaylistDetailScreen(api: widget.api, name: pl.name),
      ),
    );
    _load();
  }

  String _fmtAdded(double ts) {
    final t = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    final now = DateTime.now();
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(t.year, t.month, t.day)).inDays;
    if (days <= 0) return 'today';
    if (days == 1) return 'yesterday';
    if (days < 7) return '$days days ago';
    return '${t.day}/${t.month}/${t.year}';
  }

  /// Change a playlist's cover from the list ⋮ menu (gallery / URL /
  /// remove). Same server calls as the detail photo flow.
  Future<void> _changePlaylistCover(PlaylistInfo pl) async {
    final src = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(tr('Choose from gallery')),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.link_outlined),
              title: Text(tr('From URL')),
              onTap: () => Navigator.pop(context, 'url'),
            ),
            ListTile(
              leading: const Icon(Icons.hide_image_outlined),
              title: Text(tr('Remove cover')),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (src == null || !mounted) return;
    try {
      if (src == 'remove') {
        await widget.api.deletePlaylistCover(pl.name);
        unawaited(OfflineStore.removePlaylistCover(pl.name));
      } else if (src == 'url') {
        final controller = TextEditingController();
        final url = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('Image URL')),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                child: Text(tr('Use')),
              ),
            ],
          ),
        );
        if (url == null || url.isEmpty || !mounted) return;
        final bytes = await widget.api.fetchBytes(url);
        if (bytes == null || !mounted) return;
        await widget.api.uploadPlaylistCover(pl.name, bytes);
        // Cache cover locally for offline access
        unawaited(OfflineStore.cachePlaylistCover(pl.name, widget.api.playlistCoverUrl(pl.name)));
      } else {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 800,
          maxHeight: 800,
          imageQuality: 88,
        );
        if (picked == null || !mounted) return;
        final bytes = await picked.readAsBytes();
        await widget.api.uploadPlaylistCover(pl.name, bytes);
        // Cache cover locally for offline access
        unawaited(OfflineStore.cachePlaylistCover(pl.name, widget.api.playlistCoverUrl(pl.name)));
      }
      coverRevNotifier.value++;
      await _load();
      if (mounted) toast(context, tr('Cover updated'), icon: Icons.check_circle);
    } catch (e) {
      if (mounted) {
        toast(context, "${tr('Cover failed')}: $e", icon: Icons.error_outline);
      }
    }
  }

  Future<void> _renamePlaylist(PlaylistInfo pl) async {
    final controller = TextEditingController(text: pl.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Rename playlist')),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          decoration: InputDecoration(
            labelText: tr('New name'),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Rename')),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == pl.name || !mounted) return;
    try {
      await widget.api.renamePlaylist(pl.name, name);
      await _load();
      if (mounted) {
        toast(context, "${tr('Renamed to')} \"$name\"", icon: Icons.check_circle);
      }
    } catch (e) {
      if (mounted) {
        toast(context, "${tr('Rename failed')}: $e", icon: Icons.error_outline);
      }
    }
  }

  Future<void> _deletePlaylist(PlaylistInfo pl) async {    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Delete ') + '"${pl.name}"?'),
        content: Text(
          tr('Removes the playlist and its .m3u file. The music ') +
              tr('files themselves are NOT deleted.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Delete')),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    // Snapshot entries for undo BEFORE deleting.
    List<String> bases = [];
    try {
      final d = await widget.api.playlistEntries(pl.name);
      bases = d.entries.map((e) => e.baseName).toList();
    } catch (_) {}
    // Optimistic: vanish from the view instantly; the server confirms
    // in the background (its list cache lags a plain reload).
    setState(() => _playlists.removeWhere((p) => p.name == pl.name));
    try {
      await widget.api.deletePlaylist(pl.name);
    } catch (e) {
      if (mounted) {
        await _load();
        toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
      }
      return;
    }
    if (!mounted) return;
    showUndoBar(context, "${tr('Deleted')} \"${pl.name}\"",
        () => _undeletePlaylist(pl.name, bases));
    await _load();
  }

  /// Restore a just-deleted playlist (undo): recreate + re-add entries
  /// in their original order. The custom cover survives a delete (the
  /// server only removes the .m3u), so it comes back too.
  Future<void> _undeletePlaylist(String name, List<String> bases) async {
    try {
      await widget.api.createPlaylist(name);
      for (final b in bases) {
        try {
          await widget.api.addToPlaylist(baseName: b, playlist: name);
        } catch (_) {}
      }
      await _load();
      if (mounted) toast(context, tr('Playlist restored'));
    } catch (e) {
      if (mounted) {
        await _load();
        toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
      }
    }
  }

  /// Long-press menu for a playlist (all three view modes): Play with the
  /// remembered shuffle choice, Shuffle toggle, Download, Change cover,
  /// Delete. A bottom sheet (themed) — no selection visuals to mismatch.
  Future<void> _playlistMenu(PlaylistInfo pl) async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final sh0 = prefs.getBool('pl.shuffle.${pl.name}') ?? false;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: Text("${tr('Play')} ${pl.name}"),
              onTap: () => Navigator.pop(context, 'play'),
            ),
            ListTile(
              leading: const Icon(Icons.shuffle),
              title: Text(tr('Shuffle')),
              trailing: sh0
                  ? const Icon(Icons.check,
                      color: Colors.green, size: 20)
                  : null,
              onTap: () => Navigator.pop(context, 'shuffle'),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_upward),
              title: Text(tr('Move up')),
              onTap: () => Navigator.pop(context, 'up'),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_downward),
              title: Text(tr('Move down')),
              onTap: () => Navigator.pop(context, 'down'),
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: Text(tr('Download playlist')),
              onTap: () => Navigator.pop(context, 'download'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: Text(tr('Change cover')),
              onTap: () => Navigator.pop(context, 'cover'),
            ),
            ListTile(
              leading: const Icon(Icons.fact_check_outlined),
              title: Text(tr('Verify against source')),
              onTap: () => Navigator.pop(context, 'verify'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(tr('Delete playlist')),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    // Reorder the LIBRARY list itself (works from any view mode).
    final p = _playlists.indexWhere((x) => x.name == pl.name);
    if (action == 'up') {
      if (p > 0) _reorderPlaylists(p + 1, p);
      return;
    }
    if (action == 'down') {
      if (p >= 0 && p < _playlists.length - 1) {
        _reorderPlaylists(p + 1, p + 2);
      }
      return;
    }
    if (action == 'download') {
      await _downloadWholePlaylist(pl);
      return;
    }
    if (action == 'cover') {
      await _changePlaylistCover(pl);
      return;
    }
    if (action == 'verify') {
      await _verifyAgainstSource(context, widget.api, pl.name);
      return;
    }
    if (action == 'delete') {
      await _deletePlaylist(pl);
      return;
    }
    if (action == 'shuffle') {
      final cur = prefs.getBool('pl.shuffle.${pl.name}') ?? false;
      await prefs.setBool('pl.shuffle.${pl.name}', !cur);
      if (mounted) {
        toast(context, !cur ? tr('Shuffle on') : tr('Shuffle off'),
            icon: Icons.shuffle);
      }
      return;
    }
    // Play with the remembered shuffle choice.
    final sh = prefs.getBool('pl.shuffle.${pl.name}') ?? false;
    PlaylistDetail? detail;
    try {
      detail = await widget.api.playlistEntries(pl.name);
    } catch (_) {
      detail = null;
    }
    if (detail == null || !mounted) return;
    final q = <QueueItem>[];
    for (final e in detail.entries) {
      if (e.url != null) {
        final t = widget.api.thumbFor(e);
        q.add(QueueItem(
          e.baseName,
          widget.api.fileUrl(e.url!),
          thumbUrl: t.isEmpty ? null : t,
          liked: e.liked,
        ));
      }
    }
    if (q.isEmpty || !mounted) return;
    if (sh) q.shuffle();
    await QueuePlayer.instance.playList(
      q,
      startIndex: 0,
      playFromPlaylist: true,
      playlistName: pl.name,
    );
    QueuePlayer.instance.shuffleEnabled.value = sh;
    prefs.setBool('pl.shuffle.${pl.name}', sh);
  }

  Future<void> _downloadWholePlaylist(PlaylistInfo pl) async {
    if (!mounted) return;
    PlaylistDetail? detail;
    try {
      detail = await widget.api.playlistEntries(pl.name);
    } catch (_) {
      detail = null;
    }
    if (detail == null || !mounted) {
      if (mounted) {
        toast(context, tr('Could not load playlist'), icon: Icons.error_outline);
      }
      return;
    }
    final items = <QueueItem>[];
    for (final e in detail.entries) {
      if (e.url != null) {
        final t = widget.api.thumbFor(e);
        items.add(QueueItem(
          e.baseName,
          widget.api.fileUrl(e.url!),
          thumbUrl: t.isEmpty ? null : t,
          liked: e.liked,
        ));
      }
    }
    if (items.isEmpty || !mounted) return;
    final total = items.length;
    var done = 0;
    var skipped = 0;
    String? stopped;
    final progress = ValueNotifier<int>(0);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (_, v, __) => Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Expanded(child: Text(tr('Downloading ') + '$v/$total…')),
            ],
          ),
        ),
      ),
    );
    for (final item in items) {
      if (OfflineStore.isDownloaded(item.title)) {
        skipped++;
      } else {
try {
          await OfflineStore.download(
            base: item.title,
            url: item.url,
            playlist: pl.name,
            thumb: item.thumbUrl,
            api: widget.api,
          );
        } on OfflineQuotaError catch (e) {
          stopped = e.message;
          break;
        } catch (_) {
          skipped++;
        }
      }
      done++;
      progress.value = done;
    }
    progress.dispose();
    if (!mounted) return;
    Navigator.pop(context);
    toast(
      context,
      stopped ?? "${done - skipped}/$total ${tr('saved to phone')}"
          "${skipped > 0 ? ' (${tr('skipped')} $skipped)' : ''}",
      icon: stopped != null ? Icons.error_outline : Icons.check_circle,
    );
  }

  /// "Playlists" header with the view-mode switcher (list / covers / compact)
  /// plus the Wrapped season banner when published.
  Widget _listHeader({bool keyed = false}) => Padding(
        key: keyed ? const ValueKey('playlists-header') : null,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: QueuePlayer.instance.isOffline,
              builder: (_, off, __) =>
                  off ? offlineBanner() : const SizedBox.shrink(),
            ),
            Row(
              children: [
            Text(
              tr('Playlists'),
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 8),
            Text(
              '${_playlists.length}',
              style: const TextStyle(color: Colors.white38),
            ),
            const Spacer(),
            IconButton(
              tooltip: _view == 0
                  ? tr('Covers grid')
                  : _view == 1
                      ? tr('Compact list')
                      : tr('Full list'),
              icon: Icon(
                _view == 0
                    ? Icons.grid_view_outlined
                    : _view == 1
                        ? Icons.view_list_outlined
                        : Icons.list_outlined,
                size: 22,
                color: Colors.white70,
              ),
              onPressed: () async {
                setState(() => _view = (_view + 1) % 3);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setInt('library.view', _view);
              },
            ),
          ],
        ),
          ],
      ),
      );

  /// Playlist cover art (or gradient placeholder), busting cache on change.
  /// Square tiles everywhere (radius 12); grid spacing lives in _gridView.
  /// Null [size] fills the parent (grid cells); otherwise a fixed box.
  Widget _coverArt(PlaylistInfo pl, [double? size]) {
    // Offline-first: local cached playlist cover renders instantly.
    final local = OfflineStore.playlistCoverFileFor(pl.name);
    final cover =
        pl.hasCover ? widget.api.playlistCoverUrl(pl.name) : null;
    final iconSize = size == null ? 48.0 : size / 2;
    return ValueListenableBuilder<int>(
      valueListenable: coverRevNotifier,
      builder: (_, rev, __) => Hero(
        tag: 'pl-avatar-${pl.name}',
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: local != null
              ? Image.file(
                  File(local),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _gradientFallback(size, iconSize, pl.name),
                )
              : cover == null
                  ? _gradientFallback(size, iconSize, pl.name)
                  : Image.network(
                      '$cover&v=$rev',
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _gradientFallback(size, iconSize, pl.name),
                    ),
        ),
      ),
    );
  }

  Widget _gradientFallback(double? size, double iconSize, String name) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(gradient: Spots.coverGradient(name)),
        child: Icon(Icons.queue_music, color: Colors.white70, size: iconSize),
      );

  /// Covers grid (YouTube-style). Browse-only: reorder + actions live in
  /// the full list mode.
  Widget _gridView() => CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _listHeader()),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            sliver: SliverGrid(
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 24,
                crossAxisSpacing: 20,
                childAspectRatio: 0.82,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final pl = _playlists[i];
                  // Press feedback lives on the cover box itself (themed,
                  // clipped to its rounded shape) — never the whole cell.
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AspectRatio(
                        aspectRatio: 1,
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            splashColor: Spots.green.withOpacity(.22),
                            highlightColor:
                                Spots.green.withOpacity(.12),
                            onTap: () => _openPlaylist(pl),
                            onLongPress: () => _playlistMenu(pl),
                            child: _coverArt(pl),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: () => _openPlaylist(pl),
                        onLongPress: () => _playlistMenu(pl),
                        child: Text(
                          pl.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      Text(
                        fmtTracks(pl.tracks),
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  );
                },
                childCount: _playlists.length,
              ),
            ),
          ),
        ],
      );

  /// Compact list: names + counts only.
  Widget _compactView() => ListView.builder(
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: _playlists.length + 1,
        itemBuilder: (_, i) {
          if (i == 0) return _listHeader();
          final pl = _playlists[i - 1];
          return ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            title: Text(
              pl.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(
              fmtTracks(pl.tracks),
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            onTap: () => _openPlaylist(pl),
            onLongPress: () => _playlistMenu(pl),
          );
        },
      );

  Widget build(BuildContext context) {
    // Throttled inside (announcer pattern): refreshes the gear red dot.
    ErrorDot.refresh(widget.api);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Library')),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: tr('Settings'),
            onPressed: () => openSettings(
              context,
              api: widget.api,
              onServer: widget.onServer,
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error, textAlign: TextAlign.center),
                  ),
                  FilledButton(
                    onPressed: _load,
                    child: Text(tr('Retry')),
                  ),
                ],
              ),
            )
          : _playlists.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('No playlists yet.'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () =>
                          openImportSheet(context, api: widget.api),
                      icon: const Icon(Icons.playlist_add_outlined),
                      label: Text(tr('Import a playlist')),
                    ),
                  ],
                ),
              ),
            )
          : _view == 1
              ? RefreshIndicator(
                  onRefresh: _load,
                  child: _gridView(),
                )
              : _view == 2
                  ? RefreshIndicator(
                      onRefresh: _load,
                      child: _compactView(),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ReorderableListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                buildDefaultDragHandles: false,
                itemCount: _playlists.length + 1,
                onReorderItem: _reorderPlaylists,
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return _listHeader(keyed: true);
                  }
                  final pl = _playlists[i - 1];
                  return ListTile(
                    key: ValueKey('pl-${pl.name}-${i - 1}'),
                    leading: _coverArt(pl, 48),
                    title: Text(pl.name),
                    subtitle: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(fmtTracks(pl.tracks)),
                        if (pl.addedAt != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            tr('Added ') +
                            '${_fmtAdded(pl.addedAt!)}',
                            style: TextStyle(color: Colors.white38),
                          ),
                        ],
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 4),
                            child: Icon(
                              Icons.drag_handle,
                              color: Colors.white38,
                              size: 20,
                            ),
                          ),
                        ),
                        PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'delete') _deletePlaylist(pl);
                            if (v == 'download') _downloadWholePlaylist(pl);
                            if (v == 'cover') _changePlaylistCover(pl);
                            if (v == 'rename') _renamePlaylist(pl);
                            if (v == 'verify') {
                              _verifyAgainstSource(context, widget.api, pl.name);
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'download',
                              child: Text(tr('Download playlist')),
                            ),
                            PopupMenuItem(
                              value: 'verify',
                              child: Text(tr('Verify against source')),
                            ),
                            PopupMenuItem(
                              value: 'cover',
                              child: Text(tr('Change cover')),
                            ),
                            PopupMenuItem(
                              value: 'rename',
                              child: Text(tr('Rename')),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text(tr('Delete playlist')),
                            ),
                          ],
                        ),
                      ],
                    ),
                    onTap: () => _openPlaylist(pl),
                    onLongPress: () => _playlistMenu(pl),
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
  const PlaylistDetailScreen({
    super.key,
    required this.api,
    required this.name,
  });
  final ApiClient api;
  final String name;

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen>
    with SingleTickerProviderStateMixin {
  PlaylistDetail? _detail;
  bool _loading = true;
  bool _busy = false;
  String _error = '';
  final _picker = ImagePicker();

  /// 0 = playlist order, 1 = song length, 2 = date added.
  int _sort = 0;
  bool _reverse = false;
  bool _shuffleOn = false;
  bool _showSort = false;
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  bool _showScrollTop = false;
  // Offline mode: rows not on the phone grey out (metadata still shows).
  bool _offline = false;
  void _syncOffline() async {
    final off = QueuePlayer.instance.isOffline.value;
    final was = _offline;
    if (off == was || !mounted) return;
    setState(() => _offline = off);
    // Back online: force a full server refresh without re-checking ping
    // (which could flap and cause offline filtering).
    if (!off) {
      _load(silent: true, forceOnline: true);
      unawaited(OfflineStore.backfillCovers().then((_) {
        if (mounted) setState(() {});
      }));
    }
  }
  // 0 = header fully shown → 1 = hidden. A timed animation (not a
  // scroll scrub) so collapsing reads as motion at any scroll speed.
  final ValueNotifier<double> _coverShrink = ValueNotifier(0);
  late final AnimationController _collapseCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final CurvedAnimation _collapseCurve = CurvedAnimation(
    parent: _collapseCtrl,
    curve: Curves.easeInOut,
  );

  List<PlaylistEntry> get _entries => _detail?.entries ?? [];

  /// A song is tappable when it exists on the server (online) or lives on
  /// the phone (explicit download or look-ahead cache). Offline, anything
  /// else greys out.
  bool _playable(PlaylistEntry e) =>
      OfflineStore.isDownloaded(e.baseName) ||
      PrefetchStore.has(e.baseName) ||
      (!_offline && e.exists);

  /// [sorted] entries narrowed by the playlist search box (song/title,
  /// case-insensitive substring).
  List<PlaylistEntry> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _sorted;
    return _sorted.where((e) => e.baseName.toLowerCase().contains(q)).toList();
  }

  List<PlaylistEntry> get _sorted {
    final l = _entries;
    final List<PlaylistEntry> r;
    if (_sort == 1) {
      r = [...l]
        ..sort((a, b) {
          final ad = a.durationS, bd = b.durationS;
          if (ad == null && bd == null) return 0;
          if (ad == null) return 1;
          if (bd == null) return -1;
          return ad.compareTo(bd);
        });
    } else if (_sort == 2) {
      // Default: newest playlist additions at the bottom (oldest first).
      r = [...l]
        ..sort((a, b) {
          final at = a.addedAt ?? double.negativeInfinity;
          final bt = b.addedAt ?? double.negativeInfinity;
          return at.compareTo(bt);
        });
    } else {
      r = [...l];
    }
    return _reverse ? r.reversed.toList() : r;
  }

  @override
  void initState() {
    super.initState();
    _offline = QueuePlayer.instance.isOffline.value;
    QueuePlayer.instance.isOffline.addListener(_syncOffline);
    _collapseCtrl.addListener(() {
      _coverShrink.value = _collapseCurve.value;
    });
    _scrollCtrl.addListener(() {
      final show = _scrollCtrl.offset > 300;
      if (show != _showScrollTop) setState(() => _showScrollTop = show);
      if (!_scrollCtrl.hasClients) return;
      // Only the pinned-header variant collapses: in search mode the
      // header scrolls away inside the list on its own — collapsing it
      // too makes it vanish twice as fast.
      if (!_canReorder) {
        if (_collapseCtrl.value != 0) _collapseCtrl.value = 0;
        return;
      }
      // Hysteresis: hide past 120, reopen near the top. Timed animation
      // does the moving — flings collapse gracefully instead of popping.
      if (_scrollCtrl.offset > 120) {
        _collapseCtrl.forward();
      } else if (_scrollCtrl.offset < 40) {
        _collapseCtrl.reverse();
      }
    });
    _loadPlaylistPrefs();
    _load();
  }

  /// Per-playlist view prefs (sort order, reverse, pre-play shuffle intent).
  /// These survive a full app restart so each playlist opens the way the
  /// user left it. Keys are namespaced by playlist name.
  String get _sortKey => 'pl.sort.${widget.name}';
  String get _reverseKey => 'pl.reverse.${widget.name}';
  String get _shuffleKey => 'pl.shuffle.${widget.name}';
  String get _showSortKey => 'pl.showsort.${widget.name}';

  Future<void> _loadPlaylistPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _sort = prefs.getInt(_sortKey) ?? 0;
      _reverse = prefs.getBool(_reverseKey) ?? false;
      _shuffleOn = prefs.getBool(_shuffleKey) ?? false;
      _showSort = prefs.getBool(_showSortKey) ?? false;
    });
  }

  Future<void> _savePlaylistPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_sortKey, _sort);
    await prefs.setBool(_reverseKey, _reverse);
    await prefs.setBool(_shuffleKey, _shuffleOn);
    await prefs.setBool(_showSortKey, _showSort);
  }

  @override
  void dispose() {
    QueuePlayer.instance.isOffline.removeListener(_syncOffline);
    _scrollCtrl.dispose();
    _collapseCtrl.dispose();
    _coverShrink.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// [silent] skips the full-screen spinner (pull-to-refresh keeps the
  /// list visible and just swaps in fresh rows — e.g. after a check-songs
  /// replacement lands in the same file slot).
  /// [forceOnline] skips the background offline check (used when we know
  /// we're back online from the connectivity listener).
  Future<void> _load({bool silent = false, bool forceOnline = false}) async {
    // 1. Instant local: snapshot cache, else downloads. Render immediately
    //    (no spinner when we have anything to show) — the server then
    //    refreshes silently underneath.
    PlaylistDetail? local;
    try {
      final user = AuthStore.instance.username ?? '';
      final cached = await MetaCache.loadEntries(user, widget.name);
      if (cached.isNotEmpty) {
        local = PlaylistDetail(name: widget.name, entries: cached);
      } else {
        local = _downloadsDetail();
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      if (!silent) _loading = true;
      _error = '';
      if (local != null) _detail = _visibleEntries(local, _offline);
    });
    // Backfill missing covers for this playlist (best-effort, fails fast
    // if offline). Runs after render so UI isn't blocked.
    if (local != null) {
      unawaited(_backfillPlaylistCovers(local.entries).then((_) {
        if (mounted) setState(() {});
      }));
    }

    // 2. Fast reachability probe AFTER first render (avoids blocking UI).
    //    Runs in background, updates offline state when complete.
    //    Skip if forceOnline=true (we know we're back online).
    if (!forceOnline) {
      unawaited(_checkAndUpdateOffline(silent: silent));
    }

    // 3. Server refresh when reachable (silent — never flashes a spinner).
    try {
      final detail = await widget.api.playlistEntries(widget.name);
      if (!mounted) return;
      setState(() {
        _detail = _visibleEntries(detail, false);
        _loading = false;
        _error = '';
      });
      MetaCache.saveEntries(AuthStore.instance.username ?? '',
          widget.name, detail.entries);
      // Single batched liked-status top-up (no-op on new servers: the
      // flags already ride in the payload). Never blocks the list.
      unawaited(_backfillLiked(detail));
    } catch (e) {
      if (!mounted) return;
      _learnOffline(e);
      setState(() {
        _loading = false;
        if (_detail == null) {
          _error = tr('No connection and nothing saved yet.');
        } else {
          // A dead route just proved offline: hide rows that can't play.
          _detail = _visibleEntries(_detail!, true);
        }
      });
    }
  }

  /// Background reachability check — updates offline state without blocking UI.
  Future<void> _checkAndUpdateOffline({bool silent = false}) async {
    final offline = QueuePlayer.instance.isOffline.value ||
        await widget.api.ping().then((online) => !online);
    if (!mounted) return;
    setState(() {
      if (!silent) _loading = false;
      _offline = offline;
      if (_detail != null) {
        _detail = _visibleEntries(_detail!, offline);
      }
    });
    // If back online, refresh from server and backfill covers.
    if (!offline) {
      try {
        final detail = await widget.api.playlistEntries(widget.name);
        if (!mounted) return;
        setState(() {
          _detail = _visibleEntries(detail, false);
          _loading = false;
          _error = '';
        });
        MetaCache.saveEntries(AuthStore.instance.username ?? '',
            widget.name, detail.entries);
        // Backfill playlist cover if missing.
        unawaited(_backfillPlaylistCover().then((_) {
          if (mounted) setState(() {});
        }));
      } catch (e) {
        if (!mounted) return;
        _learnOffline(e);
      }
    }
  }

  /// Backfill playlist cover from server if missing locally.
  Future<void> _backfillPlaylistCover() async {
    if (_detail != null && _detail!.entries.isNotEmpty) {
      // Check if this playlist has a cover on the server.
      final playlists = await widget.api.playlists();
      for (final pl in playlists) {
        if (pl.name == widget.name && pl.hasCover) {
          final local = OfflineStore.playlistCoverFileFor(pl.name);
          if (local == null) {
            await OfflineStore.cachePlaylistCover(pl.name, widget.api.playlistCoverUrl(pl.name));
            return;
          }
        }
      }
    }
  }

  /// Offline detail rows from what's on the phone (null when nothing
  /// saved). The 'Downloads' bucket (see library fallback) holds songs
  /// downloaded outside any playlist.
  PlaylistDetail? _downloadsDetail() {
    final local = widget.name == tr('Downloads')
        ? OfflineStore.songsIn('')
        : OfflineStore.songsIn(widget.name);
    if (local.isEmpty) return null;
    return PlaylistDetail(
      name: widget.name,
      entries: [
        for (final s in local)
          PlaylistEntry(
            baseName: s.base,
            path: '',
            exists: true,
            url: OfflineStore.localUriFor(s.base),
            albumImage: OfflineStore.coverFileFor(s.base) ?? s.thumb,
            inNas: true,
          ),
      ],
    );
  }

  /// Offline mode shows downloaded songs only: rows that can't play
  /// without a connection are hidden instead of teasing. Online shows
  /// everything.
  PlaylistDetail _visibleEntries(PlaylistDetail d, bool offline) {
    if (!offline) return d;
    final kept =
        d.entries.where((e) => OfflineStore.isDownloaded(e.baseName)).toList();
    if (kept.isEmpty || kept.length == d.entries.length) return d;
    return PlaylistDetail(name: d.name, entries: kept);
  }

  /// Best-effort backfill for entries in [entries] that have a thumb but
  /// no local cover file. Fails fast if offline (short HTTP timeout).
  Future<void> _backfillPlaylistCovers(List<PlaylistEntry> entries) async {
    for (final e in entries) {
      if (!OfflineStore.isDownloaded(e.baseName)) continue;
      final localCover = OfflineStore.coverFileFor(e.baseName);
      if (localCover != null) continue;
      final thumb = e.albumImage;
      if (thumb == null || thumb.isEmpty) continue;
      try {
        await OfflineStore.setThumb(e.baseName, thumb);
      } catch (_) {}
    }
  }

  /// ONE batch liked-status call per playlist open. New servers inline
  /// liked flags in the detail payload (nothing to do); older ones don't —
  /// a single call covers the whole list instead of N per-row roundtrips.
  Future<void> _backfillLiked(PlaylistDetail detail) async {
    if (detail.entries.any((e) => e.coverDirect != null)) return;
    Map<String, bool> m;
    try {
      m = await widget.api
          .likedBatch(detail.entries.map((e) => e.baseName).toList())
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      return;
    }
    if (!mounted || m.isEmpty || _detail == null) return;
    setState(() {
      for (var i = 0; i < _detail!.entries.length; i++) {
        final e = _detail!.entries[i];
        final v = m[e.baseName];
        if (v != null && v != e.liked) {
          _detail!.entries[i] = PlaylistEntry(
            baseName: e.baseName,
            path: e.path,
            exists: e.exists,
            url: e.url,
            albumImage: e.albumImage,
            durationS: e.durationS,
            addedAt: e.addedAt,
            liked: v,
            inNas: e.inNas,
            coverDirect: e.coverDirect,
          );
        }
      }
    });
  }

  String get _cover =>
      '${widget.api.playlistCoverUrl(widget.name)}&v=${coverRevNotifier.value}';

  Future<void> _playAll() async {
    final q = _queueForAll();
    if (q.isEmpty) {
      toast(
        context,
        tr('Nothing playable yet.'),
        icon: Icons.info_outline,
        background: const Color(0xFFF4A100),
      );
      return;
    }
    await _playQueueShuffled(q, startIndex: 0, playAll: true);
  }

  /// Full error text in a dialog with Copy — toasts truncate and vanish.
  Future<void> _spotifyErrorDialog(String msg) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(tr('Spotify failed')),
        content: SelectableText(msg),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: msg));
              Navigator.pop(dctx);
              toast(context, tr('Error copied'), icon: Icons.check_circle);
            },
            child: Text(tr('Copy')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(tr('Close')),
          ),
        ],
      ),
    );
  }

  /// Pasted public link -> embed order (first 100 tracks).
  Future<List<dynamic>> _spotifyLinkTracks() async {
    final controller = TextEditingController();
    final link = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Spotify playlist link')),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://open.spotify.com/playlist/…',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Fetch')),
          ),
        ],
      ),
    );
    if (link == null || link.isEmpty || !mounted) return [];
    if (!mounted) return [];
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(child: Text(tr('Reading Spotify order…'))),
          ],
        ),
      ),
    );
    try {
      final res = await widget.api.spotifyPlaylistOrder(link);
      if (!mounted) return [];
      Navigator.pop(context);
      return (res['tracks'] as List?) ?? [];
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        toast(context, tr('Could not read playlist: ') + '$e',
            icon: Icons.error_outline);
      }
      return [];
    }
  }

  /// Own Spotify login -> full track order. Handles Client ID setup +
  /// browser login + playlist picker. Returns [] on cancel/failure.
  /// Reorder this playlist to match a Spotify playlist's sequence.
  /// Source: a pasted public link (first 100 tracks). Unmatched NAS
  /// entries stay at the end.
  Future<void> _matchSpotifyOrder() async {
    if (!mounted || _entries.isEmpty) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Match Spotify order')),
        content: Text(
          tr('Paste a public Spotify playlist link (first 100 tracks).'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'link'),
            child: Text(tr('Paste link')),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    List<dynamic> tracks;
    tracks = await _spotifyLinkTracks();
    if (tracks.isEmpty) return;
    if (!mounted) return;
    // Match Spotify titles to NAS entries (core-normalized; first
    // unmatched wins, so duplicates consume in order).
    final remaining = _entries.map((e) => e.baseName).toList();
    final ordered = <String>[];
    for (final t in tracks) {
      if (t is! Map<String, dynamic>) continue;
      final st = normCore((t['title'] ?? '').toString());
      if (st.isEmpty) continue;
      final sa = normArtist((t['artist'] ?? '').toString());
      String? hit;
      for (final b in remaining) {
        final parts = b.split(' - ');
        final bt = parts.length > 1
            ? normCore(parts.sublist(1).join(' - '))
            : normCore(b);
        if (bt != st) continue;
        if (sa.isNotEmpty && parts.isNotEmpty) {
          final ba = normArtist(parts.first);
          if (ba.isNotEmpty && sa.isNotEmpty && ba != sa) continue;
        }
        hit = b;
        break;
      }
      if (hit != null) {
        remaining.remove(hit);
        ordered.add(hit);
      }
    }
    if (ordered.isEmpty || !mounted) {
      if (mounted) {
        toast(context, tr('No songs matched — different playlists?'),
            icon: Icons.info_outline);
      }
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Reorder playlist?')),
        content: Text(
          '${ordered.length}/${tracks.length} ${tr('Spotify tracks matched on')} '
          '${tr('this playlist')}. ${remaining.length} ${tr('unmatched stay at the end.')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Reorder')),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      final res = await widget.api.setPlaylistOrder(widget.name, ordered);
      if (!mounted) return;
      toast(
        context,
        "${tr('Reordered')} ${res['reordered']}/${res['total']} "
        "(${res['unlisted_kept']} ${tr('kept at end')})",
        icon: Icons.check_circle,
      );
      await _load(silent: true);
    } catch (e) {
      if (mounted) {
        toast(context, "${tr('Reorder failed')}: $e", icon: Icons.error_outline);
      }
    }
  }

  /// Delete from the detail screen (confirm → server delete → pop back;
  /// the list reloads fresh behind it).
  Future<void> _deletePlaylist() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Delete ') + '"${widget.name}"?'),
        content: Text(
          tr('Removes the playlist and its .m3u file. The music ') +
              tr('files themselves are NOT deleted.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Delete')),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await widget.api.deletePlaylist(widget.name);
    } catch (e) {
      if (mounted) {
        toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
      }
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  /// Rename from the detail screen (tap the playlist name). Pops back —
  /// the name is the route's identity, so the list reloads fresh.
  Future<void> _renameHere() async {
    final controller = TextEditingController(text: widget.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Rename playlist')),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          decoration: InputDecoration(
            labelText: tr('New name'),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(tr('Rename')),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == widget.name || !mounted) {
      return;
    }
    try {
      await widget.api.renamePlaylist(widget.name, name);
      if (!mounted) return;
      toast(context, "${tr('Renamed to')} \"$name\"", icon: Icons.check_circle);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().contains('409')
          ? tr('That name is taken — pick another.')
          : "${tr('Rename failed')}: $e";
      toast(context, msg, icon: Icons.error_outline);
    }
  }

  /// Download the whole playlist to the phone (quota-enforced). Stops at
  /// the first quota refusal and reports how far it got.
  /// "Add songs": NAS picker by default; submitting a query searches
  /// online too (covers on every row). NAS taps append instantly;
  /// online taps download into this playlist via the import worker.
  Future<void> _addSongs() async {
    if (_busy) return;
    List<Map<String, dynamic>> all = [];
    try {
      all = await widget.api.nasIndex();
    } catch (e) {
      if (mounted) _snack("${tr('Failed')}: $e");
      return;
    }
    if (!mounted) return;
    final have = _entries.map((e) => e.baseName).toSet();
    final addedNas = <String>{};
    var addedOnline = 0;
    final filter = TextEditingController();
    List<Suggestion> online = [];
    bool searching = false;
    String searched = '';

    Widget nasList(StateSetter setSheet, BuildContext ctx) {
      final q = filter.text.trim().toLowerCase();
      final rows = all.where((t) {
        final b = (t['base_name'] ?? '').toString();
        if (b.isEmpty || have.contains(b)) return false;
        return q.isEmpty || b.toLowerCase().contains(q);
      }).toList();
      if (rows.isEmpty) {
        return Center(
          child: Text(
            tr('No songs found.'),
            style: const TextStyle(color: Colors.white54),
          ),
        );
      }
      return ListView.builder(
        itemCount: rows.length,
        itemBuilder: (_, i) {
          final b = (rows[i]['base_name'] ?? '').toString();
          final u = (rows[i]['url'] ?? '').toString();
          final done = addedNas.contains(b);
          return ListTile(
            leading: CoverThumb(
              title: b,
              thumbUrl: u.isNotEmpty ? widget.api.coverUrl(u) : null,
              size: 40,
            ),
            title: Text(
              b,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: done
                ? const Icon(Icons.check, color: Colors.green)
                : null,
            onTap: done
                ? null
                : () async {
                    try {
                      await widget.api.addToPlaylist(
                        baseName: b,
                        playlist: widget.name,
                      );
                      addedNas.add(b);
                    } catch (e) {
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text("${tr('Failed')}: $e")));
                      }
                      return;
                    }
                    setSheet(() {});
                  },
          );
        },
      );
    }

    Widget onlineList(StateSetter setSheet, BuildContext ctx) {
      final rows = online.where((s) {
        if (s.isOnline) {
          final key =
              '${s.artist ?? ''} - ${s.title ?? ''}'.trim();
          return key.isNotEmpty && !have.contains(key);
        }
        final b = s.baseName;
        return b.isNotEmpty && !have.contains(b);
      }).toList();
      if (rows.isEmpty) {
        return Center(
          child: Text(
            tr('No songs found.'),
            style: const TextStyle(color: Colors.white54),
          ),
        );
      }
      return ListView.builder(
        itemCount: rows.length,
        itemBuilder: (_, i) {
          final s = rows[i];
          final title = s.isOnline
              ? '${s.artist ?? ''} - ${s.title ?? ''}'.trim()
              : s.baseName;
          final key = '${s.isOnline ? 'net' : 'nas'}:$title';
          final done = addedNas.contains(key);
          return ListTile(
            leading: CoverThumb(
              title: title,
              thumbUrl: s.isOnline
                  ? (s.albumImage ?? '')
                  : (s.url.isNotEmpty
                      ? widget.api.coverUrl(s.url)
                      : null),
              size: 40,
            ),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: s.isOnline && (s.provider ?? '').isNotEmpty
                ? Text(
                    '${s.provider}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12),
                  )
                : null,
            trailing: done
                ? const Icon(Icons.check, color: Colors.green)
                : (s.isOnline ? const Icon(Icons.download_outlined) : null),
            onTap: done
                ? null
                : () async {
                    try {
                      if (s.isOnline) {
                        await widget.api.importStart(widget.name, [
                          {
                            'artist': (s.artist ?? '').toString(),
                            'title': (s.title ?? '').toString(),
                          }
                        ]);
                        addedOnline++;
                      } else {
                        await widget.api.addToPlaylist(
                          baseName: s.baseName,
                          playlist: widget.name,
                        );
                      }
                      addedNas.add(key);
                    } catch (e) {
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text("${tr('Failed')}: $e")));
                      }
                      return;
                    }
                    setSheet(() {});
                  },
          );
        },
      );
    }

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.75,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: TextField(
                    controller: filter,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: tr('Search NAS + online…'),
                      prefixIcon: const Icon(Icons.search),
                      border: const OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.search,
                    onChanged: (_) {
                      if (filter.text.trim().isEmpty &&
                          searched.isNotEmpty) {
                        setSheet(() {
                          online = [];
                          searched = '';
                        });
                      } else {
                        setSheet(() {});
                      }
                    },
                    onSubmitted: (q) async {
                      final t = q.trim();
                      if (t.isEmpty || !ctx.mounted) return;
                      setSheet(() => searching = true);
                      try {
                        online = await widget.api.suggest(t);
                        searched = t;
                      } catch (_) {
                        online = [];
                      }
                      if (ctx.mounted) {
                        setSheet(() => searching = false);
                      }
                    },
                  ),
                ),
                Expanded(
                  child: searching
                      ? const Center(
                          child: CircularProgressIndicator())
                      : (searched.isEmpty
                          ? nasList(setSheet, ctx)
                          : onlineList(setSheet, ctx)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    filter.dispose();
    if (!mounted) return;
    if (addedNas.isNotEmpty || addedOnline > 0) {
      final parts = <String>[];
      final n = addedNas.where((k) => !k.startsWith('net:')).length;
      if (n > 0) parts.add('added $n');
      if (addedOnline > 0) {
        parts.add('downloading $addedOnline into the playlist');
      }
      toast(context, parts.join(', '));
      await _load();
    }
  }

  Future<void> _downloadPlaylist() async {
    final q = _queueForAll();
    if (q.isEmpty || !mounted) return;
    final total = q.length;
    var done = 0;
    var skipped = 0;
    String? stopped;
    final progress = ValueNotifier<int>(0);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (_, v, __) => Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Expanded(child: Text(tr('Downloading ') + '$v/$total…')),
            ],
          ),
        ),
      ),
    );
    for (final item in q) {
      if (OfflineStore.isDownloaded(item.title)) {
        skipped++;
        done++;
        progress.value = done;
        continue;
      }
try {
        await OfflineStore.download(
          base: item.title,
          url: item.url,
          playlist: widget.name,
          thumb: item.thumbUrl,
          api: widget.api,
        );
      } on OfflineQuotaError catch (e) {
        stopped = e.message;
        break;
      } catch (_) {
        skipped++;
      }
      done++;
      progress.value = done;
    }
    progress.dispose();
    if (!mounted) return;
    Navigator.pop(context);
    toast(
      context,
      stopped ?? "${done - skipped}/$total ${tr('saved to phone')}"
          "${skipped > 0 ? ' (${tr('skipped')} $skipped)' : ''}",
      icon: stopped != null ? Icons.error_outline : Icons.check_circle,
    );
  }

  /// Build the final ordered queue from [q] and plays it starting at [startIndex].
  /// If shuffle mode is on, the SELECTED song plays first and the REST is
  /// randomized after it — the tapped song is never displaced by shuffle.
  /// [playAll] distinguishes the "Play All" button (which is allowed to fully
  /// randomize everything) from a tapped row whose startIndex happens to be 0
  /// (which must still play the tapped song first).
  /// Optimistic autoplay (funnel): the head song's audio starts NOW —
  /// prewarmed single-item queue — while the tail appends behind it
  /// instead of blocking first sound on queue assembly.
  Future<void> _playQueueShuffled(
    List<QueueItem> q, {
    required int startIndex,
    bool playAll = false,
  }) async {
    // Once a playlist-driven queue is already active, the SHARED
    // shuffleEnabled is authoritative (the full-screen toggle drives it, and
    // the local _shuffleOn would otherwise go stale / "ghost"). Only before
    // anything is playing do we use the local pre-play intent (_shuffleOn).
    final inPlaylist = QueuePlayer.instance.fromPlaylist.value;
    final shuffle = inPlaylist
        ? QueuePlayer.instance.shuffleEnabled.value
        : _shuffleOn;
    startIndex = startIndex.clamp(0, q.length - 1);
    if (shuffle && q.length > 1) {
      if (playAll) {
        // Play All (no specific song selected): fully randomize the order so
        // the whole playlist is shuffled, not just the tail.
        q = [...q]..shuffle(Random());
      } else {
        // A specific song was tapped with shuffle on: it plays FIRST, the rest
        // randomize after it (the tapped song is never displaced) — even when
        // the tapped song sits at position 0 in the queue.
        final head = q[startIndex];
        final rest = [...q]..removeAt(startIndex);
        rest.shuffle(Random());
        q = [head, ...rest];
        startIndex = 0;
      }
    }
    _shuffleOn = shuffle;
    final head = q[startIndex];
    final tail = [...q]..removeAt(startIndex);
    widget.api.prewarmFile(head.url);
    await QueuePlayer.instance.playList(
      [head],
      startIndex: 0,
      startShuffled: shuffle,
      playFromPlaylist: true,
      playlistName: widget.name,
    );
    for (final it in tail) {
      QueuePlayer.instance.addToQueueEnd(it);
    }
  }

Future<void> _playFrom(int i) async {
    // Dismiss the playlist search keyboard + unselect the search field when a
    // result is tapped, so the list is fully visible while playing.
    FocusManager.instance.primaryFocus?.unfocus();
    if (i < 0 || i >= _filtered.length) return;
    final item = _filtered[i];
    if (!_playable(item)) {
      toast(context, tr('Not on this phone — connect to play'),
          icon: Icons.wifi_off_outlined);
      return;
    }
    // Load the full playlist queue (same path as Play All) so shuffle is
    // respected and autoplay only tops up at the end — it must NOT pull
    // internet tracks when the user tapped a single playlist song.
    final q = _queueForAll();
    if (q.isEmpty) return;
    final targetUrl = _itemUrl(item);
    final startIndex =
        q.indexWhere((qi) => qi.url == targetUrl).clamp(0, q.length - 1);
    await _playQueueShuffled(q, startIndex: startIndex);
  }

  List<QueueItem> _queueForAll() => [
    for (final e in _filtered)
      if (_playable(e))
        QueueItem(
          e.baseName,
          _itemUrl(e),
          thumbUrl: _thumbFor(e),
          liked: e.liked,
        ),
  ];

  /// Row art: direct CDN URL from the single detail payload when the
  /// server knows one (no NAS-proxied bytes over the funnel uplink),
  /// else the proxied cover endpoint (Tailscale path unchanged).
  /// Null = CoverThumb falls back to the playlist cover / gradient.
  String? _thumbFor(PlaylistEntry e) {
    final t = widget.api.thumbFor(e);
    return t.isEmpty ? null : t;
  }

  /// Stream URL for a row, phone-first: a downloaded copy plays from
  /// local storage (instant, works offline) instead of the server URL.
  String _itemUrl(PlaylistEntry e) =>
      OfflineStore.localUriFor(e.baseName) ??
      widget.api.fileUrl(e.url!);

  /// Rename from the detail screen (tap the title). The route's name is
  /// immutable, so a successful rename pops back to the reloaded list.
  Future<void> _delete(PlaylistEntry e) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Remove ') + '"${e.baseName}" from playlist?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Remove')),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    // Snapshot the full order so undo restores the exact position.
    final order = _entries.map((x) => x.baseName).toList();
    try {
      await widget.api.removeFromPlaylist(widget.name, baseName: e.baseName);
      await _load();
    } catch (err) {
      if (mounted) toast(context, "${tr('Failed')}: $err", icon: Icons.error_outline);
      return;
    }
    if (!mounted) return;
    showUndoBar(context, "${tr('Removed')} \"${e.baseName}\"",
        () => _undeleteEntry(e.baseName, order));
  }

  Future<void> _undeleteEntry(String base, List<String> order) async {
    try {
      await widget.api.addToPlaylist(
          baseName: base, playlist: widget.name);
      await widget.api.setPlaylistOrder(widget.name, order);
      await _load();
      if (mounted) toast(context, tr('Song restored'));
    } catch (err) {
      if (mounted) {
        await _load();
        toast(context, "${tr('Failed')}: $err", icon: Icons.error_outline);
      }
    }
  }

  // ------------------------------------------------------------- photos
  void _snack(String msg) {
    if (!mounted) return;
    toast(context, msg);
  }

  // Kept (change-cover entry point): the detail header button that used
  // this is gone, cover changes now start from the list ⋮ menu.
  // ignore: unused_element
  Future<void> _editPhoto() async {
    if (_busy) return;
    final source = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(tr('Use art from a song in this playlist')),
              onTap: () => Navigator.pop(ctx, 'song'),
            ),
            if (defaultTargetPlatform == TargetPlatform.android) ...[
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: Text(tr('Pick a photo from your device')),
                onTap: () => Navigator.pop(ctx, 'gallery'),
              ),
              const Divider(height: 1, color: Colors.white12),
            ],
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(tr('Paste an image URL')),
              onTap: () => Navigator.pop(ctx, 'url'),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_check_outlined),
              title: Text(tr('Use a YouTube Music / Spotify cover')),
              onTap: () => Navigator.pop(ctx, 'source'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(tr('Remove custom photo')),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || source == null) return;
    setState(() => _busy = true);
    try {
      if (source == 'song') {
        // Distinct covers in a grid: fetch every candidate's bytes,
        // hash them, and show each image once (same album art repeats
        // across songs, and per-file URLs can't tell that).
        final cands =
            _entries.where((x) => x.exists && x.url != null).toList();
        final picked = await showModalBottomSheet<PlaylistEntry>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (ctx) => SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.6,
              child: _CoverGridPicker(
                api: widget.api,
                entries: cands,
              ),
            ),
          ),
        );
        if (picked == null) return;
        final bytes = await widget.api.coverBytes(picked.url!);
        if (bytes == null) {
          _snack(tr('No artwork found for that song.'));
          return;
        }
        await widget.api.uploadPlaylistCover(widget.name, bytes);
      } else if (source == 'gallery') {
        final picked = await _picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 800,
          maxHeight: 800,
          imageQuality: 88,
        );
        if (picked == null) {
          _snack(tr('No photo chosen.'));
          return;
        }
        final bytes = await picked.readAsBytes();
        await widget.api.uploadPlaylistCover(widget.name, bytes);
      } else if (source == 'url') {
        final url = await _promptUrl();
        if (url == null) return;
        final bytes = await widget.api.fetchBytes(url);
        if (bytes == null) {
          _snack(tr('Could not fetch that image.'));
          return;
        }
        await widget.api.uploadPlaylistCover(widget.name, bytes);
      } else if (source == 'source') {
        final bytes = await _sourceCoverBytes();
        if (bytes == null) {
          _snack(tr('No cover found.'));
          return;
        }
        await widget.api.uploadPlaylistCover(widget.name, bytes);
      } else if (source == 'remove') {
        await widget.api.deletePlaylistCover(widget.name);
      }
      coverRevNotifier.value++;
      await _load();

      if (source == 'remove') {
        _snack(tr('Custom photo removed.'));
      }
    } catch (e) {
      _snack("${tr('Failed')}: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _promptUrl() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Image URL')),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://…'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: Text(tr('Use')),
          ),
        ],
      ),
    );
  }

  /// Playlist link (YouTube Music / Spotify) for the 'source' cover
  /// option. Host decides which resolver reads the playlist art.
  Future<String?> _promptSourceLink() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Playlist link')),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
              hintText: 'music.youtube.com / open.spotify.com'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: Text(tr('Use')),
          ),
        ],
      ),
    );
  }

  /// Cover from the user's own YouTube Music playlists (pick one from
  /// the import list, covers shown), or a pasted YTM/Spotify link when
  /// that list is unreachable. Spotify has no listing without a login,
  /// so its links stay paste-only.
  Future<Uint8List?> _sourceCoverBytes() async {
    final picked = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            MyYtMusicScreen(api: widget.api, pickCover: true),
      ),
    );
    if (picked != null && picked.isNotEmpty) {
      final bytes = await widget.api.fetchBytes(picked);
      if (bytes != null) return bytes;
    }
    if (!mounted || (picked != null)) return null;
    // Backed out of the list (or its fetch failed): paste a link,
    // resolve its art (YTM or Spotify, no auth either way).
    final link = await _promptSourceLink();
    if (link == null) return null;
    final cover = await _sourcePlaylistCover(link);
    if ((cover ?? '').isEmpty) return null;
    return widget.api.fetchBytes(cover!);
  }

  /// Cover URL of a public YTM/Spotify playlist link ("" when none).
  /// Reuses the importers' order endpoints — no auth either way.
  Future<String?> _sourcePlaylistCover(String link) async {
    final host = Uri.tryParse(link)?.host.toLowerCase() ?? '';
    try {
      if (host.contains('spotify')) {
        final res =
            await widget.api.spotifyPlaylistOrder(link, full: false);
        return (res['cover'] ?? '').toString();
      }
      final res = await widget.api.ytmusicPlaylist(link);
      return (res['cover'] ?? '').toString();
    } catch (_) {
      return null;
    }
  }

  /// Drag-reorder is available in every view except search (a filtered
  /// list has no meaningful drop target). Dropping adopts the visual
  /// order as the new manual order (back to Playlist view).
  bool get _canReorder => _query.trim().isEmpty;

  /// Persist a drag-reorder: optimistic local move (by entry OBJECT, so
  /// duplicate song names keep their identities), server m3u rewrite,
  /// silent reload to confirm.
  Future<void> _reorderSongs(int oldIndex, int newIndex) async {
    final detail = _detail;
    if (detail == null) return;
    if (oldIndex < newIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    // Operate on the VISUAL order (filtered), whatever the sort is.
    final visual = [..._filtered];
    if (oldIndex < 0 ||
        oldIndex >= visual.length ||
        newIndex < 0 ||
        newIndex >= visual.length) {
      return;
    }
    final keep = detail.entries.toList();
    final moved = visual.removeAt(oldIndex);
    visual.insert(newIndex, moved);
    setState(() {
      detail.entries
        ..clear()
        ..addAll([
          ...visual,
          for (final e in keep)
            if (!visual.contains(e)) e,
        ]);
      _sort = 0;
      _reverse = false;
    });
    try {
      await widget.api.setPlaylistOrder(
        widget.name,
        detail.entries.map((e) => e.baseName).toList(),
      );
      await _savePlaylistPrefs();
      await _load(silent: true);
    } catch (e) {
      if (mounted) {
        toast(context, "${tr('Reorder failed')}: $e", icon: Icons.error_outline);
        await _load(silent: true);
      }
    }
  }

  // ------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final shown = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: tr('Delete'),
            onPressed:
                _busy ? null : () => _deletePlaylist(),
          ),
          IconButton(
            icon: const Icon(Icons.photo_outlined),
            tooltip: tr('Change cover'),
            onPressed: _busy ? null : _editPhoto,
          ),
          IconButton(
            icon: const Icon(Icons.fact_check_outlined),
            tooltip: tr('Verify against source'),
            onPressed: _busy
                ? null
                : () =>
                    _verifyAgainstSource(context, widget.api, widget.name),
          ),
        ],
      ),
      bottomNavigationBar: const MiniPlayerBar(),
      floatingActionButton: _showScrollTop
          ? FloatingActionButton.small(
              heroTag: 'pldetail-scrolltop',
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.black,
              onPressed: () => _scrollCtrl.animateTo(
                0,
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOut,
              ),
              child: const Icon(Icons.arrow_upward),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error, textAlign: TextAlign.center),
                  ),
                  FilledButton(
                    onPressed: _load,
                    child: Text(tr('Retry')),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                _header(),
                Expanded(
                  child: shown.isEmpty
                      ? RefreshIndicator(
                          onRefresh: () => _load(silent: true),
                          child: ListView(
                            controller: _scrollCtrl,
                            padding:
                                const EdgeInsets.only(bottom: 24),
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 40),
                                child: Center(
                                  child: _query.isEmpty
                                      ? Text(
                                          tr('Empty playlist.'),
                                          style: TextStyle(
                                              color: Colors.white54),
                                        )
                                      : Text(
                                          tr('No songs match the search.'),
                                          style: TextStyle(
                                              color: Colors.white54),
                                        ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : _canReorder
                          ? Scrollbar(
                        controller: _scrollCtrl,
                        thumbVisibility: true,
                        interactive: true,
                        child: RefreshIndicator(
                          onRefresh: () => _load(silent: true),
                          child: ReorderableListView.builder(
                            scrollController: _scrollCtrl,
                            padding: const EdgeInsets.only(bottom: 24),
                            buildDefaultDragHandles: false,
                            itemCount: shown.length,
                            onReorder: _reorderSongs,
                            itemBuilder: (_, i) {
                              final e = shown[i];
                              return Container(
                                key: ValueKey(e),
                                child: _trackTile(e, i,
                                    reorderHandle: true),
                              );
                            },
                          ),
                        ),
                      )
                : RefreshIndicator(
                  onRefresh: () => _load(silent: true),
                  child: Scrollbar(
                    controller: _scrollCtrl,
                    thumbVisibility: true,
                    interactive: true,
                    child: ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final e = shown[i];
                        return _trackTile(e, i);
                      },
                    ),
                    ),
                    ),
                  ),
            ],
          ),
    );
  }

  Widget _header() {
    final n = _entries.length;    final total = _detail?.totalSeconds;
    final metaParts = [fmtTracks(n)];
    if (total != null && total > 0) {
      metaParts.add('•');
      metaParts.add(fmtTotal(Duration(seconds: total.round())));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_offline) offlineBanner(),
          // Cover + title collapse away as the song list scrolls.
          // Staggered: fade leads, shrink follows (reads as animation
          // instead of a pop).
          ValueListenableBuilder<double>(
            valueListenable: _coverShrink,
            builder: (_, t, __) {
              final e = (t * t * (3 - 2 * t)).clamp(0.0, 1.0);
              final fade = (1 - e * 1.5).clamp(0.0, 1.0);
              if (e >= 1) return const SizedBox.shrink();
              return ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: 1 - e,
                  child: Opacity(
                    opacity: fade,
                    child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              GestureDetector(
                onTap: () => _busy ? null : _editPhoto(),
                child: Hero(
                  tag: 'pl-avatar-${widget.name}',
                  child: _art(_cover, 132),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => _renameHere(),
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                widget.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(
                                        fontWeight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.edit_outlined,
                              size: 16,
                              color: Colors.white38,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      metaParts.join(' '),
                      style: const TextStyle(color: Colors.white60),
                    ),
                  ],
                ),
              ),
            ],
                    ),
                  ),
                ),
              );
            },
          ),
          // Buttons + sort + search collapse with the same motion.
          ValueListenableBuilder<double>(
            valueListenable: _coverShrink,
            builder: (_, t2, __) {
              final e2 = (t2 * t2 * (3 - 2 * t2)).clamp(0.0, 1.0);
              final fade2 = (1 - e2 * 1.5).clamp(0.0, 1.0);
              if (e2 >= 1) return const SizedBox.shrink();
              return ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: 1 - e2,
                  child: Opacity(
                    opacity: fade2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Spots.green,
                  foregroundColor: Colors.black,
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(10),
                ),
                onPressed: _busy ? null : () => _playAll(),
                child: const Icon(
                  Icons.play_arrow,
                  size: 22,
                  color: Colors.black,
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<bool>(
                valueListenable: QueuePlayer.instance.shuffleEnabled,
                builder: (_, sh, __) {
                  // Keep local intent in sync with the shared queue shuffle
                  // state so the playlist toggle and the full-screen toggle
                  // never disagree once a playlist has been started.
                  // Once a playlist-driven queue is active, the SHARED state is
                  // authoritative; the local _shuffleOn is only pre-play intent.
                  final fromPl = QueuePlayer.instance.fromPlaylist.value;
                  final on = fromPl ? sh : _shuffleOn;
                  return OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(8),
                      side: BorderSide(
                        color: on ? Spots.green : Colors.white38,
                      ),
                      backgroundColor: on ? Spots.green.withOpacity(.18) : null,
                    ),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            if (QueuePlayer.instance.fromPlaylist.value) {
                              // Flip the shared toggle; it drives BOTH this
                              // button and the full-screen button. Mirror it
                              // back so _shuffleOn never goes stale.
                              QueuePlayer.instance.toggleShuffle();
                              _shuffleOn =
                                  QueuePlayer.instance.shuffleEnabled.value;
                              _savePlaylistPrefs();
                            } else {
                              _shuffleOn = !on;
                              _savePlaylistPrefs();
                            }
                          }),
                    child: Icon(
                      Icons.shuffle,
                      size: 16,
                      color: on ? Spots.green : null,
                    ),
                  );
                },
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(8),
                ),
                onPressed: _busy ? null : _downloadPlaylist,
                child: const Icon(Icons.download_outlined, size: 16),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(8),
                ),
                onPressed: _busy ? null : _addSongs,
                child: const Icon(Icons.add, size: 16),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () {
                  setState(() => _showSort = !_showSort);
                  _savePlaylistPrefs();
                },
                iconSize: 18,
                icon: Icon(
                  Icons.sort_outlined,
                  size: 18,
                  color: _showSort ? Spots.green : Colors.white54,
                ),
              ),
              IconButton(
                onPressed: _busy ? null : () => _deletePlaylist(),
                iconSize: 18,
                tooltip: tr('Delete'),
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
              IconButton(
                onPressed: _busy ? null : _editPhoto,
                iconSize: 18,
                tooltip: tr('Change cover'),
                icon: const Icon(Icons.photo_outlined, size: 18),
              ),
              IconButton(
                onPressed: _busy
                    ? null
                    : () => _verifyAgainstSource(
                        context, widget.api, widget.name),
                iconSize: 18,
                tooltip: tr('Verify against source'),
                icon: const Icon(Icons.fact_check_outlined, size: 18),
              ),
            ],
          ),
          const Divider(height: 20, color: Colors.white12),
          if (_showSort)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Wrap(
                spacing: 6,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _sortChip(0, Icons.list, tr('Playlist')),
                  _sortChip(1, Icons.timer_outlined, tr('Length')),
                  _sortChip(2, Icons.calendar_today, tr('Added')),
                  ActionChip(
                    avatar: const Icon(Icons.swap_vert_outlined, size: 14),
                    label: Text(tr('Spotify order'),
                        style: TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                    onPressed: _busy ? null : _matchSpotifyOrder,
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: tr('Search this playlist…'),
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                      ),
                filled: true,
                fillColor: Colors.white10,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
              style: const TextStyle(fontSize: 14),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _sortChip(int v, IconData icon, String label) {
    final selected = _sort == v;
    return ChoiceChip(
      selected: selected,
      showCheckmark: false,
      avatar: Icon(
        icon,
        size: 16,
        color: selected ? Colors.black : Colors.white54,
      ),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.black : Colors.white70,
            ),
          ),
          if (selected && v != 0) ...[
            const SizedBox(width: 3),
            Icon(
              _reverse ? Icons.arrow_upward : Icons.arrow_downward,
              size: 13,
              color: Colors.black87,
            ),
          ],
        ],
      ),
      selectedColor: Spots.green,
      backgroundColor: Spots.elevated,
      side: const BorderSide(color: Colors.white12),
      visualDensity: VisualDensity.compact,
      onSelected: (_) => setState(() {
        if (_sort == v) {
          _reverse = !_reverse;
        } else {
          _sort = v;
          _reverse = false;
        }
        _savePlaylistPrefs();
      }),
    );
  }

  Widget _art(String url, double size) {
    // Offline-first: check for a locally cached playlist cover first.
    final localPlaylistCover = OfflineStore.playlistCoverFileFor(widget.name);
    if (localPlaylistCover != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          File(localPlaylistCover),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _gradient(size),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) {
          // Offline: fall back to a pre-cached song cover from this
          // playlist before the gradient (no flag needed — local files
          // either exist or they don't).
          final entries = _detail?.entries;
          if (entries != null) {
            for (final e in entries) {
              final local = OfflineStore.coverFileFor(e.baseName);
              if (local != null) {
                return Image.file(
                  File(local),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                );
              }
            }
          }
          return Container(
            width: size,
            height: size,
            decoration:
                BoxDecoration(gradient: Spots.coverGradient(widget.name)),
            child: Icon(
              Icons.queue_music,
              size: size * .4,
              color: Colors.white70,
            ),
          );
        },
      ),
    );
  }

  Widget _gradient(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(gradient: Spots.coverGradient(widget.name)),
      child: Icon(Icons.queue_music, size: size * .4, color: Colors.white70),
    );
  }

  Widget _trackTile(PlaylistEntry e, int shownIndex,
      {bool reorderHandle = false}) {
    final exists = e.exists;
    final playable = _playable(e);
    final thumb = _thumbFor(e);
    final i = e.baseName.indexOf(' - ');
    final artist = i > 0 ? e.baseName.substring(0, i) : '';
    final title = i > 0 ? e.baseName.substring(i + 3) : e.baseName;
    final subtitle = [
      if (artist.isNotEmpty) artist,
      if (exists && e.durationS != null) fmtClock(e.durationS!),
      if (!exists) 'missing on NAS',
      if (_offline && !playable) 'not on this phone',
    ].join(' · ');
    return ValueListenableBuilder<String>(
      valueListenable: QueuePlayerShim.instance.title,
      builder: (context, currentTitle, _) {
        final isCurrent = exists && currentTitle == e.baseName;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: exists
              ? () => showSongLongPressMenu(
                    context,
                    api: widget.api,
                    queueItem: QueueItem(
                      e.baseName,
                      _itemUrl(e),
                      thumbUrl: thumb,
                      liked: e.liked,
                    ),
                    baseNameForPlaylist: e.baseName,
                  )
              : null,
          child: Material(
            color: Colors.transparent,
            // Own Material per row: ListTile's ink then paints inside
            // the row and scrolls with it instead of detaching onto
            // the page-level Material and sliding behind the header.
            child: ListTile(
            enabled: playable,
            leading: CoverThumb(
              title: e.baseName,
              thumbUrl: thumb,
              fallbackUrl: _cover,
            ),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: isCurrent
                  ? TextStyle(color: Spots.green, fontWeight: FontWeight.w700)
                  : (_offline && !playable)
                      ? const TextStyle(color: Colors.white38)
                      : null,
            ),
            subtitle: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<int>(
                  valueListenable: OfflineStore.change,
                  builder: (_, __, ___) =>
                      OfflineStore.isDownloaded(e.baseName)
                          ? Padding(
                              padding:
                                  const EdgeInsets.only(right: 2),
                              child: Icon(
                                Icons.download_outlined,
                                size: 18,
                                color: Spots.green,
                              ),
                            )
                          : const SizedBox.shrink(),
                ),
                if (playable)
                  IconButton(
                    // The existing play triangle turns green when this song is the
                    // one currently playing.
                    icon: Icon(
                      Icons.play_arrow,
                      color: isCurrent ? Spots.green : null,
                    ),
                    onPressed: () => _playFrom(shownIndex),
                  ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'remove') {
                      _delete(e);
                    } else if (v == 'everywhere') {
                      deleteFromEveryPlaylist(context,
                          api: widget.api, baseName: e.baseName);
                    } else if (v == 'nas') {
                      deleteSongFromNas(context,
                          api: widget.api, baseName: e.baseName);
                    } else if (v == 'addto') {
                      _addToAnotherPlaylist(e);
                    } else if (v == 'check') {
                      checkOneSong(context,
                          api: widget.api, baseName: e.baseName);
                    } else if (v == 'download' && e.url != null) {
                      downloadToPhone(context,
                          api: widget.api,
                          baseName: e.baseName,
                          playlist: widget.name,
                          item: QueueItem(
                            e.baseName,
                            widget.api.fileUrl(e.url!),
                          ));
                    } else {
                      // No silent fall-through: every ⋮ tap answers visibly.
                      toast(context, tr('Could not queue (missing file)'),
                          icon: Icons.error_outline);
                    }
                  },
                  itemBuilder: (_) => [
                    // Like every sibling action (and tap-to-play), only for
                    // rows that exist on the server: queuing a missing
                    // file's URL yields a dead item that fails to load.
                    if (exists && e.url != null)
                      PopupMenuItem(
                        // onTap ONLY (no `value:`): same delivery-robustness
                        // reason as 'queue' below — the menu result must not
                        // round-trip through onSelected's mounted gate.
                        onTap: () {
                          if (e.url == null) return;
                          QueuePlayer.instance.playNextNewItem(QueueItem(
                            e.baseName,
                            _itemUrl(e),
                            thumbUrl: thumb,
                            liked: e.liked,
                          ));
                          toast(context, tr('Playing next'),
                              icon: Icons.queue_play_next);
                        },
                        child: Text(tr('Play next in queue')),
                      ),
                    if (exists)
                      PopupMenuItem(
                        value: 'addto',
                        child: Text(tr('Add to another playlist')),
                      ),
                    // Check is a user feature (replace stays owner-only).
                    if (exists)
                      PopupMenuItem(
                        value: 'check',
                        child: Text(tr('Check song')),
                      ),
                    if (exists && e.url != null)
                      PopupMenuItem(
                        value: 'download',
                        child: Text(tr('Download to phone')),
                      ),
                    PopupMenuItem(
                      value: 'remove',
                      child: Text(tr('Remove from playlist')),
                    ),
                    PopupMenuItem(
                      value: 'everywhere',
                      child: Text(tr('Delete from every playlist')),
                    ),
                    // Owner-only (also enforced server-side).
                    if (AuthStore.instance.isOwner)
                      PopupMenuItem(
                        value: 'nas',
                        child: Text(tr('Delete from NAS')),
                      ),
                  ],
                ),
                if (reorderHandle)
                  ReorderableDragStartListener(
                    index: shownIndex,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Icon(
                        Icons.drag_handle,
                        color: Colors.white38,
                        size: 20,
                      ),
                    ),
                  ),
              ],
            ),
            onTap: playable
                ? () => _playFrom(shownIndex)
                : (_offline
                    ? () => toast(context, tr('Not on this phone — connect to play'),
                        icon: Icons.wifi_off_outlined)
                    : null),
            ),
          ),
        );
      },
    );
  }

  Future<void> _addToAnotherPlaylist(PlaylistEntry e) async {
    try {
      final others = (await widget.api.playlists())
          .where((p) => p.name != widget.name)
          .toList();
      if (others.isEmpty) {
        _snack(tr('No other playlists.'));
        return;
      }
      if (!mounted) return;
      final picked = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final p in others)
                ListTile(
                  tileColor: Colors.transparent,
                  hoverColor: Colors.white10,
                  focusColor: Colors.transparent,
                  leading: CoverThumb(
                    title: p.name,
                    thumbUrl: widget.api.playlistCoverUrl(p.name),
                    size: 44,
                  ),
                  title: Text(p.name),
                  onTap: () => Navigator.pop(ctx, p.name),
                ),
            ],
          ),
        ),
      );
      if (picked == null || !mounted) return;
      await widget.api.addToPlaylist(playlist: picked, baseName: e.baseName);
      _snack("${tr('Added')} \"${e.baseName}\" ${tr('to')} $picked.");
    } catch (err) {
      if (mounted) _snack("${tr('Failed')}: $err");
    }
  }
}

/// Cover picker grid: one tile per DISTINCT image. Songs sharing an
/// album resolve to identical bytes through different per-file URLs,
/// so identity is hashed from the bytes, not the URL.
class _CoverGridPicker extends StatefulWidget {
  const _CoverGridPicker({required this.api, required this.entries});
  final ApiClient api;
  final List<PlaylistEntry> entries;

  @override
  State<_CoverGridPicker> createState() => _CoverGridPickerState();
}

class _CoverGridPickerState extends State<_CoverGridPicker> {
  List<PlaylistEntry>? _distinct;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static int _hashBytes(List<int> b) {
    var h = 2166136261;
    for (final x in b) {
      h ^= x;
      h = (h * 16777619) & 0xFFFFFFFF;
    }
    return h;
  }

  Future<void> _load() async {
    // Show every candidate instantly (thumbs lazy-load on their own),
    // then collapse duplicates in the background as hashes resolve.
    // Waiting for every hash first is what kept the sheet blank for
    // multiple seconds.
    if (!mounted) return;
    setState(() => _distinct = List.of(widget.entries));
    final seen = <int, PlaylistEntry>{};
    final queue = List.of(widget.entries);
    const laneCount = 8;
    Future<void> lane() async {
      while (queue.isNotEmpty) {
        final e = queue.removeAt(0);
        try {
          final bytes = await widget.api.coverBytes(e.url!);
          if (bytes == null || bytes.length < 64) continue;
          seen.putIfAbsent(_hashBytes(bytes), () => e);
        } catch (_) {}
        if (mounted) setState(() => _distinct = seen.values.toList());
      }
    }

    try {
      await Future.wait([for (var k = 0; k < laneCount; k++) lane()]);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final distinct = _distinct;
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (distinct == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (distinct.isEmpty) {
      return Center(child: Text(tr('No artwork found.')));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: distinct.length,
      itemBuilder: (_, i) {
        final e = distinct[i];
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => Navigator.pop(context, e),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CoverThumb(
              title: e.baseName,
              thumbUrl: widget.api.coverUrl(e.url!),
              size: 200,
            ),
          ),
        );
      },
    );
  }
}
