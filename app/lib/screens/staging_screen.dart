import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../auth_store.dart';
import '../import_sheet.dart';
import '../keep_dialog.dart';
import '../lang.dart';
import '../offline_store.dart';
import '../theme.dart';
import '../toast.dart';
import '../widgets.dart';
import 'settings_screen.dart';

class StagingScreen extends StatefulWidget {
  const StagingScreen({super.key, required this.api, required this.onServer});
  final ApiClient api;
  final Future<String?> Function() onServer;

  @override
  State<StagingScreen> createState() => _StagingScreenState();
}

class _StagingScreenState extends State<StagingScreen> {
  List<DownloadRow> _downloads = [];
  bool _loading = true;
  String _error = '';
  Timer? _timer;
  // Adaptive poll state: back off when the list is unchanged/idle, poll fast
  // while jobs run. Single-flight so slow ticks never overlap into 2x load.
  bool _inFlight = false;
  int _stableTicks = 0;
  String _lastHash = '';
  // Swipe between server/phone pages (synced with the picker above).
  final PageController _pageCtrl = PageController();
  // One-shot cover backfill for phone rows saved before thumbs existed.
  bool _thumbFilling = false;

  @override
  void initState() {
    super.initState();
    _load();
    _schedule();
  }

  /// Next poll delay: 3s while busy/changing, else 6→9→12→15s backoff.
  void _schedule() {
    _timer?.cancel();
    final busy = _isBusy;
    final delay = downloadsPollDelaySec(
      busy: busy,
      stableTicks: _stableTicks,
    );
    _timer = Timer(Duration(seconds: delay), () {
      // Screen off / background: IndexedStack keeps this state alive on
      // every tab — a bg tick is pure server cost, so skip and reschedule.
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        _schedule();
        return;
      }
      _load(silent: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    if (_inFlight) {
      _schedule();
      return;
    }
    _inFlight = true;
    try {
      final dls = await widget.api.downloads();
      if (!mounted) return;
      // Silent polls must never clobber a good list with a transient
      // empty (that reads as "everything vanished").
      if (silent && dls.isEmpty && _downloads.isNotEmpty) return;
      final hash = downloadsHash(dls);
      if (hash == _lastHash) {
        _stableTicks++;
      } else {
        _stableTicks = 0;
        _lastHash = hash;
      }
      setState(() {
        _downloads = dls;
        _loading = false;
        _error = '';
      });
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    } finally {
      _inFlight = false;
      if (mounted) _schedule();
    }
  }

  /// Let the user pick among candidates for a failed download.
  Future<void> _pickAndRetry(DownloadRow d) async {
    late final List<Candidate> cands;
    try {
      cands = await widget.api.candidates(d.id);
    } catch (e) {
      if (mounted) {
        toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
      }
      return;
    }
    if (!mounted) return;
    if (cands.isEmpty) {
      toast(context, tr('No candidates.'), icon: Icons.info_outline);
      return;
    }
    final sel = await showModalBottomSheet<Candidate>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                tr('Choose a version to retry'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: cands.length,
                itemBuilder: (_, i) {
                  final c = cands[i];
                  return ListTile(
                    title: Text(
                      c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      c.channel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(ctx, c),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (sel == null || !mounted) return;
    try {
      await widget.api.redownload(d.id, sel.videoId);
      await _load();
    } catch (e) {
      if (mounted) {
        toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
      }
    }
  }

  Future<void> _remove(DownloadRow d) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("${tr('Discard')} \"${d.baseName}\"?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Discard')),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final base = d.baseName;
    try {
      await widget.api.remove(d.id);
      await _load();
    } catch (e) {
      if (mounted) {
        toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
      }
      return;
    }
    if (!mounted) return;
    showUndoBar(context, "${tr('Discarded')} \"$base\"", () => _restage(base));
  }

  /// Re-download a discarded/failed row ("Download again").
  Future<void> _restage(String base) async {
    final i = base.indexOf(' - ');
    if (i <= 0 || !mounted) return;
    try {
      await widget.api.stage(
          base.substring(0, i).trim(), base.substring(i + 3).trim());
      if (mounted) toast(context, tr('Downloading again'));
      await _load();
    } catch (e) {
      if (mounted) toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
    }
  }

  // Downloads side: server staging jobs vs on-phone songs.
  bool _phoneSide = false;
  // Filter text for the on-phone list (per-group delete below reuses it).
  String _phoneFilter = '';
  // Collapsed phone-group keys (normKey): drives the trailing arrow +
  // survives rebuilds (reuses existing strings, no new translations).
  final Set<String> _collapsedGroups = {};

  bool get _isBusy => _downloads.any(
        (d) =>
            d.status == 'downloading' ||
            d.status == 'searching' ||
            d.status == 'queued',
      );

  String _statusLabel(String s) => s == 'staged' ? tr('downloaded — save it') : s;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
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
          ? Center(child: Text(_error))
          : Column(
              children: [
                ImportProgressCard(api: widget.api),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                  child: SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(
                        value: false,
                        label: Text(tr('On the server (NAS)')),
                        icon: const Icon(Icons.dns_outlined, size: 18),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text(tr('On this phone')),
                        icon: const Icon(
                            Icons.smartphone_outlined, size: 18),
                      ),
                    ],
                    selected: {_phoneSide},
                    onSelectionChanged: (s) {
                      final v = s.first;
                      setState(() => _phoneSide = v);
                      _pageCtrl.animateToPage(
                        v ? 1 : 0,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                      );
                    },
                  ),
                ),
                Expanded(
                  child: PageView(
                    controller: _pageCtrl,
                    onPageChanged: (i) =>
                        setState(() => _phoneSide = i == 1),
                    children: [
                      _serverList(),
                      _phoneList(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  /// Server download rows (staging jobs).
  Widget _serverList() {
    if (_downloads.isEmpty) {
      return Center(
        child: Text(
          "${tr('Nothing on the server yet.')}\n\n"
          "${tr('Search -> pick a track -> it downloads here.')}\n"
          "${tr('Save the ones you like.')}",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(),
      child: _serverRows(),
    );
  }

  Widget _serverRows() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _downloads.length,
      itemBuilder: (_, i) {
                  final d = _downloads[i];
                  final done = d.status == 'staged' || d.status == 'kept';
                  return ListTile(
                    leading: CoverThumb(
                      title: d.baseName,
                      thumbUrl: d.status == 'staged' || d.status == 'kept'
                          ? widget.api.coverUrl('/staging/file/${d.path}')
                          : (d.videoId != null && d.videoId!.isNotEmpty)
                              ? widget.api.coverVidUrl(d.videoId!)
                              : null,
                    ),
                    title: Text(
                      d.baseName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Row(
                      children: [
                        if (d.status == 'downloading' ||
                            d.status == 'searching' ||
                            d.status == 'queued') ...[
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (d.status == 'failed')
                          const Icon(
                            Icons.error_outline,
                            size: 15,
                            color: Colors.redAccent,
                          ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            _statusLabel(d.status),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: done ? Spots.green : Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (d.status == 'staged')
                          IconButton(
                            icon: const Icon(Icons.save_outlined),
                            tooltip: tr('Save'),
                            onPressed: () async {
                              final pl = await showModalBottomSheet<String>(
                                context: context,
                                showDragHandle: true,
                                builder: (_) =>
                                    KeepPlaylistSheet(api: widget.api),
                              );
                              if (pl == null) return;
                              String msg;
                              try {
                                await widget.api.addToPlaylist(
                                  downloadId: d.id,
                                  playlist: pl,
                                );
                                msg =
                                    "${tr('Saved to')} \"$pl\" ${tr('and moved to your library')}";
                              } catch (e) {
                                msg = "${tr('Failed')}: $e";
                              }
                              if (mounted) {
                                toast(
                                  context,
                                  msg,
                                  icon: msg.startsWith('Failed')
                                      ? Icons.error_outline
                                      : Icons.check_circle,
                                );
                              }
                              await _load();
                            },
                          ),
                        if (d.status == 'failed' &&
                            AuthStore.instance.isOwner)
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            tooltip: tr('Retry'),
                            onPressed: () => _pickAndRetry(d),
                          ),
                        if (AuthStore.instance.isOwner)
                          PopupMenuButton<String>(
                            onSelected: (v) {
                              if (v == 'remove') _remove(d);
                              if (v == 'again') _restage(d.baseName);
                            },
                            itemBuilder: (_) => [
                              if (d.status == 'failed')
                                PopupMenuItem(
                                  value: 'again',
                                  child: Text(tr('Download again')),
                                ),
                              PopupMenuItem(
                                value: 'remove',
                                child: Text(tr('Discard')),
                              ),
                            ],
                          ),
                      ],
                    ),
                  );
                },
              );
  }

  /// On-phone songs grouped by import playlist (ungrouped under
  /// "Songs"), each with cover + delete. Answers "will a phone
  /// playlist look like a playlist": yes — one expansion per list.
  /// Backfill missing phone-row covers (entries saved before thumbs
  /// were stored): resolve each base via suggest, keep the first art
  /// URL. Single-flight background pass; the change notifier repaints.
  void _backfillThumbs(List<dynamic> entries) {
    if (_thumbFilling) return;
    final missing = entries
        .where((e) => ((e.thumb as String?) ?? '').isEmpty)
        .toList();
    if (missing.isEmpty) return;
    _thumbFilling = true;
    () async {
      for (final e in missing) {
        if (!mounted) break;
        try {
          final rows = await widget.api.suggest(e.base as String);
          String art = '';
          for (final s in rows) {
            art = s.albumImage ?? '';
            if (art.isNotEmpty) break;
          }
          if (art.isNotEmpty) {
            await OfflineStore.setThumb(e.base as String, art);
          }
        } catch (_) {}
      }
      _thumbFilling = false;
    }();
  }

  /// Cache server covers for on-phone group names (best-effort, online
  /// only). [names] are DISPLAY names (server spelling): the cache key
  /// hashes the exact string, so normalized keys would never hit render.
  void _backfillPhoneGroupCovers(List<String> names) {
    unawaited(widget.api.ping().then((reachable) {
      if (!reachable || !mounted) return;
      for (final n in names) {
        if (n.isEmpty) continue;
        if (OfflineStore.playlistCoverFileFor(n) != null) continue;
        unawaited(OfflineStore.maybeCachePlaylistCover(n, widget.api).then((ok) {
          if (ok && mounted) setState(() {});
        }));
      }
    }));
  }

  /// Cached cover file when present, gradient+icon fallback (never blank).
  Widget _phoneGroupCover(String name) {
    final local = OfflineStore.playlistCoverFileFor(name);
    if (local != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(local),
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _phoneGroupFallback(name),
        ),
      );
    }
    return _phoneGroupFallback(name);
  }

  Widget _phoneGroupFallback(String name) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: Spots.coverGradient(name),
        ),
        child:
            const Icon(Icons.queue_music, color: Colors.white70, size: 20),
      );

  Widget _phoneList() {
    return ValueListenableBuilder<int>(
      valueListenable: OfflineStore.change,
      builder: (_, __, ___) {
        final entries = OfflineStore.all();
        if (entries.isEmpty) {
          return Center(
            child: Text(
              '${tr('Nothing downloaded yet.')}\n\n'
              '${OfflineStore.fmtBytes(OfflineStore.bytesUsed)}'
              ' / ${OfflineStore.fmtBytes(OfflineStore.quotaBytes)}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54),
            ),
          );
        }
        final q = _phoneFilter.trim().toLowerCase();
        final visible = q.isEmpty
            ? entries
            : entries
                .where((e) => e.base.toLowerCase().contains(q))
                .toList();
        if (visible.isEmpty) {
          return Column(
            children: [
              _phoneFilterField(),
              Expanded(
                child: Center(
                  child: Text(tr('No songs match the search.'),
                      style: const TextStyle(color: Colors.white54)),
                ),
              ),
            ],
          );
        }
        final groups = <String, List<dynamic>>{};
        final display = <String, String>{}; // normKey -> first display name
        for (final e in visible) {
          final raw = (e.playlist as String? ?? '');
          final k = OfflineStore.normKey(raw);
          display.putIfAbsent(k, () => raw.trim());
          groups.putIfAbsent(k, () => []).add(e);
        }
        final names = groups.keys.toList()
          ..sort((a, b) {
            if (a.isEmpty) return 1;
            if (b.isEmpty) return -1;
            return a.compareTo(b);
          });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _backfillThumbs(entries);
            _backfillPhoneGroupCovers(
                [for (final k in names) display[k] ?? '']);
          }
        });
        return Column(
          children: [
            _phoneFilterField(),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: names.length,
                itemBuilder: (_, gi) {
                  final gk = names[gi];
                  final name = display[gk] ?? '';
                  final songs = groups[gk]!;
                  if (name.isEmpty) {
                    return Column(
                      children: [
                        for (final e in songs) _phoneTile(e),
                      ],
                    );
                  }
                  final expanded = !_collapsedGroups.contains(gk);
                  return ExpansionTile(
                    key: PageStorageKey<String>('phone-group-$gk'),
                    initiallyExpanded: expanded,
                    onExpansionChanged: (v) => setState(() {
                      if (v) {
                        _collapsedGroups.remove(gk);
                      } else {
                        _collapsedGroups.add(gk);
                      }
                    }),
                    dense: true,
                    leading: _phoneGroupCover(name),
                    title: Text(name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${songs.length} ${tr('songs')}',
                        style: const TextStyle(fontSize: 12)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: tr('Delete'),
                          onPressed: () async {
                            for (final e in songs) {
                              await OfflineStore.remove(e.base as String);
                            }
                          },
                        ),
                        AnimatedRotation(
                          turns: expanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: const Icon(Icons.expand_more),
                        ),
                      ],
                    ),
                    children: [
                      for (final e in songs) _phoneTile(e),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  /// Filter field above the on-phone list (reuses existing strings).
  Widget _phoneFilterField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: TextField(
        decoration: InputDecoration(
          hintText: tr('Search this playlist…'),
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _phoneFilter.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: tr('Clear'),
                  onPressed: () => setState(() => _phoneFilter = ''),
                ),
          filled: true,
          fillColor: Spots.elevated,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(30),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
        ),
        onChanged: (v) => setState(() => _phoneFilter = v),
      ),
    );
  }

  Widget _phoneTile(dynamic e) {
    return ListTile(
      dense: true,
      leading: CoverThumb(
        title: e.base as String,
        thumbUrl: e.thumb as String?,
        size: 40,
      ),
      title: Text((e.base as String),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        OfflineStore.fmtBytes(e.size as int),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: tr('Delete'),
        onPressed: () async {
          await OfflineStore.remove(e.base as String);
        },
      ),
    );
  }
}

/// Change hash for the downloads list (pure, unit-tested): ids + statuses
/// are everything the staging UI renders per tick.
String downloadsHash(List<DownloadRow> dls) =>
    dls.map((d) => '${d.id}:${d.status}').join('|');

/// Adaptive /api/downloads poll interval (pure, unit-tested): 3s while jobs
/// are active or the list just changed, else 6→9→12→15s backoff. Steady idle
/// settles at 15s (~240 req/hr vs ~1200 at a flat 3s).
int downloadsPollDelaySec({required bool busy, required int stableTicks}) {
  if (busy || stableTicks <= 0) return 3;
  const steps = [6, 9, 12, 15];
  return steps[(stableTicks - 1).clamp(0, steps.length - 1)];
}
