import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../keep_dialog.dart';
import '../theme.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final dls = await widget.api.downloads();
      if (!mounted) return;
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
    }
  }

  /// Let the user pick among candidates for a failed download.
  Future<void> _pickAndRetry(DownloadRow d) async {
    late final List<Candidate> cands;
    try {
      cands = await widget.api.candidates(d.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
      return;
    }
    if (!mounted) return;
    if (cands.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No candidates.')));
      return;
    }
    final sel = await showModalBottomSheet<Candidate>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Choose a version to retry',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: cands.length,
              itemBuilder: (_, i) {
                final c = cands[i];
                return ListTile(
                  title: Text(c.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(c.channel,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(ctx, c),
                );
              },
            ),
          ),
        ]),
      ),
    );
    if (sel == null || !mounted) return;
    try {
      await widget.api.redownload(d.id, sel.videoId);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _remove(DownloadRow d) async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text('Discard "${d.baseName}"?'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Discard')),
              ],
            ));
    if (confirm != true || !mounted) return;
    try {
      await widget.api.remove(d.id);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  bool get _isBusy =>
      _downloads.any((d) =>
          d.status == 'downloading' ||
          d.status == 'searching' ||
          d.status == 'queued');

  String _statusLabel(String s) =>
      s == 'staged' ? 'downloaded — save it' : s;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isBusy ? 'Staging…' : 'Staging'),
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
              : _downloads.isEmpty
                  ? const Center(
                      child: Text('Nothing staged yet.\n\n'
                          'Search -> pick a track -> it downloads here.\n'
                          'Save the ones you like.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54)))
                  : RefreshIndicator(
                      onRefresh: () => _load(),
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _downloads.length,
                        itemBuilder: (_, i) {
                          final d = _downloads[i];
                          final done = d.status == 'staged' ||
                              d.status == 'kept';
                          return ListTile(
                            leading: CoverThumb(
                              title: d.baseName,
                              thumbUrl: d.status == 'staged' ||
                                      d.status == 'kept'
                                  ? widget.api.coverUrl('/staging/file/${d.path}')
                                  : null,
                            ),
                            title: Text(d.baseName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            subtitle: Row(children: [
                              if (d.status == 'downloading' ||
                                  d.status == 'searching' ||
                                  d.status == 'queued') ...[
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                                const SizedBox(width: 8),
                              ],
                              if (d.status == 'failed')
                                const Icon(Icons.error_outline,
                                    size: 15, color: Colors.redAccent),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(_statusLabel(d.status),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: done
                                            ? Spots.green
                                            : Colors.white54,
                                        fontSize: 12)),
                              ),
                            ]),
                            trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (d.status == 'staged')
                                    IconButton(
                                      icon: const Icon(Icons.save_outlined),
                                      tooltip: 'Save',
                                      onPressed: () async {
                                        final pl =
                                            await showModalBottomSheet<String>(
                                          context: context,
                                          showDragHandle: true,
                                          builder: (_) => KeepPlaylistSheet(
                                                  api: widget.api),
                                        );
                                        if (pl == null) return;
                                        String msg;
                                        try {
                                          await widget.api.addToPlaylist(
                                              downloadId: d.id,
                                              playlist: pl);
                                          msg =
                                              'Saved to "$pl" and moved to your library';
                                        } catch (e) {
                                          msg = 'Failed: $e';
                                        }
                                        if (mounted) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                                  SnackBar(content: Text(msg)));
                                        }
                                        await _load();
                                      },
                                    ),
                                  if (d.status == 'failed')
                                    IconButton(
                                      icon: const Icon(Icons.refresh),
                                      tooltip: 'Retry',
                                      onPressed: () => _pickAndRetry(d),
                                    ),
                                  PopupMenuButton<String>(
                                    onSelected: (v) {
                                      if (v == 'remove') _remove(d);
                                    },
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                          value: 'remove',
                                          child: Text('Discard')),
                                    ],
                                  ),
                                ]),
                          );
                        },
                      ),
                    ),
    );
  }
}
