import 'package:audioplayers/audioplayers.dart' show PlayerState;
import 'package:flutter/material.dart';

import 'queue_player.dart';
import 'screens/now_playing.dart';
import 'theme.dart';

export 'queue_player.dart' show QueueItem;

/// Rounded floating mini-player. Tap opens the full NowPlayingPage route.
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final qp = QueuePlayer.instance;
    return ValueListenableBuilder<String>(
      valueListenable: qp.currentTitle,
      builder: (context, title, _) {
        if (title.isEmpty) return const SizedBox.shrink();
        return GestureDetector(
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const NowPlayingPage())),
          child: Container(
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            decoration: BoxDecoration(
              color: Spots.elevated,
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [
                BoxShadow(color: Colors.black45, blurRadius: 12)
              ],
            ),
            child: Row(children: [
              ValueListenableBuilder<String>(
                valueListenable: qp.currentThumb,
                builder: (ctx, thumb, _) => CoverThumb(
                    title: title, thumbUrl: thumb, size: 40),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 5),
                    ValueListenableBuilder<Duration>(
                      valueListenable: qp.position,
                      builder: (ctx, pos, _) =>
                          ValueListenableBuilder<Duration>(
                        valueListenable: qp.trackDuration,
                        builder: (ctx, dur, __) => ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: dur.inMilliseconds > 0
                                ? (pos.inMilliseconds / dur.inMilliseconds)
                                    .clamp(0.0, 1.0)
                                : 0,
                            minHeight: 3,
                            backgroundColor: Spots.subtle,
                            valueColor:
                                const AlwaysStoppedAnimation(Spots.green),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ValueListenableBuilder<PlayerState>(
                valueListenable: qp.status,
                builder: (ctx, st, _) {
                  final playing = st == PlayerState.playing;
                  final started = st != PlayerState.stopped;
                  return IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(playing
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill),
                    iconSize: 32,
                    onPressed: !started
                        ? null
                        : () => playing ? qp.pause() : qp.resume(),
                  );
                },
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.skip_next),
                onPressed: qp.next,
              ),
            ]),
          ),
        );
      },
    );
  }
}

/// Small square cover with network thumb + gradient fallback.
class CoverThumb extends StatelessWidget {
  const CoverThumb(
      {super.key, required this.title, required this.thumbUrl, this.size = 44});

  final String title;
  final String? thumbUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = thumbUrl ?? '';
    if (url.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: Spots.coverGradient(title),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.music_note, size: size * .5, color: Colors.white70),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
              width: size,
              height: size,
              color: Spots.subtle,
              child: Icon(Icons.music_note,
                  size: size * .5, color: Colors.white70))),
    );
  }
}
