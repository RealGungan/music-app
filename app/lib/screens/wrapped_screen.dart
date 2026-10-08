import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api_client.dart';
import '../demo_wrapped.dart';
import '../diag_log.dart';
import '../lang.dart';
import '../offline_store.dart';
import '../play_log.dart';
import '../toast.dart';
import '../wrapped.dart';

/// Year-in-review stories, Spotify Wrapped pattern: full-screen gradient
/// slides, staggered entrances, count-ups, auto-advance with animated
/// progress, tap zones, share at the end. Eligibility mirrors Spotify
/// (30 streams >30s). Data starts accumulating on install — no backfill.
///
/// Deliberately breaks out of the app theme presets: Wrapped is an event,
/// not chrome — hardcoded vivid gradients like Spotify does.
class WrappedScreen extends StatefulWidget {
  const WrappedScreen({super.key, required this.api});

  /// Covers (top-song thumbs, artist photos) + image share need the server.
  final ApiClient api;

  @override
  State<WrappedScreen> createState() => _WrappedScreenState();
}

/// One slide background: vivid Spotify-style duotone gradient.
class _Palette {
  final Color from;
  final Color to;
  const _Palette(this.from, this.to);
}

const _palettes = <_Palette>[
  _Palette(Color(0xFF4A148C), Color(0xFFAD1457)), // minutes: purple-pink
  _Palette(Color(0xFF00695C), Color(0xFF0D47A1)), // songs: teal-blue
  _Palette(Color(0xFFB71C1C), Color(0xFFE65100)), // artists: crimson-orange
  _Palette(Color(0xFF1A237E), Color(0xFF0097A7)), // sprint: indigo-cyan
  _Palette(Color(0xFF311B92), Color(0xFF6A1B9A)), // biggest day: plum-violet
  _Palette(Color(0xFF1B5E20), Color(0xFF33691E)), // finale: wrapped green
];

