import 'package:flutter/material.dart' hide RepeatMode;

import '../queue_player.dart';
import '../theme.dart';

/// Standalone queue page: covers, swipe actions, drag reorder,
/// multi-select, repeat/shuffle.
class QueuePage extends StatefulWidget {
  const QueuePage({super.key});

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
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
        (_selected.isEmpty || (_selected.length == 1 && _selected.contains(rowIdx)))
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
                title: Text('Play'))),
        PopupMenuItem(
            value: 'next',
            child: ListTile(
                dense: true,
                leading: Icon(Icons.low_priority, size: 18),
                title: Text('Play next'))),
        PopupMenuItem(
            value: 'remove',
            child: ListTile(
                dense: true,
                leading: Icon(Icons.playlist_remove, size: 18),
                title: Text('Remove from queue'))),
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


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Spots.base,
      appBar: AppBar(title: const Text('Queue')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            ValueListenableBuilder<RepeatMode>(
              valueListenable: qp.repeat,
              builder: (ctx, rep, _) => IconButton(
                  tooltip: 'Repeat',
                  onPressed: qp.cycleRepeat,
                  icon: Icon(switch (rep) {
                    RepeatMode.one => Icons.repeat_one,
                    RepeatMode.all => Icons.repeat,
                    _ => Icons.repeat_outlined,
                  },
                      size: 20,
                      color: rep == RepeatMode.off
                          ? Colors.white54
                          : Spots.green)),
            ),
            const SizedBox(width: 6),
            ValueListenableBuilder<bool>(
              valueListenable: qp.shuffleEnabled,
              builder: (ctx, shuf, _) => IconButton(
                  tooltip: 'Shuffle queue',
                  onPressed: qp.toggleShuffle,
                  icon: Icon(Icons.shuffle,
                      size: 20, color: shuf ? Spots.green : Colors.white54)),
            ),
            const Spacer(),
            Text('${qp.items.length} in queue',
                style:
                    const TextStyle(fontSize: 11.5, color: Colors.white38)),
          ]),
        ),
        Expanded(
          child: AnimatedBuilder(
            animation: Listenable.merge([qp, qp.revision]),
            builder: (ctx, _) {
              if (qp.items.isEmpty) {
                return const Center(
                    child: Text('Nothing in queue',
                        style: TextStyle(color: Colors.white38)));
              }
              return ReorderableListView.builder(
                buildDefaultDragHandles: false,
                proxyDecorator: (child, idx, anim) => Material(
                    color: Spots.elevated,
                    elevation: 6,
                    borderRadius: BorderRadius.circular(8),
                    child: child),
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
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            duration: const Duration(milliseconds: 900),
                            content: Text('“${it.title}” will play next')));
                        return false; // keep the row
                      }
                      setState(() => qp.removeAt({i}));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          duration: Duration(milliseconds: 900),
                          content: Text('Removed from queue')));
                      return true;
                    },
                    background: Container(
                        alignment: Alignment.centerLeft,
                        color: Spots.green.withOpacity(.25),
                        padding: const EdgeInsets.only(left: 20),
                        child: const Icon(Icons.low_priority,
                            size: 22, color: Spots.green)),
                    secondaryBackground: Container(
                        alignment: Alignment.centerRight,
                        color: Colors.redAccent.withOpacity(.25),
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.playlist_remove,
                            size: 22, color: Colors.redAccent)),
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
                                    : Colors.transparent),
                          ),
                          child: ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            leading: GestureDetector(
                              onTap: () => _toggleSel(i),
                              child: Stack(clipBehavior: Clip.none,
                                  children: [
                                    ClipRRect(
                                      borderRadius:
                                          BorderRadius.circular(5),
                                      child: it.thumbUrl != null
                                          ? Image.network(it.thumbUrl!,
                                              width: 42,
                                              height: 42,
                                              fit: BoxFit.cover,
                                              errorBuilder:
                                                  (_, __, ___) =>
                                                      _fallback())
                                          : _fallback(),
                                    ),
                                    Positioned.fill(
                                      child: Center(
                                        child: current
                                            ? Container(
                                                padding:
                                                    const EdgeInsets.all(
                                                        2),
                                                decoration:
                                                    const BoxDecoration(
                                                        color: Spots.base,
                                                        shape: BoxShape
                                                            .circle),
                                                child: const Icon(
                                                    Icons.graphic_eq,
                                                    size: 12,
                                                    color: Spots.green))
                                            : sel
                                                ? const Icon(
                                                    Icons.check_circle,
                                                    size: 18,
                                                    color: Spots.green)
                                                : null,
                                      ),
                                    ),
                                  ]),
                            ),
                            title: Text(it.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: current
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: current
                                        ? Spots.green
                                        : Colors.white70)),
                            subtitle: it.genreHint != null
                                ? Text('from ${it.genreHint}',
                                    style: const TextStyle(fontSize: 10.5))
                                : null,
                            onTap: () => _jump(i),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ReorderableDragStartListener(
                                  index: i,
                                  child: const Padding(
                                      padding: EdgeInsets.all(6),
                                      child: Icon(Icons.drag_handle,
                                          size: 18,
                                          color: Colors.white38)),
                                ),
                              ],
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
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
              'Swipe right = play next · left = remove · drag ≡ to reorder · tap ○ to select',
              style:
                  const TextStyle(fontSize: 10.5, color: Colors.white38)),
        ),
      ]),
    );
  }

  Widget _fallback() => Container(
      width: 42,
      height: 42,
      color: Spots.subtle,
      child: const Icon(Icons.music_note, size: 16, color: Colors.white38));
}
