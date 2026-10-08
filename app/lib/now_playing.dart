import 'dart:math' as math;
import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api_client.dart';
import 'keep_dialog.dart';
import 'lang.dart';
import 'lyrics_sheet.dart';
import 'offline_store.dart';
import 'prefetch_store.dart';
import 'queue_player.dart';
import 'share_story.dart';
import 'screens/album_screen.dart';
import 'screens/artist_screen.dart';
import 'theme.dart';
import 'toast.dart';
import 'widgets.dart';

/// Which service a shared song link should point at.
enum _ShareTarget { ytmusic, spotify, instagram }

/// Transition route for the Now Playing screen: fades the player content in
/// over a soft dim, while the album art itself flies in from the mini
/// player's thumbnail via a shared Hero ([kPlayerArtHeroTag]) — a smooth
/// YouTube-Music-style expansion. Reverses on close.
class NowPlayingRoute extends PageRouteBuilder<void> {
  NowPlayingRoute()
    : super(
        opaque: false,
        pageBuilder: (_, __, ___) => const NowPlayingScreen(),
        transitionDuration: const Duration(milliseconds: 460),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (_, anim, __, child) {
          // The dim appears first so the home screen reads as "behind" while
          // the art starts flying in; the full player then fades in AND rises
          // slightly as the artwork settles — a smooth, cover-anchored reveal
          // instead of an instant opaque background. Reverses on close.
          final dim = Tween<double>(begin: 0, end: 1).animate(
            CurvedAnimation(
              parent: anim,
              curve: const Interval(0, 0.5, curve: Curves.easeOut),
            ),
          );
          final fade = Tween<double>(begin: 0, end: 1).animate(
            CurvedAnimation(
              parent: anim,
              curve: const Interval(0.12, 0.92, curve: Curves.easeOutCubic),
            ),
          );
          final rise = Tween<Offset>(
            begin: const Offset(0, 0.06),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic));
          return Stack(
            fit: StackFit.expand,
            children: [
              FadeTransition(
                opacity: dim,
                child: const ColoredBox(color: Colors.black54),
              ),
              FadeTransition(
                opacity: fade,
                child: SlideTransition(position: rise, child: child),
              ),
            ],
          );
        },
      );
}

