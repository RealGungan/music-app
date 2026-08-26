import 'package:flutter/material.dart' hide RepeatMode;

import '../queue_player.dart';
import '../theme.dart';

/// Standalone queue page (mobile-friendly).
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

  Future<void> _menu(BuildContext ctx, Offset pos, int rowIdx) async {
    final targets = _selected.isEmpty ||
            (_selected.length == 1 && _selected.contains(rowIdx))
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
        case 'remove':
          qp.removeAt(targets);
      }
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Spots.base,
      appBar: AppBar(title: const Text('Queue')),
      body: AnimatedBuilder(
        animation: Listenable.merge([qp, qp.status]),
        builder: (ctx, _) {
          final cur = qp.queueIndex.value;
          if (qp.items.isEmpty) {
            return const Center(
                child: Text('Nothing in queue',
                    style: TextStyle(color: Colors.white38)));
          }
          return Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Tooltip(
                  message: 'Repeat',
                  child: InkWell(
                    onTap: qp.cycleRepeat,
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: ValueListenableBuilder<RepeatMode>(
                        valueListenable: qp.repeat,
                        builder: (ctx, rep, _) => Icon(
                            switch (rep) {
                              RepeatMode.one => Icons.repeat_one,
                              RepeatMode.all => Icons.repeat,
                              _ => Icons.repeat_outlined,
                            },
                            size: 19,
                            color: rep == RepeatMode.off
                                ? Colors.white54
                                : Spots.green),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Shuffle queue',
                  child: InkWell(
                    onTap: qp.toggleShuffle,
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: ValueListenableBuilder<bool>(
                        valueListenable: qp.shuffleEnabled,
                        builder: (ctx, shuf, _) => Icon(Icons.shuffle,
                            size: 19,
                            color:
                                shuf ? Spots.green : Colors.white54),
                      ),
                    ),
                  ),
                ),
                if (_selected.isNotEmpty) ...[
                  const Spacer(),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        textStyle: const TextStyle(fontSize: 12)),
                    onPressed: () => setState(() {
                      qp.playNext(Set.of(_selected));
                      _selected.clear();
                    }),
                    icon: const Icon(Icons.low_priority, size: 15),
                    label: const Text('Play next'),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        textStyle: const TextStyle(fontSize: 12)),
                    onPressed: () => setState(() {
                      qp.removeAt(Set.of(_selected));
                      _selected.clear();
                    }),
                    icon: const Icon(Icons.playlist_remove, size: 15),
                    label: const Text('Remove'),
                  ),
                ] else
                  const Spacer(),
              ]),
            ),
            Expanded(
              child: ReorderableListView.builder(
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
                  final current = i == cur && qp.hasTrack;
                  final sel = _selected.contains(i);
                  return ReorderableDragStartListener(
                    key: ValueKey('${i}_${it.title}_${it.url}'),
                    index: i,
                    child: GestureDetector(
                      onSecondaryTapUp: (d) =>
                          _menu(context, d.globalPosition, i),
                      onLongPress: () => _jump(i),
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
                            child: Container(
                              width: 30,
                              height: 30,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: sel
                                        ? Spots.green
                                        : Colors.white24,
                                    width: 1.5),
                                color: sel
                                    ? Spots.green.withOpacity(.2)
                                    : Colors.transparent,
                              ),
                              child: current
                                  ? const Icon(Icons.graphic_eq,
                                      size: 15, color: Spots.green)
                                  : sel
                                      ? const Icon(Icons.check,
                                          size: 15, color: Spots.green)
                                      : it.thumbUrl != null
                                          ? ClipOval(
                                              child: Image.network(
                                                  it.thumbUrl!,
                                                  width: 26,
                                                  height: 26,
                                                  fit: BoxFit.cover,
                                                  errorBuilder:
                                                      (_, __, ___) =>
                                                          Text('${i + 1}',
                                                              style: const TextStyle(
                                                                  fontSize:
                                                                      10.5,
                                                                  color: Colors
                                                                      .white38))))
                                          : Text('${i + 1}',
                                              style: const TextStyle(
                                                  fontSize: 10.5,
                                                  color: Colors.white38)),
                            ),
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
                                      : sel
                                          ? Colors.white
                                          : Colors.white70)),
                          subtitle: it.genreHint != null
                              ? Text('from ${it.genreHint}',
                                  style: const TextStyle(fontSize: 10.5))
                              : null,
                          onTap: () => _jump(i),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Auto-adds more when the queue runs out',
                  style:
                      const TextStyle(fontSize: 10.5, color: Colors.white38)),
            ),
          ]);
        },
      ),
    );
  }

  void _jump(int i) {
    if (_selected.isNotEmpty) setState(() => _selected.clear());
    qp.jumpTo(i);
  }
}
