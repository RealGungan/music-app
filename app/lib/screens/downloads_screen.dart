import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../theme.dart';
import 'keep_dialog.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

const _activeStatuses = {
  'pending', 'queued', 'searching', 'downloading', 'retrying'
};

class _DownloadsScreenState extends State<DownloadsScreen> {
  List<DownloadRow> _rows = [];
  Timer? _poll;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final rows = await widget.api.downloads();
      rows.sort((a, b) {
        final aa = _activeStatuses.contains(a.status) ? 0 : 1;
        final bb = _activeStatuses.contains(b.status) ? 0 : 1;
        if (aa != bb) return aa - bb;
        return b.baseName.compareTo(a.baseName);
      });
      if (mounted) {
        setState(() {
          _rows = rows;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  (IconData, Color) _statusVisual(String s) => switch (s) {
        'staged' => (Icons.schedule, Colors.amber.shade600),
        'kept' => (Icons.bookmark, Spots.green),
        'expired' => (Icons.hourglass_bottom, Colors.blueGrey),
        'deleted' || 'failed' || 'giveup' => (
            Icons.error_outline,
            Colors.redAccent
          ),
        'no_results' || 'no_official' => (
            Icons.search_off,
            Colors.deepOrange
          ),
        _ => (Icons.downloading, Colors.lightBlueAccent),
      };

  Future<void> _openDetail(DownloadRow row) async {
    final cands = await widget.api.candidates(row.id);
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Spots.elevated,
      builder: (ctx) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: .75,
          builder: (ctx, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
            children: [
              Text(row.baseName,
                  style: Theme.of(ctx)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Row(children: [
                Icon(_statusVisual(row.status).$1,
                    size: 15, color: _statusVisual(row.status).$2),
                const SizedBox(width: 6),
                Text(row.status,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: _statusVisual(row.status).$2)),
                Expanded(
                  child: Text(
                      row.channel != null ? '  ·  ${row.channel}' : '',
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 12.5, color: Colors.white38)),
                ),
              ]),
              const SizedBox(height: 18),
              Text('ALTERNATIVES — BEST FIRST',
                  style: TextStyle(
                      fontSize: 11.5,
                      letterSpacing: .8,
                      fontWeight: FontWeight.w800,
                      color: Theme.of(ctx).colorScheme.primary)),
              const SizedBox(height: 6),
              if (cands.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text('No stored alternatives.',
                      style: TextStyle(color: Colors.white38)),
                )
              else ...[
                for (final (i, c) in cands.indexed)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                    decoration: BoxDecoration(
                      color: c.videoId == row.videoId
                          ? Spots.green.withOpacity(.13)
                          : Spots.base,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: c.videoId == row.videoId
                              ? Spots.green.withOpacity(.5)
                              : Colors.white10),
                    ),
                    child: Row(children: [
                      SizedBox(
                        width: 26,
                        child: i == 0
                            ? const Icon(Icons.star,
                                size: 17, color: Spots.green)
                            : Text('${i + 1}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 12)),
                      ),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(c.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600)),
                              Row(children: [
                                Flexible(
                                  child: Text(c.channel,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 11.5,
                                          color: Colors.white54)),
                                ),
                                Text('  ·  ${_fmt(c.durationS ?? 0)}',
                                    style: const TextStyle(
                                        fontSize: 11.5,
                                        color: Colors.white38)),
                              ]),
                            ]),
                      ),
                      Chip(
                        label: Text('score ${c.score ?? '?'}',
                            style: const TextStyle(fontSize: 10.5)),
                        visualDensity: VisualDensity.compact,
                        backgroundColor: Spots.subtle,
                        side: BorderSide.none,
                      ),
                      if (c.videoId == row.videoId)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10),
                          child: Text('CURRENT',
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  color: Spots.green)),
                        )
                      else
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.swap_horiz, size: 20),
                          tooltip: 'Replace with this version',
                          onPressed: () async {
                            Navigator.pop(ctx);
                            try {
                              await widget.api.redownload(row.id, c.videoId);
                              _snack('Swapping version…');
                            } catch (err) {
                              _snack('Failed: $err');
                            }
                            _refresh();
                          },
                        ),
                    ]),
                  ),
              ],
              const Divider(height: 24),
              ListTile(
                enabled: row.status == 'staged' || row.status == 'kept',
                leading: const Icon(Icons.playlist_add),
                title: const Text('Add to playlist'),
                onTap: () {
                  Navigator.pop(ctx);
                  showKeepDialog(context, widget.api,
                          downloadId: row.id, baseName: row.baseName)
                      .then((_) => _refresh());
                },
              ),
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('Delete track + history',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await widget.api.remove(row.id);
                  _snack('Deleted');
                  _refresh();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  static String _fmt(int s) =>
      '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(slivers: [
        SliverAppBar(
          pinned: true,
          toolbarHeight: 72,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, children: [
            Text('Staging',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800)),
            Text('Downloaded tracks expire in 7 days unless kept',
                style: TextStyle(fontSize: 12, color: Colors.white54)),
          ]),
        ),
        if (_error != null)
          SliverToBoxAdapter(
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(child: Text(_error!)))),
        if (_error == null && _rows.isEmpty)
          const SliverFillRemaining(
              child: Center(
                  child: Text('Nothing staged yet.',
                      style: TextStyle(color: Colors.white38)))),
        SliverList.builder(
          itemCount: _rows.length,
          itemBuilder: (context, i) {
            final r = _rows[i];
            final active = _activeStatuses.contains(r.status);
            final (icon, color) = _statusVisual(r.status);
            return ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16),
              horizontalTitleGap: 12,
              leading: active
                  ? const SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : CircleAvatar(
                      radius: 19,
                      backgroundColor: Spots.elevated,
                      child: Icon(icon, size: 18, color: color)),
              title: Text(r.baseName,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(r.status +
                  (r.channel != null ? ' · ${r.channel}' : ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54)),
              trailing: r.status == 'staged'
                  ? IconButton(
                      icon: const Icon(Icons.playlist_add),
                      tooltip: 'Add to playlist',
                      onPressed: () =>
                          showKeepDialog(context, widget.api,
                                  downloadId: r.id, baseName: r.baseName)
                              .then((_) => _refresh()),
                    )
                  : null,
              onTap: () => _openDetail(r),
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 90)),
      ]),
    );
  }
}
