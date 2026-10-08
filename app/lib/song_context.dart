import 'dart:async';

import 'package:flutter/material.dart';

import 'api_client.dart';
import 'auth_store.dart';
import 'diag_log.dart';
import 'keep_dialog.dart';
import 'lang.dart';
import 'offline_store.dart';
import 'prefetch_store.dart';
import 'queue_player.dart';
import 'toast.dart';
import 'version_sheet.dart';
import 'widgets.dart';

/// Shared long-press context menu for any song row in the app.
///
/// All actions are reachable from every song list (search, playlist detail,
/// album, artist) so the UX is identical everywhere:
///  * "Play next in queue" — insert [queueItem] right after the current song
///    (starting it if the queue was empty).
///  * "Add to playlist" — save the song under [baseNameForPlaylist].
///  * "Check this song" — run the studio-original check on just this song
///    and show the verdict (same engine as Settings → Check songs).
Future<void> showSongLongPressMenu(
  BuildContext context, {
  required ApiClient api,
  required QueueItem queueItem,
  required String baseNameForPlaylist,
  bool queued = false,
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.queue_play_next),
            title: Text(tr('Play next in queue')),
            onTap: () => Navigator.pop(context, 'next'),
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: Text(tr('Add to playlist')),
            onTap: () => Navigator.pop(context, 'add'),
          ),
          // Check + versions are user features (replace itself is
          // owner-gated server-side).
          ListTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: Text(tr('Check this song')),
            onTap: () => Navigator.pop(context, 'check'),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: Text(tr('Download to phone')),
            onTap: () => Navigator.pop(context, 'download'),
          ),
          ListTile(
            leading: const Icon(Icons.playlist_remove_outlined),
            title: Text(tr('Delete from every playlist')),
            onTap: () => Navigator.pop(context, 'everywhere'),
          ),
          // Owner-only (also enforced server-side): destructive NAS delete.
          if (AuthStore.instance.isOwner)
            ListTile(
              leading: const Icon(Icons.delete_forever_outlined),
              title: Text(tr('Delete from NAS')),
              onTap: () => Navigator.pop(context, 'nas'),
            ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  if (action == 'everywhere') {
    await deleteFromEveryPlaylist(context, api: api, baseName: baseNameForPlaylist);
    return;
  }
  if (action == 'nas') {
    await deleteSongFromNas(context, api: api, baseName: baseNameForPlaylist);
    return;
  }
  if (action == 'check') {
    await checkOneSong(context, api: api, baseName: baseNameForPlaylist);
    return;
  }
  if (action == 'download') {
    await downloadToPhone(context, api: api,
        baseName: baseNameForPlaylist, item: queueItem);
    return;
  }
  // NAS-first: if the song lives on the NAS, prefer the local copy
  // instead of streaming the (possibly wrong) internet video.
  Future<QueueItem> resolveNasFirst() async {
    var item = queueItem;
    final artist = queueItem.lyricsArtist;
    final title = queueItem.lyricsTitle;
    if (artist != null && title != null) {
      try {
        // Bounded: queue-next/end must never park on a slow NAS check.
        final nas = await api
            .inNas(artist: artist, title: title)
            .timeout(const Duration(seconds: 2));
        if (nas.found && (nas.url?.isNotEmpty ?? false)) {
          item = QueueItem(
            nas.baseName ?? queueItem.title,
            api.fileUrl(nas.url!),
            thumbUrl: (nas.albumImage?.isNotEmpty ?? false)
                ? nas.albumImage
                : queueItem.thumbUrl,
            album: nas.album,
            // Keep the song's identity keys: the queued copy must stay
            // resolvable + lyric-matched exactly like the tapped row.
            lyricsArtist: queueItem.lyricsArtist,
            lyricsTitle: queueItem.lyricsTitle,
          );
        }
      } catch (_) {
        // NAS check is best-effort; fall through with the original item.
      }
    }
    return item;
  }

  if (action == 'next') {
    QueuePlayer.instance.playNextNewItem(await resolveNasFirst());
    if (context.mounted) {
      toast(context, tr('Playing next'), icon: Icons.queue_play_next);
    }
    return;
  }
  final pl = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (_) => KeepPlaylistSheet(api: api),
  );
  if (pl == null || !context.mounted) return;
  try {
    await api.addToPlaylist(baseName: baseNameForPlaylist, playlist: pl);
    if (context.mounted) {
      toast(
        context,
        queued
            ? "${tr('Saved to')} \"$pl\" ${tr('(queued to download)')}"
            : "${tr('Saved to')} \"$pl\"",
      );
    }
  } catch (e) {
    if (context.mounted) toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
  }
}