class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key, this.editMode = false});

  /// Renders a real copy of the fullscreen player where every control is
  /// inert and the secondary button row is draggable to rearrange, so the
  /// layout editor looks exactly like the live screen.
  final bool editMode;

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen>
    with TickerProviderStateMixin {
  final qp = QueuePlayer.instance;
  bool get _edit => widget.editMode;
  double _volume = 1.0;
  late final AnimationController _artController;
  late final AnimationController _closeCtrl;
  late final AnimationController _queueCtrl;
  double _dragX = 0;
  int _artDir = 0; // 1 = next (swipe left), -1 = prev (swipe right)
  bool _artAnim = false;
  // Scrub accumulator for slow horizontal drags on the art: every 60px of
  // drag seeks ∓5s so the timestamp follows the finger. A committed fling
  // (past the progress threshold) still changes tracks instead.
  double _scrubAccum = 0;
  // Position when the current art drag started: a cancelled drag at a
  // boundary (first/last song, nowhere to go) snaps back here so a
  // doomed swipe is a complete no-op instead of a stray few-seconds jump.
  Duration _scrubStartPos = Duration.zero;
  // Slider scrub position in ms while the finger is down. The thumb
  // follows the finger locally; the engine gets ONE seek on release.
  // Firing qp.seek per onChanged tick floods the audio engine and
  // hangs the app on slow drags.
  double? _scrubMs;
  // Last committed seek target: after release the engine needs a moment
  // to get there, so keep showing the target (instead of flashing back
  // to the old position) until playback catches up or 3s pass.
  int? _seekTargetMs;
  int _seekAtMs = 0;

  /// Position to DISPLAY: the seek target while the engine is still
  /// catching up, else the real engine position.
  int _shownMs(int posMs) {
    final t = _seekTargetMs;
    if (t == null) return posMs;
    // Hold the target while the engine is more than 2s away on EITHER
    // side (forward seeks lag below it, backward seeks linger above
    // it) — otherwise the readout flashes old -> new -> settled.
    final far = (posMs < t - 2000) || (posMs > t + 2000);
    if (DateTime.now().millisecondsSinceEpoch - _seekAtMs > 3000 || !far) {
      _seekTargetMs = null;
      return posMs;
    }
    return t;
  }

  /// Record a committed seek (scrub release / wave release / tap).
  void _commitSeek(int ms) {
    _seekTargetMs = ms;
    _seekAtMs = DateTime.now().millisecondsSinceEpoch;
    qp.seek(Duration(milliseconds: ms));
  }

  // Whole-screen vertical swipe state: swipe up opens the queue, swipe down
  // dismisses back to the previous page.
  bool _queueOpen = false;
  bool _queueFull = false;
  bool _queueDragging = false;
  double _queueDrag = 0; // >0 = sheet pulled down below its target
  // Mid↔full size tween: flipping _queueFull changes the height target
  // instantly, so a dedicated controller eases the rendered height instead.
  late final AnimationController _queueSizeCtrl;
  double _queueSizeFrom = 0;
  double _queueSizeTo = 0;
  bool _queueSizeAnimating = false;
  double _vertStartY = 0;

  /// Share links resolved in the background per song title, so tapping the
  /// share button opens the chooser instantly instead of waiting on the
  /// network resolve of the YouTube video id.
  final Map<String, ({String ytLink, String spLink, String subject})>
      _shareCache = {};

  @override
  void initState() {
    super.initState();
    _artController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _closeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 190),
    );
    _queueCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _queueSizeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _queueSizeCtrl.addStatusListener((s) {
      if (!mounted) return;
      if (s == AnimationStatus.completed && _queueSizeAnimating) {
        setState(() => _queueSizeAnimating = false);
      }
    });
    qp.currentTitle.addListener(_prewarmShare);
    _prewarmShare();
  }

  @override
  void dispose() {
    qp.currentTitle.removeListener(_prewarmShare);
    _artController.dispose();
    _closeCtrl.dispose();
    _queueCtrl.dispose();
    _queueSizeCtrl.dispose();
    super.dispose();
  }

  bool _artCanGo() {
    if (_artDir == 0) return false;
    if (_artDir == 1) return qp.hasNext;
    return qp.hasPrev;
  }

  /// Drag-driven art carousel: the incoming cover slides in as you drag and
  /// settles into the full (slow or fast) transition. Vertical swipes are
  /// handled at the whole-screen level (up = queue, down = dismiss).
  Widget _buildArtArea() {
    final area = SizedBox(
      width: 320,
      height: 320,
      child: ValueListenableBuilder<String>(
        valueListenable: qp.currentTitle,
        builder: (_, __, ___) => ValueListenableBuilder<String>(
          valueListenable: qp.currentThumb,
          builder: (_, ___, ____) => AnimatedBuilder(
            animation: _artController,
            builder: (_, __) {
              final p = _artController.value;
              final t = qp.currentTitle.value;
              final tb = qp.currentThumb.value;
              final idx = qp.index;
              final cur = Hero(
                tag: kPlayerArtHeroTag,
                createRectTween: (begin, end) =>
                    MaterialRectCenterArcTween(begin: begin, end: end),
                child: Container(
                  width: 300,
                  height: 300,
                  child: CoverArt(
                    seed: t,
                    icon: Icons.music_note,
                    networkUrl: tb.isEmpty ? null : tb,
                    size: 300,
                  ),
                ),
              );
              final signed = _artDir * p;
              if (p > 0) {
                final incoming = _artDir > 0 && qp.hasNext
                    ? qp.items[idx + 1]
                    : (_artDir < 0 && qp.hasPrev ? qp.items[idx - 1] : null);
                if (incoming != null) {
                  return Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Transform.translate(
                        offset: Offset(-60 * signed, 0),
                        child: Transform.scale(scale: 1 - 0.05 * p, child: cur),
                      ),
                      Transform.translate(
                        offset: Offset(_artDir * 320 * (1 - p), 0),
                        child: Transform.scale(
                          scale: 1 - 0.06 * (1 - p),
                          child: Opacity(
                            opacity: p.clamp(0.0, 1.0),
                            child: Container(
                              width: 300,
                              height: 300,
                              child: CoverArt(
                                seed: incoming.title,
                                icon: Icons.music_note,
                                networkUrl: (incoming.thumbUrl ?? '').isEmpty
                                    ? null
                                    : incoming.thumbUrl,
                                size: 300,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }
              }
              return Transform.translate(
                offset: Offset(-60 * signed, 0),
                child: Transform.scale(scale: 1 - 0.05 * p, child: cur),
              );
            },
          ),
        ),
      ),
    );
    if (_edit) return area;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) {
        _scrubAccum = 0;
        _scrubStartPos = qp.position.value;
      },
      onHorizontalDragUpdate: (d) {
        if (_artAnim) return;
        final dx = d.primaryDelta ?? d.delta.dx;
        // Dead end (first song dragging prev-wards, last song dragging
        // next-wards): fully inert — not even scrub — so a doomed swipe
        // can never blip the audio.
        if ((dx > 0 && !qp.hasPrev) || (dx < 0 && !qp.hasNext)) return;
        // Slow-drag scrub: timestamp follows the finger (drag left =
        // forward, drag right = back). Stepped to avoid flooding seeks.
        _scrubAccum += dx;
        final dur = qp.trackDuration.value;
        if (dur > Duration.zero) {
          while (_scrubAccum <= -60) {
            _scrubAccum += 60;
            final t = qp.position.value + const Duration(seconds: 5);
            qp.seek(t > dur ? dur : t);
          }
          while (_scrubAccum >= 60) {
            _scrubAccum -= 60;
            final t = qp.position.value - const Duration(seconds: 5);
            qp.seek(t < Duration.zero ? Duration.zero : t);
          }
        }
        setState(() {
          _dragX += dx;
          // Hysteresis: only flip the slide direction after the drag has
          // crossed 8px past the current direction's boundary, so slow
          // back-and-forth swipes no longer flicker between next/previous.
          final wantNext = _dragX < 0;
          if ((wantNext && _artDir != 1 && _dragX < -8) ||
              (!wantNext && _artDir != -1 && _dragX > 8)) {
            _artDir = wantNext ? 1 : -1;
          }
          _artController.value = (_dragX.abs() / 150).clamp(0.0, 1.0);
        });
      },
      onHorizontalDragEnd: (d) {
        if (_artAnim) return;
        final v = d.primaryVelocity ?? 0;
        final p = _artController.value;
        final fling = (_artDir == 1 && v < -280) || (_artDir == -1 && v > 280);
        final go = _artCanGo() && (p > 0.32 || fling);
        _artAnim = true;
        if (go) {
          _artController.forward().whenComplete(() {
            if (!mounted) return;
            setState(() {
              if (_artDir == 1) {
                qp.next();
              } else {
                qp.previous(force: true);
              }
              _dragX = 0;
              _scrubAccum = 0;
              _artDir = 0;
              _artAnim = false;
              _artController.value = 0;
            });
          });
        } else {
          // Cancelled drag: mid-queue keeps the scrubbed position
          // (timestamp follows the finger); at a boundary there's nowhere
          // to go, so snap back — but only when the drift is audible
          // (>0.5s), otherwise the corrective seek itself blips.
          if (!_artCanGo() &&
              (qp.position.value - _scrubStartPos).abs() >
                  const Duration(milliseconds: 500)) {
            qp.seek(_scrubStartPos);
          }
          _scrubAccum = 0;
          _artController.reverse().whenComplete(() {
            if (!mounted) return;
            setState(() {
              _dragX = 0;
              _artDir = 0;
              _artAnim = false;
            });
          });
        }
      },
      child: area,
    );
  }

  // ---- In-screen queue overlay (no modal: swipes to/from the track page) ----

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = (d.inSeconds.remainder(60)).toString().padLeft(2, '0');
    return '$m:$s';
  }

  double get _queueHalfH => MediaQuery.of(context).size.height * 0.45;
  double get _queueFullH => MediaQuery.of(context).size.height * 0.92;
  double get _queueTargetH => _queueFull ? _queueFullH : _queueHalfH;

  void _openQueue() {
    if (_queueOpen) return;
    setState(() {
      _queueOpen = true;
      _queueFull = false;
      _queueDragging = false;
      _queueDrag = 0;
    });
    _queueCtrl.forward();
  }

  void _closeQueue() {
    _queueSizeCtrl.stop();
    _queueSizeAnimating = false;
    _queueCtrl.reverse().whenComplete(() {
      if (!mounted) return;
      setState(() {
        _queueOpen = false;
        _queueFull = false;
        _queueDragging = false;
        _queueDrag = 0;
      });
    });
  }

  void _queueDragStart(DragStartDetails d) {
    // A fresh grab cancels any in-flight mid↔full size tween; the finger wins.
    if (_queueSizeAnimating) {
      _queueSizeCtrl.stop();
      _queueSizeAnimating = false;
    }
    setState(() => _queueDragging = true);
  }

  /// Tween the rendered sheet height (mid 45% ↔ full 92%) over ~280ms.
  void _animateQueueSize(double from, double to) {
    _queueSizeFrom = from;
    _queueSizeTo = to;
    _queueSizeAnimating = true;
    _queueSizeCtrl.forward(from: 0);
  }

  void _queueDragUpdate(DragUpdateDetails d) {
    setState(() => _queueDrag += d.delta.dy);
  }

  void _queueDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    // Height currently on screen (the finger may have pulled it partway up),
    // so the grow tween starts seamlessly instead of jumping.
    final releaseH =
        (_queueTargetH - _queueDrag.clamp(-_queueFullH, _queueFullH))
            .clamp(96.0, _queueFullH);
    setState(() {
      _queueDragging = false;
      if (v < -350 || (_queueDrag < 0 && _queueDrag < -40)) {
        // Strong swipe up → ease up to full height.
        _queueFull = true;
        _animateQueueSize(releaseH, _queueFullH);
      } else if (v > 350 || _queueDrag > 80) {
        // Swipe down (from medium or full) → fully close, never to medium.
        _queueSizeCtrl.stop();
        _queueSizeAnimating = false;
        _queueOpen = false;
        _queueDragging = true;
        _queueCtrl.reverse().whenComplete(() {
          if (!mounted) return;
          setState(() {
            _queueOpen = false;
            _queueFull = false;
            _queueDragging = false;
            _queueDrag = 0;
          });
        });
        return;
      } else {
        // No clear intent: if it was full and drifted down a bit, ease back.
        if (_queueFull && _queueDrag > 0 && _queueDrag < 80) {
          _animateQueueSize(releaseH, _queueFullH);
        }
      }
      _queueDrag = 0;
    });
  }

  Widget _buildQueueOverlay() {
    return AnimatedBuilder(
      animation: Listenable.merge([_queueCtrl, _queueSizeCtrl]),
      builder: (_, __) {
        if (_queueCtrl.status == AnimationStatus.dismissed && !_queueOpen) {
          return const SizedBox.shrink();
        }
        // Mid↔full grows ease via the size tween instead of jumping targets.
        final h = _queueSizeAnimating
            ? _queueSizeFrom +
                (_queueSizeTo - _queueSizeFrom) *
                    Curves.easeOutCubic.transform(
                        _queueSizeCtrl.value.clamp(0.0, 1.0))
            : _queueTargetH;
        final hidden = 1 - _queueCtrl.value;
        final dragRemainder = _queueDragging
            ? _queueDrag.clamp(-_queueFullH, _queueFullH)
            : 0.0;
        // While dragging, the sheet visually follows the finger: height is
        // the target minus how far down you've pulled (up-grow / down-shrink).
        final dragHeight = _queueDragging
            ? (_queueTargetH - dragRemainder).clamp(96.0, _queueFullH)
            : h;
        return Stack(
          children: [
            // Scrim above the sheet — tapping or swiping down anywhere outside
            // the queue box closes it. Always full-size so the sheet's own
            // header zone (which handles the down-close drags) is separate.
            Positioned.fill(
              child: GestureDetector(
                onTap: _closeQueue,
onVerticalDragStart: _queueDragging ? null : _queueDragStart,
                onVerticalDragUpdate: _queueDragUpdate,
                onVerticalDragEnd: _queueDragEnd,
                onVerticalDragCancel: () =>
                    setState(() => _queueDragging = false),
                child: Container(
                  color: Colors.black.withValues(alpha: .45 * _queueCtrl.value),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Transform.translate(
                offset: Offset(0, hidden * h + dragRemainder.clamp(0, h)),
                child: _QueueSheet(
                  qp: qp,
                  heightPx: dragHeight,
                  onVerticalDragStart:
                      _queueDragging ? null : _queueDragStart,
                  onVerticalDragUpdate: _queueDragUpdate,
                  onVerticalDragEnd: _queueDragEnd,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // Whole-screen vertical swipes: up opens the queue, down dismisses the page
  // (the page dissolves downward through the route's reverse transition).
  Widget _buildScreen(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: _edit
          ? null
          : (d) => _vertStartY = d.globalPosition.dy,
      onVerticalDragUpdate: _edit
          ? null
          : (d) {
              final dy = d.globalPosition.dy - _vertStartY;
              setState(() {
                _closeCtrl.stop();
                _closeCtrl.value = (dy / 400).clamp(0.0, 1.0);
              });
            },
      onVerticalDragEnd: _edit
          ? null
          : (d) {
              final v = d.primaryVelocity ?? 0;
              // The art + title zone occupies the upper ~72% of the screen.
              // Only an up-swipe STARTED there opens the queue; up-swipes
              // originating lower (progress slider, transport buttons)
              // register as the Android gesture-nav "home" swipe and must
              // not be captured (otherwise swiping home pops the queue
              // sheet open as a side effect).
              final inArt =
                  _vertStartY < MediaQuery.sizeOf(context).height * 0.72;
              if (v < -350 && inArt) {
                // Swipe up on the art → queue.
                _closeCtrl.reverse();
                _openQueue();
              } else if (v > 300 || _closeCtrl.value > 0.5) {
                // Swipe down → back to the previous page.
                Navigator.of(context).pop();
              } else {
                _closeCtrl.reverse();
              }
            },
      onVerticalDragCancel: _edit ? null : () => _closeCtrl.reverse(),
      child: AnimatedBuilder(
        animation: _closeCtrl,
        builder: (_, child) => Opacity(
          opacity: (1 - _closeCtrl.value * .3).clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, _closeCtrl.value * 70),
            child: child,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24)
                .copyWith(top: 8),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: tr('Minimize player'),
                      icon: const Icon(
                        Icons.keyboard_arrow_down,
                        size: 28,
                        color: Colors.white70,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Spacer(),
                  ],
                ),
                Expanded(child: Center(child: _buildArtArea())),
                const SizedBox(height: 16),
                IgnorePointer(
                  ignoring: _edit,
                  child: _MetaSection(api: ServerContext.of(context)),
                ),
                const SizedBox(height: 16),
                ValueListenableBuilder<Duration>(
                  valueListenable: qp.position,
                  builder: (_, pos, __) => ValueListenableBuilder<Duration>(
                    valueListenable: qp.trackDuration,
                    builder: (_, dur, ___) {
                      final liveMs = _shownMs(pos.inMilliseconds);
                      final progress = _scrubMs != null &&
                              dur > Duration.zero
                          // Scrubbing: pin the bar to the finger (same
                          // flash reason as the time label below).
                          ? (_scrubMs! / dur.inMilliseconds).clamp(0.0, 1.0)
                          : (dur > Duration.zero)
                              ? liveMs
                                    .clamp(0, dur.inMilliseconds)
                                    .toDouble() /
                                  dur.inMilliseconds
                              : 0.0;
                      // Progress style picks the Slider or SoundCloud-style
                      // waves (edit-layout setting, persisted in UiStore).
                      return ListenableBuilder(
                        listenable: UiStore.instance,
                        builder: (_, __) =>
                            UiStore.instance.progressStyle == 'waves'
                            ? _WaveSeekBar(
                                qp: qp,
                                edit: _edit,
                                fraction: progress.clamp(0.0, 1.0),
                                onSeek: (ms) => _commitSeek(ms),
                              )
                            : Slider(
                                value: (_shownMs(pos.inMilliseconds)
                                        .toDouble())
                                    .clamp(
                                        0.0,
                                        (dur > Duration.zero)
                                            ? dur.inMilliseconds.toDouble()
                                            : 1.0),
                                max: (dur > Duration.zero)
                                    ? dur.inMilliseconds.toDouble()
                                    : 1,
                                activeColor: Spots.green,
                                inactiveColor: Spots.subtle,
                                onChanged: _edit
                                    ? (_) {}
                                    : (v) => setState(
                                        () => _scrubMs = v),
                                onChangeEnd: (v) {
                                  final ms = v.round();
                                  setState(() => _scrubMs = null);
                                  _commitSeek(ms);
                                },
                              ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      ValueListenableBuilder<Duration>(
                        valueListenable: qp.position,
                        builder: (_, p, __) => Text(
                          // While scrubbing or waiting for a committed
                          // seek to land, show the target so the readout
                          // never flashes back to the old timestamp.
                          _fmt(Duration(
                              milliseconds:
                                  _shownMs(p.inMilliseconds))),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                      const Spacer(),
                      ValueListenableBuilder<Duration>(
                        valueListenable: qp.trackDuration,
                        builder: (_, d, __) => Text(
                          _fmt(d),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(width: 8),
                    ListenableBuilder(
                      listenable: UiStore.instance,
                      builder: (_, __) => _edit
                          ? DragTarget<String>(
                              onWillAcceptWithDetails: (_) => true,
                              onAcceptWithDetails: (d) => UiStore.instance
                                  .setTransportSlot(true, d.data),
                              builder: (_, candidate, ___) => Container(
                                decoration: candidate.isNotEmpty
                                    ? BoxDecoration(
                                        border: Border.all(
                                            color: Spots.green, width: 2),
                                        borderRadius:
                                            BorderRadius.circular(20),
                                      )
                                    : null,
                                child: _transportButton(
                                    UiStore.instance.transportLeft, _edit),
                              ),
                            )
                          : _transportButton(
                              UiStore.instance.transportLeft, _edit),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.skip_previous, size: 36),
                      onPressed: _edit ? _noop : qp.previous,
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
                                  strokeWidth: 3,
                                ),
                              ),
                            )
                            : StreamBuilder<PlayerState>(
                              stream: qp.stateStream,
                              initialData: qp.playing
                                  ? PlayerState.playing
                                  : PlayerState.paused,
                              builder: (_, snap) => ListenableBuilder(
                                listenable: qp.stateSyncing,
                                builder: (_, __) => IconButton(
                                  visualDensity: VisualDensity.compact,
                                  iconSize: 60,
                                  color: Colors.white,
                                  onPressed: (_edit || qp.stateSyncing.value)
                                      ? null
                                      : () => qp.resumeOrPause(),
                                  icon: Icon(
                                    snap.data == PlayerState.playing
                                        ? Icons.pause_circle_filled
                                        : Icons.play_circle_fill,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.skip_next, size: 36),
                      onPressed: _edit ? _noop : qp.next,
                    ),
                    ListenableBuilder(
                      listenable: UiStore.instance,
                      builder: (_, __) => _edit
                          ? DragTarget<String>(
                              onWillAcceptWithDetails: (_) => true,
                              onAcceptWithDetails: (d) => UiStore.instance
                                  .setTransportSlot(false, d.data),
                              builder: (_, candidate, ___) => Container(
                                decoration: candidate.isNotEmpty
                                    ? BoxDecoration(
                                        border: Border.all(
                                            color: Spots.green, width: 2),
                                        borderRadius:
                                            BorderRadius.circular(20),
                                      )
                                    : null,
                                child: _transportButton(
                                    UiStore.instance.transportRight, _edit),
                              ),
                            )
                          : _transportButton(
                              UiStore.instance.transportRight, _edit),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
                const SizedBox(height: 4),
                if (_edit)
                  _buildEditableRow()
                else
                  ListenableBuilder(
                    listenable: UiStore.instance,
                    builder: (context, _) => Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: _secondaryButtons(UiStore.instance.playerOrder),
                    ),
                  ),
                const SizedBox(height: 8),
                if (kIsWeb || defaultTargetPlatform != TargetPlatform.android)
                  Row(
                    children: [
                      const Icon(
                        Icons.volume_down,
                        size: 18,
                        color: Colors.white54,
                      ),
                      Expanded(
                        child: Slider(
                          value: _volume,
                          activeColor: Spots.green,
                          inactiveColor: Spots.subtle,
                          onChanged: _edit
                              ? (_) {}
                              : (v) {
                                  setState(() => _volume = v);
                                  qp.setVolume(v);
                                },
                        ),
                      ),
                      const Icon(
                        Icons.volume_up,
                        size: 18,
                        color: Colors.white54,
                      ),
                    ],
                  ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Secondary control buttons (queue / shuffle / repeat / autoplay / lyrics)
  /// in the order the user arranged.
  /// Editor row: the same five control buttons rendered as a horizontally
  /// draggable, live-reorderable copy. Buttons are inert (no onPressed) and
  /// each one is wrapped in [ReorderableDragStartListener], so you drag them
  /// directly (press + move) without a long-press or tooltip stealing the
  /// gesture.
  Widget _buildEditableRow() {
    final buttons = <String, Widget Function()>{
      'queue': _queueButtonInert,
      'share': _shareButtonInert,
      'shuffle': _shuffleButtonInert,
      'repeat': _repeatButtonInert,
      'autoplay': _autoplayButtonInert,
      'lyrics': _lyricsButtonInert,
    };
    return SizedBox(
      height: 56,
      child: ListenableBuilder(
        listenable: UiStore.instance,
        builder: (context, _) {
          final order = UiStore.instance.playerOrder;
          final fixed = {
            UiStore.instance.transportLeft,
            UiStore.instance.transportRight
          };
          final ids = List<String>.of(order.where((k) => !fixed.contains(k)))
            ..addAll(buttons.keys
                .where((k) => !order.contains(k) && !fixed.contains(k)));
          return ReorderableListView.builder(
            scrollDirection: Axis.horizontal,
            buildDefaultDragHandles: false,
            itemCount: ids.length,
            onReorderItem: (oldIndex, newIndex) {
              if (oldIndex == newIndex) return;
              final next = List<String>.of(order);
              final moved = next.removeAt(oldIndex);
              next.insert(newIndex, moved);
              UiStore.instance.setPlayerOrder(next);
            },
            proxyDecorator: (child, index, animation) => AnimatedBuilder(
              animation: animation,
              builder: (_, c) => Transform.scale(
                scale: 1 + 0.08 * animation.value,
                child: Material(color: Colors.transparent, child: c),
              ),
              child: child,
            ),
            itemBuilder: (_, i) {
              final id = ids[i];
              final btn = SizedBox(
                width: 56,
                child: Center(child: buttons[id]!()),
              );
              return ReorderableDragStartListener(
                key: ValueKey('np-edit-$id'),
                index: i,
                // Hold-and-move: quick press-move reorders the bottom row,
                // holding still lifts the button to drop on a flank slot.
                child: LongPressDraggable<String>(
                  data: id,
                  feedback: Material(
                    color: Colors.transparent,
                    child: btn,
                  ),
                  childWhenDragging: Opacity(opacity: .3, child: btn),
                  child: btn,
                ),
              );
            },
          );
        },
      ),
    );
  }

  // Inert twins of the real control buttons: identical look, identical
  // enabled/disabled state, but their action never fires in the editor.
  Widget _queueButtonInert() {
    return ValueListenableBuilder<int>(
      valueListenable: qp.queueLength,
      builder: (_, n, __) => IconButton(
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.queue_music),
        onPressed: n > 0 ? _noop : null,
      ),
    );
  }

  Widget _shuffleButtonInert() {
    return ValueListenableBuilder<bool>(
      valueListenable: qp.fromPlaylist,
      builder: (_, fromPl, __) => ValueListenableBuilder<bool>(
        valueListenable: qp.shuffleEnabled,
        builder: (_, sh, ___) => IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.shuffle, color: sh ? Spots.green : Colors.white54),
          onPressed: fromPl ? _noop : null,
        ),
      ),
    );
  }

  Widget _repeatButtonInert() {
    return ValueListenableBuilder<bool>(
      valueListenable: qp.repeatEnabled,
      builder: (_, rep, __) => IconButton(
        visualDensity: VisualDensity.compact,
        icon: Icon(Icons.repeat, color: rep ? Spots.green : Colors.white54),
        onPressed: _noop,
      ),
    );
  }

  Widget _autoplayButtonInert() {
    return ValueListenableBuilder<bool>(
      valueListenable: qp.autoplayEnabled,
      builder: (_, auto, __) => IconButton(
        visualDensity: VisualDensity.compact,
        style: auto
            ? ButtonStyle(
                backgroundColor: WidgetStateProperty.all(
                  Spots.green.withValues(alpha: .18),
                ),
              )
            : null,
        icon: Icon(
          Icons.all_inclusive,
          color: auto ? Spots.green : Colors.white54,
        ),
        onPressed: _noop,
      ),
    );
  }

  Widget _lyricsButtonInert() {
    return ValueListenableBuilder<String>(
      valueListenable: qp.currentTitle,
      builder: (_, t, __) => IconButton(
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.lyrics_outlined),
        onPressed: t.isEmpty ? null : _noop,
      ),
    );
  }

  Widget _shareButtonInert() {
    return ValueListenableBuilder<String>(
      valueListenable: qp.currentTitle,
      builder: (_, t, __) => IconButton(
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.share_outlined),
        onPressed: t.isEmpty ? null : _noop,
      ),
    );
  }

  /// No-op action so inert editor buttons look fully real (enabled) but never
  /// perform their action.
  void _noop() {}

  /// Transport flank slot (left of previous / right of next): any
  /// catalog button, live or inert depending on edit mode.
  Widget _transportButton(String id, bool inert) {
    switch (id) {
      case 'queue':
        return inert ? _queueButtonInert() : _queueButton();
      case 'share':
        return inert ? _shareButtonInert() : _shareButton();
      case 'repeat':
        return inert ? _repeatButtonInert() : _repeatButton();
      case 'autoplay':
        return inert ? _autoplayButtonInert() : _autoplayButton();
      case 'lyrics':
        return inert ? _lyricsButtonInert() : _lyricsButton();
      case 'shuffle':
      default:
        return inert ? _shuffleButtonInert() : _shuffleButton();
    }
  }

  List<Widget> _secondaryButtons(List<String> order) {
    final buttons = <String, Widget Function()>{
      'queue': _queueButton,
      'share': _shareButton,
      'shuffle': _shuffleButton,
      'repeat': _repeatButton,
      'autoplay': _autoplayButton,
      'lyrics': _lyricsButton,
    };
    // Slotted transport buttons leave the bottom row (even if an old
    // persisted order still lists them).
    final fixed = {
      UiStore.instance.transportLeft,
      UiStore.instance.transportRight
    };
    final ids = List<String>.of(order.where((k) => !fixed.contains(k)))
      ..addAll(buttons.keys
          .where((k) => !order.contains(k) && !fixed.contains(k)));
    return [
      for (final id in ids)
        if (buttons[id] != null) buttons[id]!(),
    ];
  }

  Widget _queueButton() {
    return ValueListenableBuilder<int>(
      valueListenable: qp.queueLength,
      builder: (_, n, __) => IconButton(
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.queue_music),
        tooltip: tr('Queue'),
        onPressed: n > 0 ? _openQueue : null,
      ),
    );
  }

  Widget _shuffleButton() {
    return ValueListenableBuilder<bool>(
      valueListenable: qp.fromPlaylist,
      builder: (_, fromPl, __) => ValueListenableBuilder<bool>(
        valueListenable: qp.shuffleEnabled,
        builder: (_, sh, ___) => IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.shuffle, color: sh ? Spots.green : Colors.white54),
          onPressed: fromPl ? qp.toggleShuffle : null,
          tooltip: fromPl
              ? tr('Shuffle playlist')
              : tr('Shuffle is for playlist playback'),
        ),
      ),
    );
  }

  Widget _repeatButton() {
    return ValueListenableBuilder<bool>(
      valueListenable: qp.repeatEnabled,
      builder: (_, rep, __) => IconButton(
        visualDensity: VisualDensity.compact,
        icon: Icon(Icons.repeat, color: rep ? Spots.green : Colors.white54),
        onPressed: qp.toggleRepeat,
      ),
    );
  }

  Widget _autoplayButton() {
    return ValueListenableBuilder<bool>(
      valueListenable: qp.autoplayEnabled,
      builder: (_, auto, __) => IconButton(
        visualDensity: VisualDensity.compact,
        style: auto
            ? ButtonStyle(
                backgroundColor: WidgetStateProperty.all(
                  Spots.green.withValues(alpha: .18),
                ),
              )
            : null,
        icon: Icon(
          Icons.all_inclusive,
          color: auto ? Spots.green : Colors.white54,
        ),
        onPressed: qp.toggleAutoplay,
        tooltip: auto ? tr('Infinite queue ON') : tr('Infinite queue OFF'),
      ),
    );
  }

  Widget _lyricsButton() {
    return ValueListenableBuilder<String>(
      valueListenable: qp.currentTitle,
      builder: (_, t, __) => IconButton(
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.lyrics_outlined),
        tooltip: tr('Lyrics'),
        onPressed: t.isEmpty ? null : () => showLyricsSheet(context),
      ),
    );
  }

  Widget _shareButton() {
    return ValueListenableBuilder<String>(
      valueListenable: qp.currentTitle,
      builder: (_, t, __) => IconButton(
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.share_outlined),
        tooltip: tr('Share to YouTube Music'),
        onPressed: t.isEmpty ? null : _shareCurrent,
      ),
    );
  }

  /// Resolve + cache the share payload for the song that just started playing,
  /// so the share tap opens the chooser IMMEDIATELY (the network resolve runs
  /// here in the background, not behind the button press).
  void _prewarmShare() {
    final cur = qp.current;
    if (cur == null || _shareCache.containsKey(cur.title)) return;
    _resolveShare(cur).then((p) {
      if (qp.current?.title == cur.title) _shareCache[cur.title] = p;
    }).catchError((_) {});
  }

  Future<({String ytLink, String spLink, String subject})> _resolveShare(
      QueueItem cur) async {
    var artist = cur.lyricsArtist ?? '';
    var title = cur.lyricsTitle ?? '';
    if (artist.isEmpty && title.isEmpty) {
      var parts = cur.title.split(' - ');
      if (parts.length >= 2) {
        artist = parts.removeAt(0).trim();
        title = parts.join(' - ').trim();
      } else {
        title = cur.title.trim();
      }
    }
    final a = artist.trim();
    final t = title.trim();
    // Both resolves are independent network calls — run them in PARALLEL so
    // the share sheet appears at the speed of the slowest one, not the sum
    // (previously resolveByName → spotifyLink ran one after the other, and a
    // slow Spotify match visibly delayed the whole share).
    final results = await Future.wait([
      _resolveYtShareLink(cur, a, t),
      _resolveSpotifyShareLink(a, t),
    ]);
    return (
      ytLink: results[0],
      spLink: results[1],
      subject: '$a - $t'.trim(),
    );
  }

  /// YouTube link: prefer the track's own resolved video id; only fall back to
  /// a server resolve per artist+title when it has none.
  Future<String> _resolveYtShareLink(QueueItem cur, String a, String t) async {
    var videoId = cur.videoId;
    if (videoId == null || videoId.isEmpty) {
      // NAS / unresolved internet play: resolve artist+title so the shared
      // link points at the actual video the player would stream — a search
      // link only ever resolves once opened, so it can't autoplay on its own.
      try {
        final r = await ServerContext.of(context)
            .resolveByName(artist: a, title: t);
        videoId = r.videoId;
      } catch (_) {
        // Offline / very obscure: accept a search link as the fallback.
        videoId = '';
      }
    }
    return videoId.isNotEmpty
        ? 'https://music.youtube.com/watch?v=$videoId'
        : 'https://music.youtube.com/search?q=${Uri.encodeQueryComponent('$a $t'.trim())}';
  }

  /// Spotify link: ask the server for the REAL track id so the shared link
  /// autoplays. The server returns its own search URL when it can't match
  /// confidently, so this never regresses to a worse link than before.
  Future<String> _resolveSpotifyShareLink(String a, String t) async {
    var spLink = '';
    if (t.isNotEmpty) {
      try {
        spLink = await ServerContext.of(context)
            .spotifyLink(artist: a, title: t);
      } catch (_) {}
    }
    return spLink.isNotEmpty
        ? spLink
        : 'https://open.spotify.com/search/${Uri.encodeQueryComponent('$a $t'.trim())}';
  }

  Future<void> _shareCurrent() async {
    final cur = qp.current;
    if (cur == null) return;
    // Open the target chooser FIRST — instant, no network work on the tap.
    final target = await showModalBottomSheet<_ShareTarget>(
      context: context,
      // Clip the Material to the rounded shape so the ListTile tap ripple /
      // highlight follows the rounded corners instead of bleeding out square
      // (the "pointy shadow" on click).
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: Text(tr('YouTube Music')),
              subtitle: Text(tr('Direct video link')),
              onTap: () => Navigator.pop(ctx, _ShareTarget.ytmusic),
            ),
            ListTile(
              leading: const Icon(Icons.headset),
              title: Text(tr('Spotify')),
              subtitle: Text(tr('Direct track link')),
              onTap: () => Navigator.pop(ctx, _ShareTarget.spotify),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(tr('Instagram')),
              subtitle: Text(tr('Story with artwork')),
              onTap: () => Navigator.pop(ctx, _ShareTarget.instagram),
            ),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;

    // Both targets come from ONE resolve: a song prewarms as soon as it starts
    // playing, so the tap is instant; only very-fast taps fall through.
    var p = _shareCache[cur.title];
    if (p == null) {
      p = await _resolveShare(cur);
      _shareCache[cur.title] = p;
    }
    if (!mounted) return;
    if (target == _ShareTarget.instagram) {
      // Tier 1 Stories (sticker + attribution) → tier 2 direct IG content
      // share (IG itself opens) → tier 3 generic sheet → clipboard. A user
      // cancel inside Instagram is unobservable (fire-and-forget composer).
      // Each failed tier logs its native diagnostic (exception +
      // resolveActivity + art exists/size + authority) to User errors so
      // one retest reveals the cause.
      final api = ServerContext.of(context);
      final story = await shareStoryDetailed(link: p.spLink);
      if (!story.ok) {
        unawaited(api.logClientError(
            'share-ig-story', '${cur.title} ${story.detail}'));
      }
      if (story.ok) return;
      final caption = storyCaption(p.subject, p.spLink);
      final direct = await shareDirectDetailed(text: caption);
      if (!direct.ok) {
        unawaited(api.logClientError(
            'share-ig-direct', '${cur.title} ${direct.detail}'));
      }
      if (instagramGenericNeeded(storyOk: story.ok, directOk: direct.ok)) {
        unawaited(api.logClientError('share-ig-fallback',
            '${cur.title} story=${story.detail} direct=${direct.detail}'));
        await _shipShare(context, link: caption, subject: p.subject);
      }
      return;
    }
    final link = target == _ShareTarget.spotify ? p.spLink : p.ytLink;
    await _shipShare(context, link: link, subject: p.subject);
  }

  Future<void> _shipShare(
    BuildContext context, {
    required String link,
    required String subject,
  }) async {
    try {
      const channel = MethodChannel('com.nasmusic.nasmusic/share');
      final sent = await channel.invokeMethod<Object>('shareText', {
        'text': link,
        'subject': subject,
      });
      if (shareTierOk(sent)) return;
      unawaited(ServerContext.of(context).logClientError(
          'share-sheet', '$subject sheet=${sent ?? 'null'}'));
    } catch (e) {
      // Desktop has no share sheet — fall through to the clipboard.
      unawaited(ServerContext.of(context)
          .logClientError('share-sheet', '$subject exception: $e'));
    }
    if (!context.mounted) return;
    await Clipboard.setData(ClipboardData(text: link));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Link copied to clipboard')),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Android back / back-gesture while the queue sheet is open must close
      // the queue first, never the whole full-screen player.
      canPop: !_queueOpen && !_queueFull,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_queueOpen || _queueFull) _closeQueue();
      },
      child: Scaffold(
        // Solid, opaque player background: the home screen must never bleed
        // through the full-screen controls (only the brief route scrim dims it
        // during the opening animation).
        backgroundColor: Spots.base,
        extendBodyBehindAppBar: true,
        body: Stack(children: [_buildScreen(context), _buildQueueOverlay()]),
      ),
    );
  }
}

/// Title + album + artist/group links + the Like heart, refreshed per song.
class _MetaSection extends StatefulWidget {
  const _MetaSection({required this.api});
  final ApiClient api;

  @override
  State<_MetaSection> createState() => _MetaSectionState();
}

class _MetaSectionState extends State<_MetaSection> {
  final qp = QueuePlayer.instance;
  MetaInfo? _meta;
  String _base = '';
  int _seq = 0;
  String? _itemAlbum;

  @override
  void initState() {
    super.initState();
    qp.currentTitle.addListener(_maybeRefresh);
    _maybeRefresh();
  }

  @override
  void didUpdateWidget(_MetaSection old) {
    super.didUpdateWidget(old);
    _maybeRefresh();
  }

  @override
  void dispose() {
    qp.currentTitle.removeListener(_maybeRefresh);
    super.dispose();
  }

  Future<void> _maybeRefresh() async {
    final base = qp.currentTitle.value;
    if (base.isEmpty) return;
    final cur = qp.current;
    // Internet/autoplay rows carry album + resolved identity directly on the
    // item; metainfo only covers library files. Fall back so the album still
    // shows on the Now Playing screen.
    if (cur != null) {
      _itemAlbum = cur.album;
    }
    final seq = ++_seq;
    if (base == _base && _meta != null) return;
    try {
      final m = await widget.api.metainfo(base);
      if (!mounted || seq != _seq) return;
      setState(() {
        _base = base;
        _meta = m;
      });
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _base = base;
        _meta = null;
      });
    }
  }

  void _artistsPopup(String artist) {
    final parts = _splitArtists(artist);
    if (parts.length <= 1) {
      final a = parts.isNotEmpty ? parts.first : artist;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ArtistScreen(api: widget.api, name: a),
        ),
      );
      return;
    }
    final photos = <String, String?>{};
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setPopup) {
          for (final a in parts) {
            if (!photos.containsKey(a)) {
              widget.api.artistPhoto(a).then((p) {
                if (ctx.mounted) {
                  setPopup(() => photos[a] = p);
                }
              });
            }
          }
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final a in parts)
                  ListTile(
                    leading: photos[a] != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              photos[a]!,
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  Icon(Icons.person, color: Spots.green),
                            ),
                          )
                        : Icon(Icons.person, color: Spots.green),
                    title: Text(
                      a,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: Colors.white38,
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              ArtistScreen(api: widget.api, name: a),
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Split a possibly-multi-artist string into individual artist names.
  static List<String> _splitArtists(String raw) {
    final parts = raw
        .split(
          RegExp(
            r'\s*(?:&|,|\+|/|feat(?:\.|uring)?|ft\.?|with|\bx\s*feat\b)\s*',
          ),
        )
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? [raw.trim()] : parts;
  }

  void _openAlbum() {
    var album = _meta?.album;
    var artist = _meta?.artist;
    if ((album == null || album.isEmpty) && (_itemAlbum?.isNotEmpty ?? false)) {
      // Internet/NAS rows carry the album directly; guess the artist from the
      // resolved identity or the 'Artist - Title' title.
      album = _itemAlbum;
      final cur = qp.current;
      final id =
          cur?.lyricsArtist ??
          (cur != null
              ? (cur.title.indexOf(' - ') > 0
                    ? cur.title.substring(0, cur.title.indexOf(' - ')).trim()
                    : '')
              : '');
      if (artist == null || artist.isEmpty) artist = id.isEmpty ? null : id;
    }
    if (album == null || album.isEmpty || artist == null || artist.isEmpty) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            AlbumScreen(api: widget.api, artist: artist!, album: album!),
      ),
    );
  }

  void _pickPlaylist(String t) {
    if (t.isEmpty) return;
    // The sheet returns the picked playlist name via pop; KeepPlaylistSheet
    // lets the user pick an existing playlist or create a fresh one.
    showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => const KeepPlaylistSheet(),
    ).then((name) async {
      if (name == null || name.isEmpty) return;
      try {
        await widget.api.addToPlaylist(baseName: t, playlist: name);
        if (mounted) {
          toast(context, "${tr('Added to')} $name", icon: Icons.playlist_add_check);
        }
      } catch (e) {
        if (mounted) toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
      }
    });
  }
  /// Download the current song to the phone. Lives in the title row,
  /// left of the heart (green mark on the mock).
  Widget _downloadButton() {
    return ValueListenableBuilder<String>(
      valueListenable: qp.currentTitle,
      builder: (_, t, __) => ValueListenableBuilder<int>(
        valueListenable: OfflineStore.change,
        builder: (_, ___, ____) {
          final done = t.isNotEmpty && OfflineStore.isDownloaded(t);
          return IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: done ? tr('On this phone') : tr('Download to phone'),
            icon: Icon(
              done ? Icons.download_done_outlined : Icons.download_outlined,
              color: done ? Spots.green : Colors.white54,
            ),
            onPressed: t.isEmpty ? null : () => _downloadCurrent(t),
          );
        },
      ),
    );
  }

  Future<void> _downloadCurrent(String base) async {
    if (OfflineStore.isDownloaded(base)) {
      toast(context, tr('Already on this phone'));
      return;
    }
    final url = qp.current?.url ?? '';
    if (url.isEmpty) {
      toast(context, tr('No file to download yet'),
          icon: Icons.error_outline);
      return;
    }
    final thumb = qp.current?.thumbUrl;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(child: Text("${tr('Downloading')} \"$base\"…")),
          ],
        ),
      ),
    );
    try {
      final pl = qp.fromPlaylist.value ? (qp.playlistName ?? '') : '';
      await OfflineStore.download(base: base, url: url, thumb: thumb, playlist: pl);
      if (mounted) {
        Navigator.pop(context);
        toast(context, tr('Saved to phone'), icon: Icons.check_circle);
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        toast(context, '$e', icon: Icons.error_outline);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = (_meta?.album?.isNotEmpty ?? false)
        ? _meta!.album
        : (_itemAlbum?.isNotEmpty ?? false)
        ? _itemAlbum
        : null;
    return ValueListenableBuilder<String>(
      valueListenable: qp.currentTitle,
      builder: (_, t, __) => ListenableBuilder(
        listenable: UiStore.instance,
        builder: (context, _) {
          final row = UiStore.instance.titleStyle == 'row';
          final title = _songTitle(t);
          const titleStyle = TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
          );
          return Column(
            crossAxisAlignment: row
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              if (!row) ...[
                // Title (song name only, centered) with the heart overlaid on
                // the right so the title stays perfectly centered despite the
                // button, and add-to-playlist on the left.
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 56),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        transitionBuilder: (child, anim) =>
                            FadeTransition(opacity: anim, child: child),
                        child: Text(
                          title,
                          key: ValueKey(t),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 4,
                      child: _LikeButton(api: widget.api, baseName: t),
                    ),
                    Positioned(
                      right: 48,
                      child: _downloadButton(),
                    ),
                    Positioned(
                      left: 4,
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: tr('Add to playlist'),
                        onPressed: () => _pickPlaylist(t),
                        icon: const Icon(
                          Icons.playlist_add,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                // Title left, wrapping onto a second line when long (no
                // scrolling marquee) with the like + add-to-playlist buttons
                // on the right.
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        key: ValueKey(t),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle,
                      ),
                    ),
                    _downloadButton(),
                    _LikeButton(api: widget.api, baseName: t),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                        tooltip: tr('Add to playlist'),
                      onPressed: () => _pickPlaylist(t),
                      icon: const Icon(
                        Icons.playlist_add,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ],
              if (album != null) const SizedBox(height: 4),
              if (album != null)
                Text(
                  album,
                  textAlign: row ? TextAlign.left : TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white70,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              const SizedBox(height: 10),
              // Artist + album side by side (red mark): each box caps at
              // half width but shrinks to its content when shorter —
              // a short artist or album leaves the rest left-aligned.
              LayoutBuilder(
                builder: (_, constraints) {
                  final hasArtist = _meta?.artist?.isNotEmpty ?? false;
                  final boxW = (constraints.maxWidth - 8) / 2;
                  // Both boxes shrink to content; the chips themselves
                  // already size to their text (Row mainAxisSize.min).
                  Widget artistBox(Widget child) => ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: boxW),
                        child: child,
                      );
                  Widget albumBox(Widget child) => ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: boxW),
                        child: child,
                      );
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      if (hasArtist)
                        artistBox(_chip(
                          Icons.person,
                          _meta!.artist!,
                          () => _artistsPopup(_meta!.artist!),
                        )),
                      if (hasArtist && album != null)
                        const SizedBox(width: 8),
                      if (album != null)
                        albumBox(_chip(
                          Icons.album_outlined,
                          album,
                          _openAlbum,
                        )),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  /// Song name only, stripping a leading "Artist - " part. Prefers the
  /// resolved/lyrics title when available.
  String _songTitle(String full) {
    final cur = qp.current;
    final lyr = cur?.lyricsTitle;
    if (lyr != null && lyr.isNotEmpty) return lyr;
    final i = full.indexOf(' - ');
    return i > 0 ? full.substring(i + 3).trim() : full;
  }

  Widget _chip(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool scroll = false,
  }) {
    final text = Text(
      label,
      maxLines: scroll ? 3 : 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Spots.elevated,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: Spots.green),
            const SizedBox(width: 6),
          Flexible(
            child: text,
          ),
          ],
        ),
      ),
    );
  }
}

