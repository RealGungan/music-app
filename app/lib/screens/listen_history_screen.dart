import 'package:flutter/material.dart';

import '../api_client.dart';
import '../history.dart';
import '../lang.dart';
import '../song_context.dart';
import '../widgets.dart';

class ListenHistoryScreen extends StatefulWidget {
  const ListenHistoryScreen({super.key, required this.api, this.visible = true});
  final ApiClient api;
  // True while this tab is showing. The _HomeShell IndexedStack never
  // disposes children, so a tab-tap would otherwise show stale rows.
  final bool visible;

  @override
  State<ListenHistoryScreen> createState() => _ListenHistoryScreenState();
}

class _ListenHistoryScreenState extends State<ListenHistoryScreen> {
  List<String> _items = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  @override
  void didUpdateWidget(ListenHistoryScreen old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible) _reload();
  }

  Future<void> _reload() async {
    final l = await AppHistory.loadListen();
    if (mounted) setState(() => _items = l);
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(tr('Listen history'),
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            if (_items.isNotEmpty)
              TextButton(
                onPressed: () async {
                  await AppHistory.clearListen();
                  _reload();
                },
                child: Text(tr('Clear')),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          tr('Songs you played, most recent first'),
          style: TextStyle(fontSize: 12, color: Colors.white54),
        ),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: _items.isEmpty
            ? Center(
                child: Text(tr('Nothing played yet.'),
                    style: TextStyle(color: Colors.white38)),
              )
            : RefreshIndicator(
                onRefresh: _reload,
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: _items.length,
                  itemBuilder: (_, i) {
                    final parts = _items[i].split(' - ');
                    return ListTile(
                      dense: true,
                      leading: _HistoryCover(
                          api: widget.api, base: _items[i]),
                      title: Text(_items[i],
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => playArtistTitle(
                        context,
                        api: widget.api,
                        artist: parts.length > 1 ? parts.first.trim() : '',
                        title: parts.length > 1
                            ? parts.sublist(1).join(' - ').trim()
                            : _items[i],
                      ),
                    );
                  },
                ),
              ),
      ),
    ]);
  }
}

/// Per-row cover: suggest albumImage, else inNas albumImage, else the NAS
/// cover endpoint for the inNas file — never a hardcoded null.
class _HistoryCover extends StatefulWidget {
  const _HistoryCover({required this.api, required this.base});
  final ApiClient api;
  final String base;

  @override
  State<_HistoryCover> createState() => _HistoryCoverState();
}

class _HistoryCoverState extends State<_HistoryCover> {
  // One-flight per base across rows + tab revisits (history caps at 30).
  static final Map<String, String> _artCache = {};
  String? _art;

  @override
  void initState() {
    super.initState();
    if (_artCache.containsKey(widget.base)) {
      _art = _artCache[widget.base];
      return;
    }
    () async {
      var art = '';
      try {
        final rows = await widget.api.suggest(widget.base);
        for (final s in rows) {
          art = s.albumImage ?? '';
          if (art.isNotEmpty) break;
        }
      } catch (_) {}
      if (art.isEmpty) {
        try {
          final parts = widget.base.split(' - ');
          final nas = await widget.api.inNas(
            artist: parts.length > 1 ? parts.first.trim() : '',
            title: parts.length > 1
                ? parts.sublist(1).join(' - ').trim()
                : widget.base,
          );
          if (nas.found) {
            art = nas.albumImage ?? '';
            if (art.isEmpty && (nas.url?.isNotEmpty ?? false)) {
              art = widget.api.coverUrl(nas.url!);
            }
          }
        } catch (_) {}
      }
      _artCache[widget.base] = art;
      if (mounted) setState(() => _art = art);
    }();
  }

  @override
  Widget build(BuildContext context) {
    final a = (_art ?? '').isEmpty ? null : _art;
    return CoverThumb(title: widget.base, thumbUrl: a, size: 40);
  }
}