/// Play "Artist - Title" NAS-first, internet fallback. Shared by history
/// taps + checker fallbacks so a row ALWAYS plays something instead of
/// erroring when the NAS copy is gone/unreachable.
Future<void> playArtistTitle(
  BuildContext context, {
  required ApiClient api,
  required String artist,
  required String title,
}) async {
  final a = artist.trim();
  final t = title.trim();
  if (t.isEmpty || !context.mounted) return;
  final label = a.isEmpty ? t : '$a - $t';
  // Cache-first (same keys as QueuePlayer._resolveItemUrl): explicit
  // downloads, then the look-ahead cache. file:// plays with no network.
  Future<String?> cachedUri() async {
    final off = OfflineStore.localUriFor(label, t);
    if (off != null) return off;
    final pre = await PrefetchStore.fileFor(label, t);
    if (pre != null) return Uri.file(pre).toString();
    return null;
  }
  Future<bool> playCached(String uri, String how) async {
    try {
      await QueuePlayer.instance.playOne(
        QueueItem(label, uri, lyricsArtist: a, lyricsTitle: t),
      );
    } catch (_) {
      return false;
    }
    DiagLog.restart.log('history offline-hit ($how) "$label"');
    unawaited(api.logClientError('offline-cache-hit', '$how $label'));
    return true;
  }
  // Offline: never go network-first (inNas/resolve hang, then toast).
  if (QueuePlayer.instance.isOffline.value) {
    final uri = await cachedUri();
    if (uri != null && context.mounted) {
      await playCached(uri, 'offline');
      return;
    }
    unawaited(api.logClientError('offline-cache-miss', label));
    if (context.mounted) {
      toast(context, tr('Offline — not saved on this phone'),
          icon: Icons.error_outline);
    }
    return;
  }
  // Instant tap: play a lazy placeholder NOW (engine resolves phone
  // cache → NAS exact-match → stream, all bounded). No inNas/resolve await
  // before first audio; failures auto-skip bounded with toast+log instead
  // of parking. The offline branch above stays (never network-first).
  QueuePlayer.instance.wireTapResolvers(api);
  try {
    await QueuePlayer.instance.playOne(
      QueueItem(
        label,
        '',
        resolveName: (artist: a, title: t),
        lyricsArtist: a,
        lyricsTitle: t,
      ),
    );
  } catch (e) {
    // Network failed: try the phone copy before giving up with a toast.
    final uri = await cachedUri();
    if (uri != null && context.mounted) {
      if (await playCached(uri, 'net-fail')) return;
    }
    unawaited(api.logClientError('playback', '$label: $e'));
    if (context.mounted) {
      toast(context, "${tr('Could not play')}: $e", icon: Icons.error_outline);
    }
  }
}

/// Run the studio-original check on a single NAS song and show the verdict.
///
/// Uses the same `/api/checksongs?scope=song:<baseName>` engine as
/// Settings → Check songs, polling until the snapshot for OUR scope is
/// done (a scope change issued while another scan runs is ignored
/// server-side, so a stale-scope snapshot is never presented as ours).
Future<void> checkOneSong(
  BuildContext context, {
  required ApiClient api,
  required String baseName,
}) async {
  final q = baseName.trim();
  if (q.isEmpty || !context.mounted) return;
  final scope = 'song:$q';
  var progressOpen = false;
  CheckSongsStatus? snap;
  try {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(child: Text("${tr('Checking')} \"$q\"…")),
          ],
        ),
      ),
    );
    progressOpen = true;
    try {
      snap = await api.checkSongs(scope: scope);
    } catch (e) {
      snap = null;
    }
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (snap != null &&
        (!snap.done || snap.running || snap.scope != scope) &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(seconds: 1));
      if (!context.mounted) return;
      try {
        // A finished snapshot for a DIFFERENT scope means our scope was
        // ignored (another scan was running) — (re)start ours now that
        // the worker is idle.
        if (snap.done && !snap.running && snap.scope != scope) {
          snap = await api.checkSongs(scope: scope);
        } else {
          snap = await api.checkSongs(scope: scope, poll: true);
        }
      } catch (_) {
        break;
      }
    }
  } finally {
    if (progressOpen && context.mounted) Navigator.pop(context);
  }
  if (!context.mounted) return;

  CheckSongReport? found;
  if (snap != null) {
    for (final r in snap.reports) {
      if (r.baseName == q) {
        found = r;
        break;
      }
    }
  }
  if (!context.mounted) return;
  if (!context.mounted) return;
  // Always the modern sheet (same as the Settings checker rows): the
  // fingerprint + version lookup auto-run on open, and Play/Versions are
  // offered even when the scan found no report (synthetic "unverified"
  // report — fingerprint + versions work via baseName either way).
  final rep = found ?? CheckSongReport(baseName: q, status: 'no_ref');
  await openCheckSongSheet(
    context,
    api: api,
    report: rep,
    onPlay: () async {
      if (rep.isPlayable) {
        await _playCheckedSong(context, api: api, rep: rep);
      }
    },
    onVersions: () async {
      openVersionPicker(context, api: api, baseName: rep.baseName);
    },
  );
}