/// SoundCloud-style waveform progress bar.
///
/// The "waves" come from a deterministic pseudo-random generator seeded by the
/// current song title, so each track shows a stable, unique wave shape (there
/// is no real audio analysis available client-side, but the seed keeps every
/// redraw of one song identical). The played portion is lit green; tapping or
/// dragging seeks. Inert in layout-edit mode.
class _WaveSeekBar extends StatefulWidget {
  const _WaveSeekBar({
    required this.qp,
    required this.edit,
    required this.fraction,
    this.onSeek,
  });

  final QueuePlayer qp;
  final bool edit;

  /// Played fraction 0..1.
  final double fraction;

  /// Fired instead of a direct engine seek so the parent can remember
  /// the target (anti-flash) before seeking.
  final void Function(int ms)? onSeek;

  @override
  State<_WaveSeekBar> createState() => _WaveSeekBarState();
}

class _WaveSeekBarState extends State<_WaveSeekBar> {
  // Drag-local fraction: the playhead follows the finger without
  // hammering the engine; one seek fires on release (same reason as
  // the Slider scrub fix — per-tick seeks hang the app).
  double? _dragF;

  QueuePlayer get qp => widget.qp;
  bool get edit => widget.edit;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: qp.currentTitle,
      builder: (_, title, __) => LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth > 0 ? constraints.maxWidth : 1.0;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: edit ? null : (d) => _seek(d.localPosition.dx / w),
            onHorizontalDragStart: edit
                ? null
                : (d) => setState(
                    () => _dragF = (d.localPosition.dx / w).clamp(0.0, 1.0)),
            onHorizontalDragUpdate: edit
                ? null
                : (d) => setState(
                    () => _dragF = (d.localPosition.dx / w).clamp(0.0, 1.0)),
            onHorizontalDragEnd: (_) {
              final f = _dragF;
              setState(() => _dragF = null);
              if (!edit && f != null) _seek(f);
            },
            onHorizontalDragCancel: () => setState(() => _dragF = null),
            child: SizedBox(
              width: double.infinity,
              height: 44,
              child: CustomPaint(
                painter: _WavePainter(
                  seed: title.isEmpty ? 0 : title.hashCode,
                  fraction: _dragF ?? widget.fraction,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _seek(double f) {
    final dur = qp.trackDuration.value;
    if (dur > Duration.zero) {
      final ms = (dur.inMilliseconds * f).round();
      final cb = widget.onSeek;
      if (cb != null) {
        cb(ms);
      } else {
        qp.seek(Duration(milliseconds: ms));
      }
    }
  }
}

/// Paints the deterministic SoundCloud-style waveform for [_WaveSeekBar].
/// The waveform is static; a moving playhead line shows progress.
class _WavePainter extends CustomPainter {
  const _WavePainter({required this.seed, required this.fraction});

  final int seed;
  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 3.0;
    const n = 45;
    final barW = (size.width - gap * (n - 1)) / n;
    if (barW <= 0) return;
    final rnd = math.Random(seed & 0x7fffffff);
    final bars = <_WaveBar>[];
    for (var i = 0; i < n; i++) {
      final noise = rnd.nextDouble();
      final env = math.sin(math.pi * (i + 0.5) / n);
      final h = (0.12 + 0.88 * noise * env) * size.height;
      final top = (size.height - h) / 2;
      final x = i * (barW + gap);
      bars.add(_WaveBar(x: x, top: top, width: barW, height: h));
    }
    // Draw unplayed portion (subtle)
    final subtlePaint = Paint()..color = Spots.subtle;
    for (final bar in bars) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(bar.x, bar.top, bar.width, bar.height),
          const Radius.circular(2),
        ),
        subtlePaint,
      );
    }
    // Draw played portion (green) up to the progress fraction
    final playedPaint = Paint()..color = Spots.green;
    final progressX = size.width * fraction;
    for (final bar in bars) {
      if (bar.x + bar.width <= progressX) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(bar.x, bar.top, bar.width, bar.height),
            const Radius.circular(2),
          ),
          playedPaint,
        );
      } else if (bar.x < progressX) {
        final playedWidth = progressX - bar.x;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(bar.x, bar.top, playedWidth, bar.height),
            const Radius.circular(2),
          ),
          playedPaint,
        );
      }
    }
    // Playhead dot.
    final circlePaint = Paint()..color = Spots.green;
    canvas.drawCircle(Offset(progressX, size.height / 2), 5, circlePaint);
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.seed != seed || old.fraction != fraction;
}

