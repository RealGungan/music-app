import 'package:audioplayers/audioplayers.dart' show PlayerState;
import 'package:flutter/material.dart';

import 'api_client.dart';
import 'queue_player.dart';
import 'screens/now_playing.dart';
import 'theme.dart';

/// Spotify-desktop bottom player bar: 3 zones, ~84px, pure black.
class BottomPlayerBar extends StatelessWidget {
  const BottomPlayerBar({
    super.key,
    required this.onToggleQueue,
    required this.liked,
    required this.onToggleLike,
    this.api,
  });

  final VoidCallback onToggleQueue;
  final ValueNotifier<Set<String>> liked;
  final void Function(String baseName) onToggleLike;
  final ApiClient? api;

  static const h = 76.0;

  @override
  Widget build(BuildContext context) {
    final qp = QueuePlayer.instance;
    return Container(
      height: h,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        // ---------------- left: track info (opens now playing view)
        Expanded(
          flex: 3,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => NowPlayingPage(api: api))),
            child: ValueListenableBuilder<String>(
              valueListenable: qp.currentTitle,
              builder: (ctx, title, _) {
                if (title.isEmpty) return const SizedBox.shrink();
                return Row(children: [
                  ValueListenableBuilder<String>(
                    valueListenable: qp.currentThumb,
                    builder: (ctx, thumb, _) => ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: thumb.isNotEmpty
                          ? Image.network(thumb,
                              width: 52,
                              height: 52,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  _gradCover(title))
                          : _gradCover(title),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                  ),
                  ValueListenableBuilder<Set<String>>(
                    valueListenable: liked,
                    builder: (ctx, likedSet, _) {
                      final isLiked = likedSet.contains(title);
                      return IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: isLiked ? 'Remove from Liked' : 'Save to Liked',
                        icon: Icon(
                            isLiked
                                ? Icons.favorite
                                : Icons.favorite_border,
                            size: 18,
                            color:
                                isLiked ? Spots.green : Colors.white54),
                        onPressed: () => onToggleLike(title),
                      );
                    },
                  ),
                ]);
              },
            ),
          ),
        ),
        // ---------------- center: transport + seek
        Expanded(
          flex: 4,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                height: 32,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ValueListenableBuilder<int>(
                      valueListenable: qp.queueIndex,
                      builder: (ctx, cur, _) => Tooltip(
                        message: 'Previous',
                        child: _ctlIcon(Icons.skip_previous,
                            size: 26,
                            solid: true,
                            onTap: qp.items.length > 1 || cur > -1
                                ? qp.previous
                                : null),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ValueListenableBuilder<PlayerState>(
                      valueListenable: qp.status,
                      builder: (ctx, st, _) {
                        final playing = st == PlayerState.playing;
                        final started = st != PlayerState.stopped;
                        return InkWell(
                          onTap: !started
                              ? null
                              : () => playing ? qp.pause() : qp.resume(),
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle),
                            child: Icon(
                                playing ? Icons.pause : Icons.play_arrow,
                                size: 22,
                                color: Colors.black),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 10),
                    Tooltip(
                      message: 'Next',
                      child: _ctlIcon(Icons.skip_next,
                          size: 26, solid: true, onTap: qp.next),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 22,
                child: Row(children: [
                  ValueListenableBuilder<Duration>(
                    valueListenable: qp.position,
                    builder: (ctx, p, _) => Text(_fmt(p),
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white54)),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<Duration>(
                      valueListenable: qp.position,
                      builder: (ctx, pos, _) =>
                          ValueListenableBuilder<Duration>(
                        valueListenable: qp.trackDuration,
                        builder: (ctx, dur, __) {
                          final totalMs = dur.inMilliseconds > 0
                              ? dur.inMilliseconds.toDouble()
                              : 1.0;
                          return SliderTheme(
                            data: Theme.of(ctx).sliderTheme.copyWith(
                                overlayShape:
                                    SliderComponentShape.noOverlay,
                                trackHeight: 3.5,
                                thumbShape: const RoundSliderThumbShape(
                                    elevation: 0, enabledThumbRadius: 6)),
                            child: Slider(
                              max: totalMs,
                              value: pos.inMilliseconds
                                  .clamp(0.0, totalMs)
                                  .toDouble(),
                              onChanged: (v) => qp.seek(
                                  Duration(milliseconds: v.round())),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  ValueListenableBuilder<Duration>(
                    valueListenable: qp.trackDuration,
                    builder: (ctx, d, _) => Text(_fmt(d),
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white54)),
                  ),
                ]),
              ),
            ],
          ),
        ),
        // ---------------- right: queue toggle + volume meter
        Expanded(
          flex: 3,
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            IconButton(
                tooltip: 'Queue',
                icon: const Icon(Icons.queue_music, size: 20,
                    color: Colors.white54),
                onPressed: onToggleQueue),
            ValueListenableBuilder<double>(
              valueListenable: qp.volume,
              builder: (ctx, vol, _) => Icon(
                  switch (vol) {
                    0 => Icons.volume_off,
                    < 0.5 => Icons.volume_down,
                    _ => Icons.volume_up,
                  },
                  size: 19,
                  color: Colors.white54),
            ),
            SizedBox(
              width: 110,
              child: ValueListenableBuilder<double>(
                valueListenable: qp.volume,
                builder: (ctx, vol, _) => SliderTheme(
                  data: Theme.of(ctx).sliderTheme.copyWith(
                      overlayShape: SliderComponentShape.noOverlay,
                      trackHeight: 3.5,
                      thumbShape: const RoundSliderThumbShape(
                          elevation: 0, enabledThumbRadius: 6)),
                  child: Slider(max: 1, value: vol, onChanged: qp.setVolume),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  static Widget _gradCover(String t) => Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          gradient: Spots.coverGradient(t),
          borderRadius: BorderRadius.circular(4),
        ),
        child:
            const Icon(Icons.music_note, size: 20, color: Colors.white70),
      );

  static Widget _ctlIcon(IconData icon,
      {double size = 20, bool solid = false, bool active = false, VoidCallback? onTap}) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(icon,
          size: size, color: active ? Spots.green : Colors.white70),
      onPressed: onTap,
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:$m' : m}:$s';
  }
}