/// Play the NAS copy behind a check report (same as the checker row's
/// play button in Settings).
Future<void> _playCheckedSong(
  BuildContext context, {
  required ApiClient api,
  required CheckSongReport rep,
}) async {
  final url = rep.url;
  if (!rep.isPlayable || url == null || url.isEmpty) {
    toast(context, tr('No playable copy on the NAS yet (still downloading?).'),
        icon: Icons.info_outline);
    return;
  }
  try {
    await QueuePlayer.instance.playOne(
      QueueItem(rep.baseName, api.fileUrl(url),
          thumbUrl: api.coverUrl(url)),
    );
  } catch (e) {
    if (context.mounted) {
      // NAS copy failed (moved/deleted since the scan, or not shared
      // with this user): fall back to streaming the same song instead
      // of leaving the tap dead with an error.
      final parts = rep.baseName.split(' - ');
      await playArtistTitle(
        context,
        api: api,
        artist: parts.length > 1 ? parts.first : '',
        title: parts.length > 1 ? parts.sublist(1).join(' - ') : rep.baseName,
      );
    }
    return;
  }
  if (!context.mounted) return;
  toast(context, "${tr('Playing')}: ${rep.baseName}", icon: Icons.music_note);
  QueuePlayerShim.instance.openNowPlaying(context);
}

/// Download one song to the phone (quota-enforced). NAS-first: prefers the
/// local NAS copy over the internet stream, same as queueing.
Future<void> downloadToPhone(
  BuildContext context, {
  required ApiClient api,
  required String baseName,
  required QueueItem item,
  String playlist = '',
}) async {
  final q = baseName.trim();
  if (q.isEmpty || !context.mounted) return;
  if (OfflineStore.isDownloaded(q)) {
    toast(context, tr('Already on your phone'), icon: Icons.check_circle);
    return;
  }
  var url = item.url;
  final artist = item.lyricsArtist;
  final title = item.lyricsTitle;
  if (artist != null && title != null) {
    try {
      final nas = await api.inNas(artist: artist, title: title);
      if (nas.found && (nas.url?.isNotEmpty ?? false)) {
        url = api.fileUrl(nas.url!);
      }
    } catch (_) {}
  }
  if (!context.mounted) return;
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: Row(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 16),
          Expanded(child: Text("${tr('Downloading')} \"$q\"…")),
        ],
      ),
    ),
  );
try {
    await OfflineStore.download(
      base: q,
      url: url,
      playlist: playlist,
      thumb: item.thumbUrl,
      api: api,
    );
    if (context.mounted) {
      Navigator.pop(context);
      toast(context, tr('Saved to phone'), icon: Icons.check_circle);
    }
  } catch (e) {
    api.logClientError('download-failed', '$q — $e');
    if (context.mounted) {
      Navigator.pop(context);
      toast(context, '$e', icon: Icons.error_outline);
    }
  }
}

/// Delete [baseName] from EVERY playlist that contains it (confirm first).
/// Shared by the song long-press menu and the playlist-detail ⋮ menu.
/// Server entry-delete is idempotent, so membership is checked first and
/// only real removals are counted. Returns true when anything was removed.
Future<bool> deleteFromEveryPlaylist(
  BuildContext context, {
  required ApiClient api,
  required String baseName,
}) async {
  final q = baseName.trim();
  if (q.isEmpty || !context.mounted) return false;
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text("${tr('Delete ')}\"$q\"${tr(' from every playlist?')}"),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(tr('Cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('Delete')),
        ),
      ],
    ),
  );
  if (confirm != true || !context.mounted) return false;
  var removed = 0;
  try {
    final pls = await api.playlists();
    for (final p in pls) {
      try {
        final detail = await api.playlistEntries(p.name);
        if (!detail.entries.any((e) => e.baseName == q)) continue;
        await api.removeFromPlaylist(p.name, baseName: q);
        removed++;
      } catch (_) {
        // Keep sweeping the rest; one bad playlist must not stop the run.
      }
    }
  } catch (e) {
    if (context.mounted) {
      toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
    }
    return false;
  }
  if (context.mounted) {
    toast(
      context,
      removed > 0 ? tr('Removed from every playlist') : tr('Not in any playlist'),
    );
  }
  return removed > 0;
}

/// Delete the NAS copy behind [baseName] (confirm first, owner-only —
/// the server 403s non-owners too). Returns true when deleted.
Future<bool> deleteSongFromNas(
  BuildContext context, {
  required ApiClient api,
  required String baseName,
}) async {
  final q = baseName.trim();
  if (q.isEmpty || !context.mounted) return false;
  if (!AuthStore.instance.isOwner) {
    toast(context, tr('Only the library owner can delete NAS copies.'),
        icon: Icons.error_outline);
    return false;
  }
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text("${tr('Delete ')}\"$q\"${tr(' from the NAS?')}"),
      content: Text(tr('The file is gone for everyone. This cannot be undone.')),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(tr('Cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('Delete')),
        ),
      ],
    ),
  );
  if (confirm != true || !context.mounted) return false;
  try {
    final rows = await api.downloads();
    DownloadRow? hit;
    for (final d in rows) {
      if (d.baseName == q) {
        hit = d;
        break;
      }
    }
    if (hit == null) {
      if (context.mounted) toast(context, tr('No NAS copy found'));
      return false;
    }
    await api.remove(hit.id);
  } catch (e) {
    if (context.mounted) {
      toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
    }
    return false;
  }
  if (context.mounted) toast(context, tr('Deleted from NAS'));
  return true;
}