class _WaveBar {
  const _WaveBar({
    required this.x,
    required this.top,
    required this.width,
    required this.height,
  });
  final double x;
  final double top;
  final double width;
  final double height;
}

class _LikeButton extends StatefulWidget {
  const _LikeButton({required this.api, required this.baseName});
  final ApiClient api;
  final String baseName;

  @override
  State<_LikeButton> createState() => _LikeButtonState();
}

class _LikeButtonState extends State<_LikeButton> {
  bool? _liked;
  // Server `downloaded` flag = the shared NAS library copy (NOT the phone
  // download button next to the heart) — surfaced in the tooltip as such.
  bool _shared = false;
  bool _busy = false;
  int _seq = 0;

  @override
  void didUpdateWidget(_LikeButton old) {
    super.didUpdateWidget(old);
    if (old.baseName != widget.baseName) _load();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    // Await the current user's index BEFORE first paint: after a user
    // switch the in-memory rows still belong to the previous user until
    // reloadForUserSwitch lands. Keyed by baseName (never display title).
    await PrefetchStore.init();
    if (!mounted || seq != _seq) return;
    setState(() {
      _liked = PrefetchStore.likedFor(widget.baseName, widget.baseName);
      _busy = false;
    });
    if (widget.baseName.isEmpty) return;
    try {
      final st = await widget.api.likedStatus(widget.baseName);
      if (!mounted || seq != _seq) return;
      setState(() {
        _liked = st.liked;
        _shared = st.downloaded;
      });
      unawaited(
          PrefetchStore.setLiked(widget.baseName, st.liked, widget.baseName));
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() =>
          _liked = PrefetchStore.likedFor(widget.baseName, widget.baseName) ??
              false);
    }
  }

  Future<void> _toggle() async {
    if (_busy || widget.baseName.isEmpty) return;
    setState(() => _busy = true);
    try {
      if (_liked == true) {
        await widget.api.removeFromPlaylist('Liked', baseName: widget.baseName);
        unawaited(
            PrefetchStore.setLiked(widget.baseName, false, widget.baseName));
        if (mounted) {
          setState(() => _liked = false);
          toast(
            context,
            tr('Removed from Liked songs'),
            icon: Icons.favorite_border,
          );
        }
      } else {
        await widget.api.addToPlaylist(
          baseName: widget.baseName,
          playlist: 'Liked',
        );
        unawaited(
            PrefetchStore.setLiked(widget.baseName, true, widget.baseName));
        if (mounted) {
          setState(() => _liked = true);
          toast(context, tr('Added to Liked songs'), icon: Icons.favorite);
        }
      }
    } catch (e) {
      if (mounted) {
        // Offline: persist the toggle locally so it survives + shows cached.
        final v = !(_liked == true);
        unawaited(PrefetchStore.setLiked(widget.baseName, v, widget.baseName));
        setState(() => _liked = v);
        toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final liked = _liked == true;
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: _shared
          ? "${tr('Like')} · ${tr('On the server (NAS)')}"
          : tr('Like'),
      onPressed: _busy ? null : _toggle,
      icon: Icon(
        liked ? Icons.favorite : Icons.favorite_border,
        color: liked ? Colors.redAccent : Colors.white54,
      ),
    );
  }
}

