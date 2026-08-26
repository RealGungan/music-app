import 'package:flutter/material.dart' hide RepeatMode;

import '../queue_player.dart';
import '../theme.dart';

/// Spotify-style queue panel (embedded in Now Playing / desktop side).
class QueuePanel extends StatefulWidget {
  const QueuePanel({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  final Set<int> _selected = {};
  final qp = QueuePlayer.instance;

  void _toggleSel(int i) => setState(() {
    _selected.contains(i) ? _selected.remove(i) : _selected.add(i);
  });

  void _jump(int i) {
    if (_selected.isNotEmpty) setState(() => _selected.clear());
    qp.jumpTo(i);
  }

  Future<void> _menu(BuildContext ctx, Offset pos, int rowIdx) async {
    final targets =
        (_selected.isEmpty ||
            (_selected.length == 1 && _selected.contains(rowIdx)))
        ? <int>{rowIdx}
        : Set.of(_selected);
    final action = await showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      color: Spots.elevated,
      items: const [
        PopupMenuItem(
          value: 'play',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.play_arrow, size: 18),
            title: Text('Play'),
          ),
        ),
        PopupMenuItem(
          value: 'next',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.low_priority, size: 18),
            title: Text('Play next'),
          ),
        ),
        PopupMenuItem(
          value: 'remove',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.playlist_remove, size: 18),
            title: Text('Remove from queue'),
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    setState(() {
      switch (action) {
        case 'play':
          _selected.clear();
          qp.jumpTo(rowIdx);
        case 'next':
          qp.playNext(targets);
          _selected.clear();
        case 'remove':
          qp.removeAt(targets);
          _selected.clear();
      }
    });
  }

  Widget _cover(QueueItem it) {
    if (it.thumbUrl != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Image.network(
          it.thumbUrl!,
          width: 42,
          height: 42,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              Container(width: 42, height: 42, color: Spots.subtle),
        ),
      );
    }
    return Container(width: 42, height: 42, color: Spots.subtle);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: const BoxDecoration(color: Colors.black),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 6, 0),
            child: Row(
              children: [
                const Text(
                  'Queue',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                const Spacer(),
                ValueListenableBuilder<RepeatMode>(
                  valueListenable: qp.repeat,
                  builder: (ctx, rep, _) => IconButton(
                    tooltip: 'Repeat',
                    onPressed: qp.cycleRepeat,
                    icon: Icon(
                      switch (rep) {
                        RepeatMode.one => Icons.repeat_one,
                        RepeatMode.all => Icons.repeat,
                        _ => Icons.repeat_outlined,
                      },
                      size: 19,
                      color: rep == RepeatMode.off
                          ? Colors.white54
                          : Spots.green,
                    ),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: qp.shuffleEnabled,
                  builder: (ctx, shuf, _) => IconButton(
                    tooltip: 'Shuffle queue',
                    onPressed: qp.toggleShuffle,
                    icon: Icon(
                      Icons.shuffle,
                      size: 19,
                      color: shuf ? Spots.green : Colors.white54,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(
                    Icons.close,
                    size: 19,
                    color: Colors.white54,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: AnimatedBuilder(
              animation: qp.revision,
              builder: (ctx, _) {
                if (qp.items.isEmpty) {
                  return const Center(
                    child: Text(
                      'Nothing in queue',
                      style: TextStyle(color: Colors.white38),
                    ),
                  );
                }
                return ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  proxyDecorator: (child, idx, anim) => Material(
                    color: Spots.elevated,
                    elevation: 6,
                    borderRadius: BorderRadius.circular(8),
                    child: child,
                  ),
                  onReorder: (oldI, newI) {
                    if (newI > oldI) newI -= 1;
                    qp.reorder(oldI, newI);
                  },
                  itemCount: qp.items.length,
                  itemBuilder: (ctx, i) {
                    final it = qp.items[i];
                    final current = i == qp.queueIndex.value && qp.hasTrack;
                    final sel = _selected.contains(i);
                    return Dismissible(
                      key: ValueKey('${i}_${it.title}_${it.url}'),
                      direction: DismissDirection.horizontal,
                      confirmDismiss: (dir) async {
                        if (dir == DismissDirection.startToEnd) {
                          setState(() => qp.playNext({i}));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              duration: const Duration(milliseconds: 900),
                              content: Text('${it.title} will play next'),
                            ),
                          );
                          return false; // keep the row
                        }
                        setState(() => qp.removeAt({i}));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            duration: Duration(milliseconds: 900),
                            content: Text('Removed from queue'),
                          ),
                        );
                        return true;
                      },
                      background: Container(
                        alignment: Alignment.centerLeft,
                        color: Spots.green.withOpacity(.25),
                        padding: const EdgeInsets.only(left: 20),
                        child: const Icon(
                          Icons.low_priority,
                          size: 22,
                          color: Spots.green,
                        ),
                      ),
                      secondaryBackground: Container(
                        alignment: Alignment.centerRight,
                        color: Colors.redAccent.withOpacity(.25),
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(
                          Icons.playlist_remove,
                          size: 22,
                          color: Colors.redAccent,
                        ),
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: GestureDetector(
                          onSecondaryTapUp: (d) =>
                              _menu(context, d.globalPosition, i),
                          child: Container(
                            decoration: BoxDecoration(
                              color: current
                                  ? Spots.green.withOpacity(.08)
                                  : sel
                                  ? Colors.white.withOpacity(.06)
                                  : null,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: current
                                    ? Spots.green.withOpacity(.35)
                                    : Colors.transparent,
                              ),
                            ),
                            child: ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              leading: GestureDetector(
                                onTap: () => _toggleSel(i),
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    _cover(it),
                                    Positioned.fill(
                                      child: Center(
                                        child: current
                                            ? Container(
                                                padding: const EdgeInsets.all(
                                                  2,
                                                ),
                                                decoration: const BoxDecoration(
                                                  color: Spots.base,
                                                  shape: BoxShape.circle,
                                                ),
                                                child: const Icon(
                                                  Icons.graphic_eq,
                                                  size: 12,
                                                  color: Spots.green,
                                                ),
                                              )
                                            : sel
                                            ? const Icon(
                                                Icons.check_circle,
                                                size: 18,
                                                color: Spots.green,
                                              )
                                            : null,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              title: Text(
                                it.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: current
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: current
                                      ? Spots.green
                                      : sel
                                      ? Colors.white
                                      : Colors.white70,
                                ),
                              ),
                              subtitle: it.genreHint != null
                                  ? Text(
                                      'from ${it.genreHint}',
                                      style: const TextStyle(fontSize: 10.5),
                                    )
                                  : null,
                              onTap: () => _jump(i),
                              trailing: ReorderableDragStartListener(
                                index: i,
                                child: const Padding(
                                  padding: EdgeInsets.all(6),
                                  child: Icon(
                                    Icons.drag_handle,
                                    size: 18,
                                    color: Colors.white38,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Swipe right = play next · left = remove · tap ○ to select · ≡ to reorder',
                style: const TextStyle(fontSize: 10.5, color: Colors.white38),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
