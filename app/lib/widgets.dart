import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'now_playing.dart' show NowPlayingScreen;
import 'queue_player.dart';
import 'theme.dart';

/// Rounded floating mini-player shown above the bottom nav.
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final qp = QueuePlayerShim.instance;
    return ValueListenableBuilder<String>(
      valueListenable: qp.title,
      builder: (context, title, _) {
        if (title.isEmpty) return const SizedBox.shrink();
        return GestureDetector(
          onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const NowPlayingScreen())),
          child: Container(
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            decoration: BoxDecoration(
              color: Spots.elevated,
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [
                BoxShadow(color: Colors.black45, blurRadius: 12),
              ],
            ),
            child: Row(children: [
              ValueListenableBuilder<String>(
                valueListenable: qp.thumb,
                builder: (_, tb, __) => CoverThumb(
                    title: title, thumbUrl: tb, size: 40),
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
                    ValueListenableBuilder<double>(
                      valueListenable: qp.progress,
                      builder: (ctx, prog, _) => ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: prog.clamp(0.0, 1.0),
                          minHeight: 3,
                          backgroundColor: Spots.subtle,
                          valueColor:
                              const AlwaysStoppedAnimation(Spots.green),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: QueuePlayerShim.instance.loading,
                builder: (_, loading, __) => loading
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5)),
                      )
                    : IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: QueuePlayerShim.instance.toggle,
                        icon: StreamBuilder<PlayerState>(
                          stream: QueuePlayerShim.instance.stateStream,
                          initialData: null,
                          builder: (_, snap) {
                            final playing = snap.data == PlayerState.playing ||
                                (snap.data == null &&
                                    QueuePlayerShim.instance.playing);
                            return Icon(
                                playing ? Icons.pause : Icons.play_arrow,
                                color: Spots.green);
                          },
                        ),
                        iconSize: 32,
                      ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.skip_next),
                onPressed: () => QueuePlayerShim.instance.next(),
              ),
            ]),
          ),
        );
      },
    );
  }
}

/// Tiny square cover with network thumb + gradient fallback.
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
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: size,
          height: size,
          color: Spots.subtle,
          child:
              Icon(Icons.music_note, size: size * .5, color: Colors.white70),
        ),
      ),
    );
  }
}

/// A single actionable item shown in a track popup menu.
class TrackAction<T> {
  final String label;
  final IconData icon;
  final T value;
  TrackAction(this.label, this.icon, this.value);
}

Future<T?> showTrackMenu<T>(BuildContext context, String title,
    List<TrackAction<T>> actions) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700)),
        ),
        ...actions.map((a) => ListTile(
              leading: Icon(a.icon, color: Colors.white70),
              title: Text(a.label),
              onTap: () => Navigator.pop(ctx, a.value),
            )),
        const SizedBox(height: 8),
      ]),
    ),
  );
}

/// Mimics a full-size cover thumbnail (used inside the player).
class CoverArt extends StatelessWidget {
  const CoverArt(
      {super.key,
      required this.seed,
      required this.icon,
      this.networkUrl,
      this.size = 56});

  final String seed;
  final IconData icon;
  final String? networkUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = networkUrl;
    if (url == null || url.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: Spots.coverGradient(seed),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: Colors.white70, size: size * .45),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: Spots.coverGradient(seed),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.white70, size: size * .45),
        ),
      ),
    );
  }
}

/// Bridge that lets widget-layer code reach the singleton without
/// importing implementation details everywhere.
class QueuePlayerShim {
  QueuePlayerShim._();
  static final QueuePlayerShim instance = QueuePlayerShim._();
  late final QueuePlayer _qp = QueuePlayer.instance;

  ValueListenable<String> get title => _qp.currentTitle;
  ValueListenable<String> get thumb => _qp.currentThumb;
  ValueListenable<double> get progress => _qp.progressFractionNotifier;
  ValueListenable<bool> get loading => _qp.loading;
  ValueListenable<String?> get lastError => _qp.lastError;
  Stream<PlayerState> get stateStream => _qp.stateStream;
  bool get playing => _qp.playing;
  bool get hasQueue => _qp.items.isNotEmpty;
  void next() => _qp.next();
  void previous() => _qp.previous();
  Future<void> toggle() =>
      _qp.playing ? _qp.pause() : _qp.resume();
  Future<void> playOne(QueueItem it) => _qp.playOne(it);

  void openNowPlaying(BuildContext context) {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const NowPlayingScreen()));
  }
}