/// Queue panel drawn at [heightPx] inside the Now Playing screen. The height
/// and all drag behavior live in the parent (_NowPlayingScreenState): the
/// header zone reports vertical drags so the whole overlay (scrim + sheet)
/// moves as one. List scrolls normally and is inert against those swipes.
class _QueueSheet extends StatefulWidget {
  const _QueueSheet({
    required this.qp,
    required this.heightPx,
    this.onVerticalDragStart,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });
  final QueuePlayer qp;
  final double heightPx;
  final GestureDragStartCallback? onVerticalDragStart;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  @override
  State<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<_QueueSheet> {
  late final ScrollController _scroll;
  final Map<int, GlobalKey> _rowKeys = {};
  VoidCallback? _songListener;
  int _scrollRetries = 0;

  @override
  void initState() {
    super.initState();
    final tgt = widget.qp.index;
    final n = widget.qp.items.length;
    // Start scrolled so the current song is in the viewport the moment the
    // queue opens (rows are ~64px). The item is then built, _rowKeys[target]
    // is populated, and ensureVisible can anchor it at the top.
    final initialOffset =
        (n > 0 && tgt > 0) ? (tgt * 64.0).clamp(0.0, (n - 1) * 64.0) : 0.0;
    _scroll = ScrollController(initialScrollOffset: initialOffset);
    _registerSongListener();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPlaying());
    _scroll.addListener(_onScroll);
  }

