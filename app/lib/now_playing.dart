import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'queue_player.dart';
import 'theme.dart';
import 'widgets.dart';

class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  final qp = QueuePlayer.instance;
  double _volume = 1.0;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = (d.inSeconds.remainder(60)).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _showQueue() {
    final items = qp.items;
    if (items.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Up next (${items.length})',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final active = i == qp.index;
                  return ListTile(
                    dense: true,
                    leading: Text('${i + 1}',
                        style: TextStyle(
                            color: active ? Spots.green : Colors.white38)),
                    title: Text(items[i].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: active ? Spots.green : null,
                            fontWeight: active ? FontWeight.w700 : null)),
                    trailing: active
                        ? const Icon(Icons.graphic_eq, color: Spots.green, size: 18)
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      qp.jumpTo(i);
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          ValueListenableBuilder<int>(
            valueListenable: qp.queueLength,
            builder: (_, n, __) => IconButton(
              icon: const Icon(Icons.queue_music),
              tooltip: 'Queue',
              onPressed: n > 0 ? _showQueue : null,
            ),
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24).copyWith(top: 8),
          child: Column(children: [
            Expanded(
              child: Center(
                child: ValueListenableBuilder<String>(
                  valueListenable: qp.currentTitle,
                  builder: (_, t, __) => ValueListenableBuilder<String>(
                    valueListenable: qp.currentThumb,
                    builder: (_, tb, ___) => Container(
                      width: 300,
                      height: 300,
                      child: CoverArt(
                        seed: t,
                        icon: Icons.music_note,
                        networkUrl: tb.isEmpty ? null : tb,
                        size: 300,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            ValueListenableBuilder<String>(
              valueListenable: qp.currentTitle,
              builder: (_, t, __) => Text(
                t,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<Duration>(
              valueListenable: qp.position,
              builder: (_, pos, __) =>
                  ValueListenableBuilder<Duration>(
                valueListenable: qp.trackDuration,
                builder: (_, dur, ___) => Slider(
                  value: (dur > Duration.zero)
                      ? pos.inMilliseconds
                              .clamp(0, dur.inMilliseconds)
                              .toDouble()
                      : 0,
                  max: (dur > Duration.zero)
                      ? dur.inMilliseconds.toDouble()
                      : 1,
                  activeColor: Spots.green,
                  inactiveColor: Spots.subtle,
                  onChanged: (v) =>
                      qp.seek(Duration(milliseconds: v.round())),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                ValueListenableBuilder<Duration>(
                  valueListenable: qp.position,
                  builder: (_, p, __) => Text(_fmt(p),
                      style: const TextStyle(fontSize: 12, color: Colors.white54)),
                ),
                const Spacer(),
                ValueListenableBuilder<Duration>(
                  valueListenable: qp.trackDuration,
                  builder: (_, d, __) => Text(_fmt(d),
                      style: const TextStyle(fontSize: 12, color: Colors.white54)),
                ),
              ]),
            ),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              ValueListenableBuilder<bool>(
                valueListenable: qp.shuffleEnabled,
                builder: (_, sh, __) => IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.shuffle,
                      color: sh ? Spots.green : Colors.white54),
                  onPressed: qp.toggleShuffle,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.skip_previous, size: 36),
                onPressed: qp.previous,
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<bool>(
                valueListenable: qp.loading,
                builder: (_, loading, __) => loading
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: SizedBox(
                            width: 30,
                            height: 30,
                            child: CircularProgressIndicator(
                                strokeWidth: 3)),
                      )
                    : StreamBuilder<PlayerState>(
                        stream: qp.stateStream,
                        initialData:
                            qp.playing ? PlayerState.playing : PlayerState.paused,
                        builder: (_, snap) => IconButton(
                          visualDensity: VisualDensity.compact,
                          iconSize: 60,
                          color: Colors.white,
                          onPressed: () => qp.resumeOrPause(),
                          icon: Icon(
                              snap.data == PlayerState.playing
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_fill,
                              color: Colors.white),
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.skip_next, size: 36),
                onPressed: qp.next,
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<bool>(
                valueListenable: qp.repeatEnabled,
                builder: (_, rep, __) => IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.repeat,
                      color: rep ? Spots.green : Colors.white54),
                  onPressed: qp.toggleRepeat,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            if (kIsWeb || defaultTargetPlatform != TargetPlatform.android)
              Row(children: [
                const Icon(Icons.volume_down, size: 18, color: Colors.white54),
                Expanded(
                  child: Slider(
                    value: _volume,
                    activeColor: Spots.green,
                    inactiveColor: Spots.subtle,
                    onChanged: (v) {
                      setState(() => _volume = v);
                      qp.setVolume(v);
                    },
                  ),
                ),
                const Icon(Icons.volume_up, size: 18, color: Colors.white54),
              ]),
            const SizedBox(height: 16),
          ]),
        ),
      ),
    );
  }
}
