import 'package:audioplayers/audioplayers.dart' show PlayerState;
import 'package:flutter/material.dart';

import '../api_client.dart';

import '../queue_player.dart';
import '../theme.dart';
import 'queue_page.dart';

/// Full-screen now-playing page. Fixed-size layout only (no flex) so
/// every control always lands on-screen.
class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key, this.api});
  final ApiClient? api;

  Future<Lyrics?> _lyrics() async {
    final item = QueuePlayer.instance.currentItem;
    final f = item?.filePath;
    if (f == null || api == null) return null;
    try {
      return await api!.lyrics(f);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final qp = QueuePlayer.instance;
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
              tooltip: 'Queue',
              icon: const Icon(Icons.queue_music_outlined),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const QueuePage()))),
          IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: () => Navigator.pop(context)),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(builder: (ctx, cons) {
          final h = cons.maxHeight;
          final artSide =
              (h < 560 ? h * .34 : h * .44).clamp(150.0, 330.0).toDouble();
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: h - 56),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Center(
                    child: ValueListenableBuilder<String>(
                      valueListenable: qp.currentThumb,
                      builder: (ctx, thumb, _) => ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: thumb.isNotEmpty
                            ? Image.network(thumb,
                                width: artSide,
                                height: artSide,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    _gradArt(artSide))
                            : _gradArt(artSide),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ValueListenableBuilder<String>(
                      valueListenable: qp.currentTitle,
                      builder: (ctx, t, _) => Text(
                          t.isEmpty ? 'Nothing playing' : t,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w800)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // seek bar
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: ValueListenableBuilder<Duration>(
                      valueListenable: qp.position,
                      builder: (ctx, pos, _) =>
                          ValueListenableBuilder<Duration>(
                        valueListenable: qp.trackDuration,
                        builder: (ctx, dur, __) {
                          final totalMs = dur.inMilliseconds > 0
                              ? dur.inMilliseconds.toDouble()
                              : 1.0;
                          return Column(children: [
                            SliderTheme(
                              data: Theme.of(ctx).sliderTheme.copyWith(
                                  overlayShape:
                                      SliderComponentShape.noOverlay),
                              child: Slider(
                                max: totalMs,
                                value: pos.inMilliseconds
                                    .clamp(0.0, totalMs)
                                    .toDouble(),
                                onChanged: (v) => qp.seek(
                                    Duration(milliseconds: v.round())),
                              ),
                            ),
                            Transform.translate(
                              offset: const Offset(0, -14),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(_fmt(pos),
                                        style: TextStyle(
                                            fontSize: 11.5,
                                            color: Colors.white54)),
                                    Text(_fmt(dur),
                                        style: TextStyle(
                                            fontSize: 11.5,
                                            color: Colors.white54)),
                                  ],
                                ),
                              ),
                            ),
                          ]);
                        },
                      ),
                    ),
                  ),
                  // transport controls
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ValueListenableBuilder<bool>(
                        valueListenable: qp.shuffleEnabled,
                        builder: (ctx, shuf, _) => IconButton(
                            iconSize: 26,
                            icon: Icon(shuf
                                ? Icons.shuffle
                                : Icons.shuffle_outlined),
                            color: shuf ? Spots.green : Colors.white70,
                            onPressed: qp.toggleShuffle),
                      ),
                      IconButton(
                          iconSize: 38,
                          icon: const Icon(Icons.skip_previous),
                          onPressed: qp.previous),
                      ValueListenableBuilder<PlayerState>(
                        valueListenable: qp.status,
                        builder: (ctx, st, _) {
                          final playing = st == PlayerState.playing;
                          return Material(
                            color: Colors.white,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () =>
                                  playing ? qp.pause() : qp.resume(),
                              child: SizedBox(
                                  width: 62,
                                  height: 62,
                                  child: Icon(
                                      playing
                                          ? Icons.pause
                                          : Icons.play_arrow,
                                      size: 38,
                                      color: Colors.black)),
                            ),
                          );
                        },
                      ),
                      IconButton(
                          iconSize: 38,
                          icon: const Icon(Icons.skip_next),
                          onPressed: qp.next),
                      // volume meter
                      GestureDetector(
                        onTap: () {},
                        child: ValueListenableBuilder<double>(
                          valueListenable: qp.volume,
                          builder: (ctx, vol, _) => Icon(
                              switch (vol) {
                                0 => Icons.volume_off,
                                < 0.5 => Icons.volume_down,
                                _ => Icons.volume_up,
                              },
                              size: 24,
                              color: Colors.white54),
                        ),
                      ),
                    ],
                  ),
                  // Up next (queue)
                  ValueListenableBuilder<int>(
                    valueListenable: qp.queueIndex,
                    builder: (ctx, cur, _) {
                      if (qp.items.length < 2) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('UP NEXT',
                                style: TextStyle(
                                    fontSize: 11.5,
                                    letterSpacing: .8,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white54)),
                            for (final (i, it) in qp.items.indexed)
                              if (i != cur)
                                ListTile(
                                  dense: true,
                                  visualDensity:
                                      VisualDensity.compact,
                                  leading: i == cur + 1 ||
                                          (cur == qp.items.length - 1 &&
                                              i == 0)
                                      ? const Icon(Icons.play_arrow,
                                          size: 16,
                                          color: Spots.green)
                                      : null,
                                  title: Text(it.title,
                                      maxLines: 1,
                                      overflow:
                                          TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13)),
                                ),
                          ],
                        ),
                      );
                    },
                  ),
                  // synced lyrics
                  ValueListenableBuilder<Duration>(
                    valueListenable: qp.position,
                    builder: (ctx, pos, _) => ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 150),
                      child: FutureBuilder<Lyrics?>(
                        future: _lyrics(),
                        builder: (ctx, snap) {
                          final l = snap.data;
                          if (l == null ||
                              (!l.hasSynced &&
                                  (l.plain == null ||
                                      l.plain!.isEmpty))) {
                            return const SizedBox.shrink();
                          }
                          if (!l.hasSynced) {
                            return Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8),
                              child: Text(l.plain!,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: Colors.white54)),
                            );
                          }
                          int active = -1;
                          for (var i = 0; i < l.synced.length; i++) {
                            if (l.synced[i].tMs <= pos.inMilliseconds) {
                              active = i;
                            }
                          }
                          return ListView.builder(
                            shrinkWrap: true,
                            itemCount: l.synced.length,
                            itemBuilder: (ctx, i) {
                              final on = i == active;
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 3),
                                child: Text(
                                  l.synced[i].text,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: on ? 15 : 13,
                                    fontWeight: on
                                        ? FontWeight.w800
                                        : FontWeight.w400,
                                    color: on
                                        ? Colors.white
                                        : Colors.white38,
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  // volume meter slider
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: ValueListenableBuilder<double>(
                      valueListenable: qp.volume,
                      builder: (ctx, vol, _) => Row(children: [
                        const Icon(Icons.volume_down,
                            size: 16, color: Colors.white38),
                        Expanded(
                          child: SliderTheme(
                            data: Theme.of(ctx).sliderTheme.copyWith(
                                overlayShape:
                                    SliderComponentShape.noOverlay),
                            child: Slider(
                                max: 1,
                                value: vol.clamp(0.0, 1.0),
                                onChanged: (v) => qp.setVolume(v)),
                          ),
                        ),
                        const Icon(Icons.volume_up,
                            size: 16, color: Colors.white38),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  static Widget _gradArt(double side) {
    return ValueListenableBuilder<String>(
      valueListenable: QueuePlayer.instance.currentTitle,
      builder: (ctx, t, _) => Container(
        width: side,
        height: side,
        decoration: BoxDecoration(
          gradient: Spots.coverGradient(t),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Center(
            child: Icon(Icons.music_note, size: 84, color: Colors.white30)),
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:$m' : m}:$s';
  }
}