  void _registerSongListener() {
    _songListener = () => _scrollToPlaying();
    // Scroll when the song changes (or the queue is opened), NOT on every
    // position tick — otherwise the list fights the finger while playing.
    widget.qp.currentTitle.addListener(_songListener!);
  }

  @override
  void didUpdateWidget(_QueueSheet old) {
    super.didUpdateWidget(old);
    if (old.qp != widget.qp) {
      old.qp.currentTitle.removeListener(_songListener!);
      _registerSongListener();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPlaying());
  }

  @override
  void dispose() {
    widget.qp.currentTitle.removeListener(_songListener!);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToPlaying() {
    if (!_scroll.hasClients) return;
    final target = widget.qp.index;
    final key = _rowKeys[target];
    final ctx = key?.currentContext;
    if (ctx == null) {
      // Item not yet in viewport — jump to an approximate scroll offset
      // so it enters the viewport (each queue row is ~64px). On the next
      // frame the item will be built and ensureVisible can fine-tune.
      if (_scrollRetries >= 4) return;
      _scrollRetries++;
      final est = (target * 64.0).clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.jumpTo(est);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPlaying());
      return;
    }
    _scrollRetries = 0;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      alignment: 0.0,
    );
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    if (p.maxScrollExtent > 0 && p.pixels > p.maxScrollExtent * 0.8) {
      widget.qp.addMore();
    }
  }

  /// Song name only, stripping a leading "Artist - " part.
  static String _songName(String full) {
    final i = full.indexOf(' - ');
    return i > 0 ? full.substring(i + 3).trim() : full;
  }

  /// Small secondary label for a queue row: the artist/group when known, the
  /// album, or "from internet" for online autoplay rows.
  static Widget? _queueSubtitle(QueueItem it) {
    final group = _splitArtistsFromTitle(it.title);
    if (group.isNotEmpty && group != _songName(it.title)) {
      return Text(
        group,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: Colors.white54),
      );
    }
    if (it.album?.isNotEmpty ?? false) {
      return Text(
        it.album!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: Colors.white54),
      );
    }
    if (it.fromInternet) {
      return Text(
        tr('from internet'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.blueAccent, fontSize: 12),
      );
    }
    return null;
  }

  /// The "Artist - Song" prefix before the separator, or empty when the
  /// string has no separator.
  static String _splitArtistsFromTitle(String full) {
    final i = full.indexOf(' - ');
    return i > 0 ? full.substring(0, i).trim() : '';
  }

  @override
  Widget build(BuildContext context) {
    final qp = widget.qp;
    return Container(
      height: widget.heightPx,
      decoration: BoxDecoration(
        color: Spots.elevated,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // HEADER ZONE: reparented drag — parent decides grow/shrink/close.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: widget.onVerticalDragStart,
              onVerticalDragUpdate: widget.onVerticalDragUpdate,
              onVerticalDragEnd: widget.onVerticalDragEnd,
              child: Container(
                width: double.infinity,
                color: Colors.transparent,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        // Drag handle as a vertical affordance
                        Container(
                          width: 4,
                          height: 24,
                          margin: const EdgeInsets.only(right: 10),
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        ValueListenableBuilder<int>(
                          valueListenable: qp.queueLength,
                          builder: (_, n, __) => Text(
                            "${tr('Up next')} ($n)",
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        await qp.addMore();
                        if (mounted) setState(() {});
                      },
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(tr('Add more')),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            // Track list — scrolls normally, never triggers fullscreen.
            // The list keeps its original engine order; jumping to a song
            // only scrolls it into view (songs above stay reachable).
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: qp.currentTitle,
                builder: (_, __, ___) => ValueListenableBuilder<int>(
                  valueListenable: qp.queueLength,
                  builder: (_, ___, ____) {
                    final all = qp.items;
                    final n = all.length;
                    return ReorderableListView.builder(
                      scrollController: _scroll,
                      buildDefaultDragHandles: false,
                      itemCount: n,
                      onReorderItem: (o, nn) {
                        if (qp.reorder(o, nn)) {
                          _rowKeys.clear();
                          if (mounted) setState(() {});
                        }
                      },
                      itemBuilder: (_, i) {
                        final it = all[i];
                        final active = i == qp.index;
                        _rowKeys[i] ??= GlobalKey();
                        // Stable per-instance keys (NOT index-based): deleting or
                        // moving one row must not rekey every row below it —
                        // that rebuilds the whole list mid-animation and the
                        // swipe stutters. QueueItem uses identity equality, so
                        // the key follows the song, not the slot.
                        return Column(
                          key: ValueKey(it),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Dismissible(
                              key: ValueKey(it),
                              direction: DismissDirection.horizontal,
                              // Snappy swipe feedback: slide-out and the
                              // post-delete collapse both well under defaults
                              // (200ms / 300ms).
                              movementDuration:
                                  const Duration(milliseconds: 120),
                              resizeDuration:
                                  const Duration(milliseconds: 150),
                              dismissThresholds: const {
                                DismissDirection.startToEnd: 0.22,
                                DismissDirection.endToStart: 0.22,
                              },
                              confirmDismiss: (d) async {
                                // Resolve by SONG IDENTITY, not build-time
                                // position: with two quick swipes the second
                                // row's index is stale (the first removal
                                // hasn't run yet) and position-based handling
                                // moved/removed the WRONG song.
                                final idx = qp.items.indexOf(it);
                                if (idx < 0 || idx == qp.index) return false;
                                if (d == DismissDirection.startToEnd) {
                                  setState(() {
                                    qp.moveToPlayNext(idx);
                                    _rowKeys.clear();
                                  });
                                  return false;
                                }
                                return true;
                              },
                              onDismissed: (d) {
                                if (d == DismissDirection.endToStart) {
                                  // Same identity rule: onDismissed runs AFTER
                                  // the slide-out animation, so the build
                                  // index may point at a different song now.
                                  final idx = qp.items.indexOf(it);
                                  if (idx < 0 || idx == qp.index) {
                                    if (mounted) setState(() {});
                                    return;
                                  }
                                  final removed = qp.items[idx];
                                  if (qp.removeFromQueue(idx)) {
                                    _rowKeys.clear();
                                    showUndoBar(
                                      context,
                                      "${tr('Removed')} \"${removed.title}\"",
                                      () {
                                        qp.insertAt(idx, removed);
                                        _rowKeys.clear();
                                        if (mounted) setState(() {});
                                      },
                                    );
                                  }
                                  if (mounted) setState(() {});
                                }
                              },
                              background: Container(
                                color: Spots.green,
                                alignment: Alignment.centerLeft,
                                padding: const EdgeInsets.only(left: 20),
                                child: Row(
                                  children: [
                                    Icon(Icons.skip_next, color: Colors.white),
                                    SizedBox(width: 8),
                                    Text(
                                      tr('PLAY NEXT'),
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              secondaryBackground: Container(
                                color: Colors.redAccent,
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 20),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Icon(Icons.delete, color: Colors.white),
                                    SizedBox(width: 8),
                                    Text(
                                      tr('REMOVE'),
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              child: ReorderableDelayedDragStartListener(
                                index: i,
                                child: ListTile(
                                  key: _rowKeys[i],
                                  dense: true,
                                  leading: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '${i + 1}',
                                        style: TextStyle(
                                          color: active
                                              ? Spots.green
                                              : Colors.white38,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      CoverThumb(
                                        title: it.title,
                                        thumbUrl: it.thumbUrl,
                                        size: 40,
                                      ),
                                    ],
                                  ),
                                  title: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (OfflineStore.isDownloaded(it.title))
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(right: 6),
                                          child: Icon(
                                            Icons.download_outlined,
                                            size: 15,
                                            color: Spots.green,
                                          ),
                                        ),
                                      Flexible(
                                        child: Text(
                                          _songName(it.title),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: active
                                                ? Spots.green
                                                : null,
                                            fontWeight: active
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  subtitle: _queueSubtitle(it),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (active)
                                        Icon(
                                          Icons.graphic_eq,
                                          color: Spots.green,
                                          size: 18,
                                        )
                                      else if (it.fromInternet)
                                        const Icon(
                                          Icons.public,
                                          color: Colors.blueAccent,
                                          size: 18,
                                        ),
                                      ReorderableDragStartListener(
                                        index: i,
                                        child: const Padding(
                                          padding: EdgeInsets.only(left: 6),
                                          child: Icon(
                                            Icons.drag_handle,
                                            color: Colors.white24,
                                            size: 18,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  enabled: !active,
                                  onTap: () {
                                    qp.jumpTo(i);
                                  },
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
