import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'now_playing.dart' show NowPlayingRoute;
import 'lang.dart';
import 'offline_store.dart';
import 'prefetch_store.dart';
import 'queue_player.dart';
import 'theme.dart';

/// "3 hr 42 min" — total playlist length.
String fmtTotal(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h > 0) return '$h hr $m min';
  return '$m min';
}

/// "3:42" clock for a single track.
String fmtClock(int seconds) {
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// "12 songs" / "1 song".
String fmtTracks(int n) => n == 1 ? tr('1 song') : '$n ${tr('songs')}';

/// "Artist - Song Name" (or any ' - ' separated string) -> just the song name.
/// Used in the small (mini) player which shows the title only, no artist.
String songNameOnly(String full) {
  final i = full.indexOf(' - ');
  return i > 0 ? full.substring(i + 3).trim() : full;
}

/// Rounded floating mini-player shown above the bottom nav.
class MiniPlayerBar extends StatefulWidget {
  const MiniPlayerBar({super.key});

  @override
  State<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends State<MiniPlayerBar> {
  double _dragUp = 0; // >0 while the user is pulling the bar upward

  void _openNowPlaying() {
    Navigator.of(context).push(NowPlayingRoute());
  }

  @override
  Widget build(BuildContext context) {
    final qp = QueuePlayerShim.instance;
    return ValueListenableBuilder<String>(
      valueListenable: qp.title,
      builder: (context, title, _) {
        if (title.isEmpty) return const SizedBox.shrink();
        final songName = songNameOnly(title);
        return GestureDetector(
          onTap: _openNowPlaying,
          onVerticalDragStart: (_) => setState(() => _dragUp = 0),
          onVerticalDragUpdate: (d) {
            final dy = d.delta.dy;
            setState(() => _dragUp = (_dragUp - dy).clamp(0.0, 120.0));
          },
          onVerticalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            setState(() => _dragUp = 0);
            if (v < -300) _openNowPlaying();
          },
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v < -300 && qp.hasNext) {
              qp.next();
            } else if (v > 300 && qp.hasPrev) {
              qp.previous();
            }
          },
          child: Transform.translate(
            offset: Offset(0, -_dragUp),
            child: Container(
              margin: EdgeInsets.fromLTRB(
                  8, 0, 8, 6 + MediaQuery.paddingOf(context).bottom),
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              decoration: BoxDecoration(
                color: Spots.elevated,
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(color: Colors.black45, blurRadius: 12),
                ],
              ),
              child: Row(
                children: [
                  ValueListenableBuilder<String>(
                    valueListenable: qp.thumb,
                    builder: (_, tb, __) => Hero(
                      tag: kPlayerArtHeroTag,
                      createRectTween: (begin, end) =>
                          MaterialRectCenterArcTween(begin: begin, end: end),
                      child: CoverThumb(title: title, thumbUrl: tb, size: 40),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _MiniMarqueeText(
                          songName,
                          key: ValueKey(songName),
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 5),
                        ValueListenableBuilder<double>(
                          valueListenable: qp.progress,
                          builder: (ctx, prog, _) => ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: prog.clamp(0.0, 1.0),
                              minHeight: 3,
                              backgroundColor: Spots.subtle,
                              valueColor: AlwaysStoppedAnimation(Spots.green),
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
                                strokeWidth: 2.5,
                              ),
                            ),
                          )
                        : ListenableBuilder(
                            listenable: qp.stateSyncing,
                            builder: (_, __) => IconButton(
                              visualDensity: VisualDensity.compact,
                              onPressed: qp.stateSyncing.value
                                  ? null
                                  : QueuePlayerShim.instance.toggle,
                              icon: StreamBuilder<PlayerState>(
                                stream: QueuePlayerShim.instance.stateStream,
                                initialData: null,
                                builder: (_, snap) {
                                  // Sole truth = native state-stream; cached
                                  // playing only seeds the null (buffering) frame.
                                  final playing = skinShowsPlaying(
                                      snap.data,
                                      lastPlaying: QueuePlayerShim
                                          .instance.playing);
                                  return Icon(
                                    playing ? Icons.pause : Icons.play_arrow,
                                    color: Spots.green,
                                  );
                                },
                              ),
                              iconSize: 32,
                            ),
                          ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.skip_next),
                    onPressed: () => QueuePlayerShim.instance.next(),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Tiny square cover with network thumb + gradient fallback.
class CoverThumb extends StatelessWidget {
  const CoverThumb({
    super.key,
    required this.title,
    required this.thumbUrl,
    this.size = 44,
    this.fallbackUrl,
  });

  final String title;
  final String? thumbUrl;
  final double size;

  /// Shown when the primary art is missing (e.g. the playlist photo).
  final String? fallbackUrl;

  @override
  Widget build(BuildContext context) {
    // Offline-first: a pre-cached cover (saved at download time) renders
    // instantly with no connection; otherwise fall back to network.
    final local = OfflineStore.coverFileFor(title);
    if (local != null) {
      // Decode at physical pixels (logical size x DPR): the old size x 1.5
      // decoded 66px for a 44px thumb and upscaled it on 2-3x screens
      // (blur/pixelation) — decode sharp, let BoxFit.cover crop.
      final cacheSize =
          (size * MediaQuery.of(context).devicePixelRatio).ceil();
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(local),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: cacheSize,
          errorBuilder: (_, __, ___) => _gradient(size),
        ),
      );
    }
    final url = thumbUrl ?? '';
    final fallback = fallbackUrl ?? '';
    if (url.isEmpty) {
      if (fallback.isNotEmpty) {
        return _image(context, fallback, size);
      }
      return _gradient(size);
    }
    return _image(
      context,
      url,
      size,
      onError: fallback.isEmpty ? null : () => _image(context, fallback, size),
    );
  }

  Widget _gradient(double size) {
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

  Widget _image(BuildContext context, String url, double size,
      {Widget Function()? onError}) {
    final cacheSize =
        (size * MediaQuery.of(context).devicePixelRatio).ceil();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      // NOTE: cacheWidth ONLY (never cacheHeight). Setting both forces
      // the decoder to that exact size and squishes non-square art
      // (e.g. 4:3 YouTube thumbnails) — stretched faces. Width-only keeps
      // the aspect; BoxFit.cover crops.
      child: Image.network(
        url,
        key: ValueKey(url),
        width: size,
        height: size,
        cacheWidth: cacheSize,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => onError != null
            ? onError()
            : Container(
                width: size,
                height: size,
                color: Spots.subtle,
                child: Icon(
                  Icons.music_note,
                  size: size * .5,
                  color: Colors.white70,
                ),
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

Future<T?> showTrackMenu<T>(
  BuildContext context,
  String title,
  List<TrackAction<T>> actions,
) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          ...actions.map(
            (a) => ListTile(
              leading: Icon(a.icon, color: Colors.white70),
              title: Text(a.label),
              onTap: () => Navigator.pop(ctx, a.value),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Mimics a full-size cover thumbnail (used inside the player).
/// Offline-first: checks for local cached cover first (works offline),
/// falls back to network, then gradient.
class CoverArt extends StatelessWidget {
  const CoverArt({
    super.key,
    required this.seed,
    required this.icon,
    this.networkUrl,
    this.size = 56,
  });

  final String seed;
  final IconData icon;
  final String? networkUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cacheSize =
        (size * MediaQuery.of(context).devicePixelRatio).ceil();

    // Offline-first: check for local cached cover first (works offline).
    final localCover =
        OfflineStore.coverFileFor(seed) ?? PrefetchStore.coverFileFor(seed);
    if (localCover != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(localCover),
          width: size,
          height: size,
          cacheWidth: cacheSize,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _gradientFallback(context),
        ),
      );
    }

    final url = networkUrl;
    if (url == null || url.isEmpty) {
      return _gradientFallback(context);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      // NOTE: cacheWidth ONLY — see above (both set = squished art).
      child: Image.network(
        url,
        key: ValueKey(url),
        width: size,
        height: size,
        cacheWidth: cacheSize,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _gradientFallback(context),
      ),
    );
  }

  Widget _gradientFallback(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: Spots.coverGradient(seed),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: Colors.white70, size: size * .45),
      );
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
  ValueListenable<bool> get stateSyncing => _qp.stateSyncing;
  bool get hasQueue => _qp.items.isNotEmpty;
  bool get hasNext => _qp.hasNext;
  bool get hasPrev => _qp.hasPrev;
  void next() => _qp.next();
  void previous() => _qp.previous();
  Future<void> toggle() => _qp.resumeOrPause();
  Future<void> playOne(QueueItem it) => _qp.playOne(it);

  void openNowPlaying(BuildContext context) {
    Navigator.push(context, NowPlayingRoute());
  }
}

/// Single-line, left-aligned mini-player title that begins scrolling
/// right-to-left when it is wider than its box, so long song names stay fully
/// readable in the small space. Scrolls noticeably faster than the removed
/// full-screen marquee.
class _MiniMarqueeText extends StatefulWidget {
  const _MiniMarqueeText(this.text, {super.key, required this.style});
  final String text;
  final TextStyle style;

  @override
  State<_MiniMarqueeText> createState() => _MiniMarqueeTextState();
}

class _MiniMarqueeTextState extends State<_MiniMarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scroll;
  double _textWidth = 0;
  double _boxWidth = 0;

  @override
  void initState() {
    super.initState();
    _scroll = AnimationController(vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart());
  }

  @override
  void didUpdateWidget(_MiniMarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _maybeStart();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeStart() {
    if (!mounted) return;
    if (_textWidth > _boxWidth + 0.5) {
      _scroll.duration = Duration(
        milliseconds: ((_textWidth + _boxWidth) * 30).round().clamp(
          2500,
          10000,
        ),
      );
      if (!_scroll.isAnimating) _scroll.repeat();
    } else if (_scroll.isAnimating) {
      _scroll.stop();
      _scroll.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, cons) {
        _boxWidth = cons.maxWidth;
        final tp = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        _textWidth = tp.width;
        _maybeStart();
        if (_textWidth <= _boxWidth + 0.5) {
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        return ClipRect(
          child: AnimatedBuilder(
            animation: _scroll,
            builder: (_, _) {
              final dx = (_boxWidth - (_textWidth + _boxWidth) * _scroll.value);
              return Transform.translate(
                offset: Offset(dx, 0),
                child: Text(
                  widget.text,
                  maxLines: 1,
                  softWrap: false,
                  style: widget.style,
                ),
              );
            },
          ),
        );
      },
    );
  }
}