/// Staggered rise-and-fade entrance. Stateless: replays whenever the slide
/// rebuilds with a new key (page change bumps the key).
class _Rise extends StatelessWidget {
  final int delayMs;
  final Widget child;
  const _Rise({required this.delayMs, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 450 + delayMs),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        final local =
            ((t * (450 + delayMs) - delayMs) / 450).clamp(0.0, 1.0);
        final e = Curves.easeOutCubic.transform(local);
        return Opacity(
          opacity: e,
          child: Transform.translate(
            offset: Offset(0, 36 * (1 - e)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// Thousands separators (12,400) so big counts stay readable mid-count.
String _sep(int v) {
  final s = '$v';
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// Animated integer count-up. Big targets get a longer run-up so the
/// digits don't blur past; the figure is scaled down to always fit.
class _CountUp extends StatelessWidget {
  final int target;
  final String Function(int) format;
  final TextStyle style;
  const _CountUp(
      {required this.target, required this.format, required this.style});

  @override
  Widget build(BuildContext context) {
    final ms = (900 + target).clamp(900, 2200);
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: TweenAnimationBuilder<int>(
        tween: IntTween(begin: 0, end: target),
        duration: Duration(milliseconds: ms),
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => Text(format(v),
            textAlign: TextAlign.center, style: style),
      ),
    );
  }
}

class _WrappedScreenState extends State<WrappedScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _dwell = Duration(seconds: 6);
  final _page = PageController();
  late final AnimationController _progress;
  List<PlayEvent> _events = [];
  bool _loading = true;
  bool _allTime = false;
  bool _demo = false;
  int _pageIdx = 0;

  /// Cover URLs by `song:<base>` / `artist:<name>` ('' = requested, waiting).
  final _covers = <String, String>{};

  /// One stable screenshot key per slide (independent from the entrance
  /// replay ValueKey on the stage container).
  final _shotKeys = List.generate(6, (_) => GlobalKey());

  /// True while capturing a slide: hides the per-slide share buttons so
  /// they don't appear in the shared image.
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _progress = AnimationController(vsync: this, duration: _dwell)
      ..addStatusListener((st) {
        if (st == AnimationStatus.completed) _advance();
      });
    PlayLog.load().then((evs) {
      if (mounted) {
        _events = evs;
        // Pre-resolve ALL row art from the offline cache BEFORE the first
        // paint: cached rows render instantly, only missing rows show the
        // disc placeholder while _fetchCovers resolves them (Future.wait).
        _primeCachedCovers();
        setState(() => _loading = false);
        _fetchCovers();
        _restartDwell();
      }
    });
  }

  /// Synchronous offline-cache prime for every row [WrappedStats] will
  /// render (top songs + top artists + per-month artists). No network, no
  /// setState — call before the first paint (and any stats change lands
  /// through [_fetchCovers], which skips keys already present here).
  void _primeCachedCovers() {
    final s = _stats;
    for (final t in s.topSongs) {
      final key = 'song:${t.name}';
      if (_covers.containsKey(key)) continue;
      final local = OfflineStore.playlistCoverFileFor('wrapped:$key');
      if (local != null) _covers[key] = 'file:$local';
    }
    for (final a in <String>{
      for (final x in s.topArtists) x.name,
      ...s.artistMonth.values,
    }) {
      final key = 'artist:$a';
      if (a.isEmpty || _covers.containsKey(key)) continue;
      final local = OfflineStore.playlistCoverFileFor('wrapped:$key');
      if (local != null) _covers[key] = 'file:$local';
    }
  }

  /// Fill [_covers] for the current stats: song ALBUM covers via the album
  /// lookup for the song's album (metainfo art, then the album page — the
  /// old resolveByName video thumb is only the last fallback), artist
  /// photos via the cheap cached endpoint. Offline-first: art prefetched
  /// on an earlier online open renders from the local file with no
  /// connection (rows show art, not discs). Parallel per row via
  /// Future.wait (GNR was fast only because its art was already cached);
  /// cached rows paint instantly, the rest keep the disc placeholder until
  /// loaded (never blank). Missing keys only. Every outcome is logged to
  /// the restart log (Settings > Diagnostics > share) so a stubborn grey
  /// disc can be traced to the exact failing request.
  Future<void> _fetchCovers() async {
    if (_loading) return;
    final s = _stats;
    // Offline-first: paint already-prefetched bytes synchronously first.
    final pendingSongs = <String>[];
    for (final t in s.topSongs) {
      final key = 'song:${t.name}';
      if (_covers.containsKey(key)) continue;
      final local = OfflineStore.playlistCoverFileFor('wrapped:$key');
      if (local != null) {
        _covers[key] = 'file:$local';
      } else {
        _covers[key] = '';
        pendingSongs.add(t.name);
      }
    }
    final artists = <String>{
      for (final a in s.topArtists) a.name,
      ...s.artistMonth.values,
    };
    final pendingArtists = <String>[];
    for (final a in artists) {
      final key = 'artist:$a';
      if (a.isEmpty || _covers.containsKey(key)) continue;
      final local = OfflineStore.playlistCoverFileFor('wrapped:$key');
      if (local != null) {
        _covers[key] = 'file:$local';
      } else {
        _covers[key] = '';
        pendingArtists.add(a);
      }
    }
    if (mounted && (pendingSongs.isNotEmpty || pendingArtists.isNotEmpty)) {
      setState(() {});
    }
    final want = pendingSongs.length + pendingArtists.length;
    if (want == 0) return;
    DiagLog.restart.log('wrapped covers: requested $want');
    var got = 0, failed = 0;
    void done(bool ok, String what, [String err = '']) {
      if (ok) {
        got++;
      } else {
        failed++;
        DiagLog.restart.log('wrapped cover FAIL $what: $err');
      }
      if (got + failed >= want) {
        DiagLog.restart
            .log('wrapped covers done: $got/$want ok, $failed failed');
      }
    }

    Future<void> oneSong(String base) async {
      final key = 'song:$base';
      final artist = WrappedStats.primaryArtist(base);
      final title = WrappedStats.songTitle(base);
      try {
        String u = '';
        try {
          final m = await widget.api.metainfo(base);
          final ai = m?.albumImage ?? '';
          if (ai.isNotEmpty) {
            u = widget.api.imageProxy(ai);
          } else if ((m?.album ?? '').isNotEmpty) {
            try {
              final pg = await widget.api.album(artist, m!.album!);
              if ((pg.image ?? '').isNotEmpty) {
                u = widget.api.imageProxy(pg.image!);
              }
            } catch (_) {}
          }
        } catch (e) {
          done(false, 'song $base metainfo', '${e.runtimeType} $e');
        }
        if (u.isEmpty) {
          try {
            final r = await widget.api
                .resolveByName(artist: artist, title: title);
            u = r.videoId.isNotEmpty
                ? widget.api.thumbUrl(r.videoId)
                : (r.thumb.isNotEmpty
                    ? widget.api.imageProxy(r.thumb)
                    : '');
          } catch (_) {}
        }
        // Online-only (non-NAS) tracks with no video thumb: fall back to
        // the artist photo so the row still shows art (cached below).
        if (u.isEmpty && artist.isNotEmpty) {
          try {
            final p = await widget.api.artistPhoto(artist);
            if (p != null && p.isNotEmpty) u = widget.api.imageProxy(p);
          } catch (_) {}
        }
        if (u.isEmpty) {
          if (mounted) setState(() => _covers.remove(key));
          done(false, 'song $base', 'empty url');
          return;
        }
        if (!mounted) return;
        setState(() => _covers[key] = u);
        done(true, '');
        unawaited(OfflineStore.cachePlaylistCover('wrapped:$key', u));
      } catch (e) {
        done(false, 'song $base', '${e.runtimeType} $e');
        if (mounted) setState(() => _covers.remove(key));
      }
    }

    Future<void> oneArtist(String a) async {
      final key = 'artist:$a';
      try {
        final p = await widget.api.artistPhoto(a);
        if (p != null && p.isNotEmpty) {
          if (!mounted) return;
          final u = widget.api.imageProxy(p);
          setState(() => _covers[key] = u);
          done(true, '');
          unawaited(OfflineStore.cachePlaylistCover('wrapped:$key', u));
        } else {
          if (mounted) setState(() => _covers.remove(key));
          done(false, 'artist $a', 'no photo');
        }
      } catch (e) {
        done(false, 'artist $a', '${e.runtimeType} $e');
        if (mounted) setState(() => _covers.remove(key));
      }
    }

    await Future.wait([
      for (final b in pendingSongs) oneSong(b),
      for (final a in pendingArtists) oneArtist(a),
    ]);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Self-heal: re-request covers that never landed (first-open
    // completions lost to an early exit now fill in on return).
    if (state == AppLifecycleState.resumed) _fetchCovers();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _progress.dispose();
    _page.dispose();
    super.dispose();
  }

  WrappedStats get _stats => WrappedStats.compute(
        _demo ? demoEvents() : _events,
        year: _allTime ? null : DateTime.now().year,
      );

  int get _pageCount => 6;

  void _restartDwell() {
    _progress.reset();
    if (_pageIdx < _pageCount - 1) _progress.forward();
  }

  void _advance() {
    if (_pageIdx < _pageCount - 1) {
      _page.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _go(int i) {
    final n = i.clamp(0, _pageCount - 1);
    if (n == _pageIdx) {
      _restartDwell();
      return;
    }
    _page.animateToPage(
      n,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  void _onTapUp(TapUpDetails d) {
    final w = MediaQuery.of(context).size.width;
    if (d.localPosition.dx < w * 0.3) {
      _go(_pageIdx - 1);
    } else if (_pageIdx < _pageCount - 1) {
      _go(_pageIdx + 1);
    } else {
      _restartDwell();
    }
  }

  String _fmtMins(int seconds) {
    final m = seconds ~/ 60;
    if (m < 60) return '$m';
    final h = m ~/ 60;
    if (h < 48) return '$h h ${m % 60}m';
    return (m / 1440).toStringAsFixed(1);
  }

  String _minsUnit(int seconds) {
    final m = seconds ~/ 60;
    if (m < 60) return m == 1 ? tr('minute of music') : tr('minutes of music');
    final h = m ~/ 60;
    if (h < 48) return tr('hours of music');
    return tr('days of music');
  }

  String _fmtDay(String? ymd) {
    if (ymd == null) return '—';
    final names = [
      '', tr('Jan'), tr('Feb'), tr('Mar'), tr('Apr'), tr('May'), tr('Jun'),
      tr('Jul'), tr('Aug'), tr('Sep'), tr('Oct'), tr('Nov'), tr('Dec')
    ];
    final p = ymd.split('-');
    if (p.length != 3) return ymd;
    final m = int.tryParse(p[1]) ?? 0;
    final d = int.tryParse(p[2]) ?? 0;
    if (m < 1 || m > 12 || d < 1) return ymd;
    return '${names[m]} $d';
  }

  String _shareText(WrappedStats s) {
    final b = StringBuffer();
    b.writeln(
        'My ${_allTime ? 'all-time' : DateTime.now().year} Wrapped (gungan.fm)');
    b.writeln('${_fmtMins(s.totalSeconds)} listened, '
        '${s.totalStreams} streams.');
    for (var i = 0; i < s.topSongs.length; i++) {
      final t = s.topSongs[i];
      b.writeln('${i + 1}. ${t.name} (${t.streams}x)');
    }
    if (s.topArtists.isNotEmpty) {
      b.writeln('Top artist: ${s.topArtists.first.name}');
    }
    return b.toString();
  }

  Future<void> _share(WrappedStats s) async {
    final ok = await DiagLog.shareText(_shareText(s), 'My Wrapped');
    if (!ok && mounted) {
      toast(context, tr('Wrapped copied'), icon: Icons.check_circle);
    }
  }

  /// Share slide [i] as a PNG card (Spotify pattern). The per-slide share
  /// buttons are the tab selector: whatever slide you're looking at is the
  /// one that gets shared. Falls back to the text share on any failure
  /// (e.g. desktop without an image-share target).
  Future<void> _shareSlide(int i) async {
    _progress.stop();
    setState(() => _capturing = true);
    try {
      await Future.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      final obj =
          _shotKeys[i].currentContext?.findRenderObject();
      if (obj is! RenderRepaintBoundary) {
        await _share(_stats);
        return;
      }
      final img = await obj.toImage(pixelRatio: 2.0);
      final data =
          await img.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        await _share(_stats);
        return;
      }
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/wrapped-$i.png');
      await f.writeAsBytes(data.buffer.asUint8List());
      await SharePlus.instance.share(ShareParams(
        files: [XFile(f.path)],
        text: _shareText(_stats),
        subject: 'My Wrapped',
      ));
    } catch (_) {
      if (mounted) await _share(_stats);
    } finally {
      if (mounted) {
        setState(() => _capturing = false);
        if (_pageIdx < _pageCount - 1) _progress.forward();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final s = _stats;
    if (s.totalStreams < 30 && !_demo) {
      return SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('🎧', style: TextStyle(fontSize: 56)),
                const SizedBox(height: 20),
                Text(
                  tr('Keep listening — your Wrapped unlocks at 30 streams ') +
                      '(${s.totalStreams}/30 ${tr('so far')}).',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _demo = true;
                      _pageIdx = 0;
                    });
                    _page.jumpToPage(0);
                    _fetchCovers();
                    _restartDwell();
                  },
                  icon: const Icon(Icons.science_outlined, size: 18),
                  label: Text(tr('Preview demo')),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('Back'),
                      style: TextStyle(color: Colors.white54)),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final year = DateTime.now().year;
    final slides = <Widget>[
      _statSlide(
        0,
        _allTime ? tr('ALL TIME') : '$year ${tr('IN MUSIC')}',
        _CountUp(
          target: s.totalSeconds ~/ 60,
          format: (v) => _sep(v),
          style: const TextStyle(
              fontSize: 84,
              fontWeight: FontWeight.w900,
              letterSpacing: -2,
              color: Colors.white,
              height: 1),
        ),
        '${_minsUnit(s.totalSeconds)}'
        '${_allTime ? tr(' of all time') : tr(' this year')}'
        ' · ${_fmtMins(s.totalSeconds)}',
      ),
      _rankSlide(1, tr('YOUR TOP SONGS'), [
        for (var i = 0; i < s.topSongs.length; i++)
          (
            title: WrappedStats.songTitle(s.topSongs[i].name),
            sub: '${WrappedStats.primaryArtist(s.topSongs[i].name)} · '
                '${s.topSongs[i].streams} ${tr('plays')} · '
                '${s.topSongs[i].seconds ~/ 60} ${tr(s.topSongs[i].seconds ~/ 60 == 1 ? 'minute' : 'minutes')}',
            image: _coverOf('song', s.topSongs[i].name),
          )
      ]),
      _rankSlide(2, tr('YOUR TOP ARTISTS'), [
        for (var i = 0; i < s.topArtists.length; i++)
          (
            title: s.topArtists[i].name,
            sub: '${s.topArtists[i].streams} ${tr('plays')} · '
                '${s.topArtists[i].seconds ~/ 60} ${tr(s.topArtists[i].seconds ~/ 60 == 1 ? 'minute' : 'minutes')}',
            image: _coverOf('artist', s.topArtists[i].name),
          )
      ], circular: false),
      _rankSlide(
        3,
        tr('ARTIST SPRINT'),
        s.artistMonth.isEmpty
            ? [
                (
                  title: tr('Listen across months'),
                  sub: tr('to unlock the sprint'),
                  image: null,
                )
              ]
            : [
                for (final m in s.artistMonth.keys)
                  (
                    title: s.artistMonth[m]!,
                    sub: '${_monthName(m)} · '
                        '${(s.artistMonthSecs[m] ?? 0) ~/ 60} '
                        '${tr((s.artistMonthSecs[m] ?? 0) ~/ 60 == 1 ? 'minute' : 'minutes')}',
                    image: _coverOf('artist', s.artistMonth[m]!),
                  )
              ],
      ),
      _statSlide(
        4,
        tr('BIGGEST DAY'),
        _Rise(
          delayMs: 120,
          child: Text(
            _fmtDay(s.biggestDay),
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 72,
                fontWeight: FontWeight.w900,
                letterSpacing: -2,
                color: Colors.white,
                height: 1),
          ),
        ),
        s.biggestDay == null
            ? 'no standout day yet'
            : '${_fmtMins(s.biggestDaySeconds)} minutes of music',
      ),
      _finaleSlide(s),
    ];
    return Stack(
      children: [
        GestureDetector(
          onTapUp: _onTapUp,
          onLongPressStart: (_) => _progress.stop(),
          onLongPressEnd: (_) {
            if (_pageIdx < _pageCount - 1) _progress.forward();
          },
          child: PageView(
            controller: _page,
            onPageChanged: (i) {
              setState(() => _pageIdx = i);
              _restartDwell();
            },
            children: slides,
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    for (var i = 0; i < _pageCount; i++)
                      Expanded(
                        child: Container(
                          height: 3,
                          margin:
                              const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2),
                            color: Colors.white24,
                          ),
                          child: i < _pageIdx
                              ? Container(
                                  decoration: BoxDecoration(
                                    borderRadius:
                                        BorderRadius.circular(2),
                                    color: Colors.white,
                                  ),
                                )
                              : i == _pageIdx
                                  ? AnimatedBuilder(
                                      animation: _progress,
                                      builder: (context, _) =>
                                          FractionallySizedBox(
                                        alignment: Alignment.centerLeft,
                                        widthFactor: _progress.value,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(
                                                    2),
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () {
                        _page.jumpToPage(0);
                        setState(() {
                          _allTime = !_allTime;
                          _pageIdx = 0;
                        });
                        _fetchCovers();
                        _restartDwell();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: Colors.white24,
                        ),
                        child: Text(
                          _allTime ? tr('ALL TIME') : '$year ▾',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                              color: Colors.white),
                        ),
                      ),
                    ),
                    if (_demo)
                      GestureDetector(
                        onTap: () {
                          setState(() => _demo = false);
                          _fetchCovers();
                          _restartDwell();
                        },
                        child: Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.circular(20),
                            border: Border.all(
                                color: Colors.orangeAccent),
                          ),
                          child: Text(tr('My real Wrapped'),
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.orangeAccent)),
                        ),
                      ),
                    if (!_demo)
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _demo = true;
                            _pageIdx = 0;
                          });
                          _page.jumpToPage(0);
                          _fetchCovers();
                          _restartDwell();
                        },
                        child: Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.circular(20),
                            border: Border.all(
                                color: Colors.white54),
                          ),
                          child: Text(tr('Preview demo'),
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white70)),
                        ),
                      ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close,
                          color: Colors.white),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Gradient stage with decorative translucent discs. Wrapped in a
  /// stable RepaintBoundary so _shareSlide can capture this exact slide.
  /// The per-slide share button (hidden while capturing) is the tab
  /// selector: the slide you're looking at is the one that gets shared.
  Widget _stage(int idx, Widget content) {
    final p = _palettes[idx % _palettes.length];
    return RepaintBoundary(
      key: _shotKeys[idx],
      child: Container(
        key: ValueKey('slide$idx-$_pageIdx'),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [p.from, p.to],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -90,
              right: -70,
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:
                      Colors.white.withValues(alpha: 0.10),
                ),
              ),
            ),
            Positioned(
              bottom: -110,
              left: -80,
              child: Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:
                      Colors.black.withValues(alpha: 0.18),
                ),
              ),
            ),
            SafeArea(child: content),
            if (!_capturing)
              Positioned(
                right: 16,
                bottom: 24,
                child: _slideShareButton(idx),
              ),
          ],
        ),
      ),
    );
  }

  Widget _slideShareButton(int idx) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _shareSlide(idx),
          borderRadius: BorderRadius.circular(24),
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.22),
            ),
            child: const Icon(Icons.share_outlined,
                color: Colors.white, size: 22),
          ),
        ),
      );

  static const _label = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w800,
      letterSpacing: 3,
      color: Colors.white70);
  static const _sub = TextStyle(fontSize: 16, color: Colors.white);

  /// Big-number slide: kicker + animated figure + caption.
  Widget _statSlide(
      int idx, String kicker, Widget figure, String caption) {
    return _stage(
      idx,
      Padding(
        padding: const EdgeInsets.fromLTRB(28, 72, 28, 48),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Rise(delayMs: 0, child: Text(kicker, style: _label)),
            const SizedBox(height: 16),
            figure,
            const SizedBox(height: 12),
            _Rise(
                delayMs: 200,
                child: Text(caption,
                    textAlign: TextAlign.center, style: _sub)),
          ],
        ),
      ),
    );
  }

  /// Ranked-list slide with staggered rows, oversized rank numerals and
  /// cover art (song thumbs square, artist photos round).
  Widget _rankSlide(int idx, String title,
      List<({String title, String sub, String? image})> rows,
      {bool circular = false}) {
    return _stage(
      idx,
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 72, 24, 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Rise(delayMs: 0, child: Text(title, style: _label)),
            const SizedBox(height: 18),
            for (var i = 0; i < rows.length; i++)
              _Rise(
                delayMs: 120 + i * 110,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _cover(rows[i].image,
                          circular: circular),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 34,
                        child: Text('${i + 1}',
                            style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                color: Colors.white
                                    .withValues(alpha: 0.45),
                                height: 1)),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(rows[i].title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white)),
                            const SizedBox(height: 2),
                            Text(rows[i].sub,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13,
                                    color: Colors.white70)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String? _coverOf(String kind, String key) {
    final u = _covers['$kind:$key'];
    return (u != null && u.isNotEmpty) ? u : null;
  }

  /// Placeholder disc shown while a cover loads OR when it fails (layout
  /// never jumps; failed rows keep the disc instead of vanishing).
  Widget _disc() => Container(
        width: 52,
        height: 52,
        color: Colors.white.withValues(alpha: 0.18),
        child: const Icon(Icons.music_note_outlined,
            color: Colors.white70, size: 26),
      );

  /// Cover art for a rank row: the image when loaded, the disc while
  /// waiting or on failure. Songs square, artists round. `file:` URLs are
  /// prefetched bytes rendered offline (no connection needed).
  Widget _cover(String? url, {bool circular = false}) {
    Widget art;
    if (url != null && url.isNotEmpty) {
      if (url.startsWith('file:')) {
        art = Image.file(
          File(url.substring(5)),
          width: 52,
          height: 52,
          fit: BoxFit.cover,
          errorBuilder: (ctx, err, __) {
            DiagLog.restart.log(
                'wrapped image FAIL ${url.split('?').first} :: $err');
            return _disc();
          },
        );
      } else {
        art = Image.network(url,
            width: 52,
            height: 52,
            fit: BoxFit.cover,
            errorBuilder: (ctx, err, __) {
              DiagLog.restart.log(
                  'wrapped image FAIL ${url.split('?').first} :: $err');
              return _disc();
            });
      }
    } else {
      art = _disc();
    }
    if (circular) {
      return ClipOval(child: SizedBox(width: 52, height: 52, child: art));
    }
    return ClipRRect(
        borderRadius: BorderRadius.circular(10), child: art);
  }

  /// Finale: totals + white share pill, Spotify style.
  Widget _finaleSlide(WrappedStats s) {
    return _stage(
      5,
      Padding(
        padding: const EdgeInsets.fromLTRB(28, 72, 28, 48),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Rise(
                delayMs: 0,
                child: Text(
                    _allTime ? tr('ALL TIME') : '${DateTime.now().year}',
                    style: _label)),
            const SizedBox(height: 16),
            _CountUp(
              target: s.totalStreams,
              format: (v) => _sep(v),
              style: const TextStyle(
                  fontSize: 84,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -2,
                  color: Colors.white,
                  height: 1),
            ),
            const SizedBox(height: 12),
            _Rise(
              delayMs: 200,
              child: Text(
                "${tr('streams')} · ${s.distinctSongs} ${tr('songs')} · "
                '${s.distinctArtists} ${tr('artists')}',
                textAlign: TextAlign.center,
                style: _sub,
              ),
            ),
            const SizedBox(height: 36),
            _Rise(
              delayMs: 350,
              child: FilledButton.icon(
                // Shares THIS slide as an image card (Spotify pattern).
                onPressed: () => _shareSlide(5),
                icon: const Icon(Icons.share_outlined),
                label: Text(tr('Share my Wrapped'),
                    style: TextStyle(fontWeight: FontWeight.w800)),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 14),
                  textStyle: const TextStyle(fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _monthName(String ym) {
    final names = [
      '',
      tr('Jan'), tr('Feb'), tr('Mar'), tr('Apr'), tr('May'), tr('Jun'),
      tr('Jul'), tr('Aug'), tr('Sep'), tr('Oct'), tr('Nov'), tr('Dec')
    ];
    final parts = ym.split('-');
    if (parts.length != 2) return ym;
    final m = int.tryParse(parts[1]) ?? 0;
    return m >= 1 && m <= 12 ? '${names[m]} ${parts[0]}' : ym;
  }
}
