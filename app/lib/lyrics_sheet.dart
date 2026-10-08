import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'keep_dialog.dart';
import 'lang.dart';
import 'queue_player.dart';
import 'theme.dart';
import 'toast.dart';

/// Lyrics point size that fits [lines] into a maxW x maxH box: full 28
/// down to a 14 floor. Measured with the real font (TextPainter, bold
/// 1.3 like the card) — no char-width guessing, so the size the gate
/// predicts is the size the card draws. The card renders unscaled
/// ([TextScaler.noScaling]); [textScale] is kept for callers that
/// measure scaled UI text. Pure, unit-tested.
double lyricFitSize(double maxW, double maxH, List<String> lines,
    {double textScale = 1.0}) {
  double totalFor(double s) {
    var h = 0.0;
    for (final l in lines) {
      h += lyricLineHeight(l, s, maxW, textScale: textScale) + 12;
    }
    return h;
  }

  var size = 28.0;
  while (size > 14 && totalFor(size) > maxH) {
    size -= 1;
  }
  return size;
}

/// Real height of one card line at [size] in [maxW]: bold 1.3, the exact
/// style the share card renders. Shared by the fitter and the fit gate
/// so selection allows precisely what the card can draw.
double lyricLineHeight(String line, double size, double maxW,
    {double textScale = 1.0}) {
  final tp = TextPainter(
    text: TextSpan(
        text: line,
        style: TextStyle(
            fontSize: size, height: 1.3, fontWeight: FontWeight.w700)),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.linear(textScale),
  )..layout(maxWidth: maxW <= 0 ? 1 : maxW);
  return tp.height;
}

/// Share-card geometry, shared by the fit gate ([lyricFitsCard]) and the
/// card render so the prediction can never drift from what is drawn.
/// Card = 9:16 capped at 68% of screen height (width-first, like
/// RenderAspectRatio); the text box is what remains after the fixed
/// chrome: outer padding + card padding + cover-art header row + gaps.
const lyricCardOuterV = 90.0; // gradient padding, per side (default look)
const lyricCardInnerV = 26.0; // dark-card padding, per side
const lyricCardInnerH = 24.0; // all horizontal padding, per side (x4)
const lyricCardHeader = 64.0; // cover-art row height
const lyricCardGaps = 46.0; // 26 below header + 20 below the text

/// Text box (w, h) the lyrics render into on a [screenW] x [screenH]
/// screen. Pure, unit-tested.
(double, double) lyricCardBox(double screenW, double screenH) {
  final cap = screenH * 0.68;
  var cardW = screenW;
  var cardH = cardW * 16 / 9;
  if (cardH > cap) {
    cardH = cap;
    cardW = cardH * 9 / 16;
  }
  return (
    cardW - lyricCardInnerH * 4,
    cardH -
        (lyricCardOuterV * 2 +
            lyricCardInnerV * 2 +
            lyricCardHeader +
            lyricCardGaps),
  );
}

/// Whether [lines] fit the share card: measured with the real font at
/// the 14sp capture floor (see [lyricLineHeight]) inside the exact box
/// the card draws into ([lyricCardBox]). The gate allows precisely what
/// the renderer can draw — no estimation either way.
/// [textScale] is the system font scale. Pure, unit-tested.
bool lyricFitsCard(double screenW, double screenH, List<String> lines,
    {double textScale = 1.0}) {
  if (lines.isEmpty) return true;
  final (availW, availH) = lyricCardBox(screenW, screenH);
  if (availW <= 0 || availH <= 0) return false;
  var h = 0.0;
  for (final l in lines) {
    h += lyricLineHeight(l, 14, availW, textScale: textScale) + 12;
  }
  return h <= availH;
}

/// Background pair + card color from per-pixel `[h, s, l]` rows (pure,
/// unit-tested). Percentage-based: every pixel votes (near-white/black
/// excluded from hue), low-saturation pixels vote as a neutral grey bucket
/// instead of being discarded — the three most frequent buckets paint
/// (gradient-top, gradient-bottom, card). Hybrid Theory's grey concrete
/// therefore yields a grey card, not a red one from its small red accent.
/// Dark pixels never force the card: the card is ALWAYS the third share
/// (falling back to the first), so dark art with a vivid accent gets a
/// dark-accent card, never a black one from pixels that carry no hue.
(Color, Color, Color) sampleCardColors(List<List<double>> hsl) {
  const buckets = 18;
  const span = 360.0 / buckets;
  final count = List.filled(buckets, 0);
  final satSum = List.filled(buckets, 0.0);
  var neutralCount = 0;
  var neutralSat = 0.0;
  for (final row in hsl) {
    var h = row[0], s = row[1], l = row[2];
    if (l > 0.92) continue; // near-white votes for nothing
    if (h.isNaN) h = 0;
    if (s.isNaN) s = 0;
    if (l.isNaN) continue;
    if (l < 0.08) continue; // near-black carries no hue: votes for nothing
    if (s < 0.15) {
      neutralCount++;
      neutralSat += s;
      continue;
    }
    final b = ((h / span).floor()).clamp(0, buckets - 1);
    count[b]++;
    satSum[b] += s;
  }
  double clampSat(double s) => s < 0.15 ? 0.15 : (s > 0.85 ? 0.85 : s);
  // Candidates ordered by pixel share (percentage), chromatic + neutral.
  final order = <int>[]; // 0..17 hue, 18 = neutral
  for (var b = 0; b < buckets; b++) {
    if (count[b] > 0) order.add(b);
  }
  if (neutralCount > 0) order.add(18);
  int share(int b) => b == 18 ? neutralCount : count[b];
  order.sort((a, b) => share(b).compareTo(share(a)));
  // No votable pixel at all: neutral charcoal, never a noise hue.
  if (order.isEmpty) {
    return (
      const Color(0xFF3C414C),
      const Color(0xFF26272E),
      const Color(0xFF17171B)
    );
  }
  // Display color for bucket [b] at lightness [l]: chromatic keeps its mean
  // saturation, neutral stays grey (fixed cool hue, capped saturation).
  Color paint(int b, double l) {
    if (b == 18) {
      final ns = (neutralSat / neutralCount).clamp(0.0, 0.12);
      return hslColor(220, ns, l);
    }
    return hslColor(
        b * span + span / 2, clampSat(satSum[b] / count[b]), l);
  }

  final a = paint(order[0], 0.38);
  final b = paint(order.length > 1 ? order[1] : order[0], 0.30);
  final card = paint(order.length > 2 ? order[2] : order[0], 0.16);
  return (a, b, card);
}

/// HSL → opaque [Color] (pure, shared by the sampler and its tests).
Color hslColor(double h, double s, double l) {
  final c = (1 - (2 * l - 1).abs()) * s;
  final x = c * (1 - (((h / 60) % 2) - 1).abs());
  final m = l - c / 2;
  double r = 0, g = 0, b = 0;
  if (h < 60) {
    r = c;
    g = x;
  } else if (h < 120) {
    r = x;
    g = c;
  } else if (h < 180) {
    g = c;
    b = x;
  } else if (h < 240) {
    g = x;
    b = c;
  } else if (h < 300) {
    r = x;
    b = c;
  } else {
    r = c;
    b = x;
  }
  return Color.fromARGB(
      255,
      ((r + m) * 255).round().clamp(0, 255),
      ((g + m) * 255).round().clamp(0, 255),
      ((b + m) * 255).round().clamp(0, 255));
}
(int, int, bool) lyricBlock(int anchor, int tap, int max) {
  var ns = anchor < tap ? anchor : tap;
  var ne = anchor < tap ? tap : anchor;
  var clamped = false;
  if (ne - ns + 1 > max) {
    clamped = true;
    if (anchor < tap) {
      ne = anchor + max - 1;
    } else {
      ns = anchor - max + 1;
    }
  }
  return (ns, ne, clamped);
}

/// Bottom sheet with position-synced lyrics (karaoke scroll + highlight).
void showLyricsSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _LyricsSheet(),
  );
}

class _LyricsSheet extends StatefulWidget {
  const _LyricsSheet();

  @override
  State<_LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<_LyricsSheet> {
  LyricsData? _data;
  bool _loading = true;
  final _scroll = ScrollController();
  final Map<int, GlobalKey> _lineKeys = {};
  int _active = -1;
  double _offsetS = 0;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String get _title => QueuePlayer.instance.currentTitle.value;

  String get _offsetKey => 'lyricOffset_$_title';

  Future<void> _shift(double delta) async {
    final next = (_offsetS + delta).clamp(-8.0, 8.0);
    if (next == _offsetS) return;
    setState(() => _offsetS = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_offsetKey, _offsetS);
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _data = null;
      _active = -1;
    });
    final prefs = await SharedPreferences.getInstance();
    _offsetS = prefs.getDouble(_offsetKey) ?? 0;
    final api = ServerContext.of(context);
    final cur = QueuePlayer.instance.current;
    // Internet items carry the resolved (actual) video identity — key the
    // lyrics against that, so they match the recording that really plays.
    final d = (cur != null &&
            (cur.lyricsArtist?.isNotEmpty ?? false) &&
            (cur.lyricsTitle?.isNotEmpty ?? false))
        ? await api.lyricsBy(cur.lyricsArtist!, cur.lyricsTitle!)
        : await api.lyrics(_title);
    if (!mounted) return;
    setState(() {
      _data = d;
      _loading = false;
      _active = -1;
      _scrolledIdx = -1;
      _lineKeys.clear();
    });
  }

  int _indexAt(Duration pos) {
    final data = _data;
    if (data == null || !data.isSynced) return -1;
    final ms = pos.inMilliseconds - (_offsetS * 1000).round();
    var idx = 0;
    for (var i = 0; i < data.synced.length; i++) {
      if (data.synced[i].t * 1000 <= ms) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  // Last line we scrolled for (moved exactly one row per advance).
  int _scrolledIdx = -1;
  // Measured row step (real geometry); fallback for unbuilt far rows.
  double _rowStep = 40.0;

  // --- Spotify-style share selection: one consecutive block, max 5 lines.
  bool _selecting = false;
  int? _anchor;
  int _selStart = 0;
  int _selEnd = -1;
  static const int _maxPick = 5;

  List<String> get _lines {
    final d = _data;
    if (d == null) return const [];
    if (d.isSynced) return [for (final l in d.synced) l.text];
    return d.plain;
  }

  bool _picked(int i) =>
      _selecting && _anchor != null && i >= _selStart && i <= _selEnd;

  int get _pickCount =>
      (!_selecting || _anchor == null) ? 0 : _selEnd - _selStart + 1;

  void _toggleSelectMode() {
    setState(() {
      _selecting = !_selecting;
      _anchor = null;
      _selStart = 0;
      _selEnd = -1;
    });
  }

  /// Tap a line in select mode: first tap anchors, later taps set the
  /// block to [anchor..tap] (always consecutive). Tapping the anchor of a
  /// single-line pick clears it.
  void _tapPick(int i) {
    if (_anchor == null) {
      setState(() {
        _anchor = i;
        _selStart = i;
        _selEnd = i;
      });
      return;
    }
    final a = _anchor!;
    if (a == i && _selStart == _selEnd) {
      setState(() {
        _anchor = null;
        _selStart = 0;
        _selEnd = -1;
      });
      return;
    }
    final (ns, ne, clamped) = lyricBlock(a, i, _maxPick);
    if (clamped) toast(context, "${tr('Max lines')}: $_maxPick");
    // Predict the canvas at the card's fixed scale (see LayoutBuilder):
    // refuse a block that would overflow instead of clipping afterward.
    final mq = MediaQuery.of(context);
    final candidate = _lines.sublist(
        ns.clamp(0, _lines.length), (ne + 1).clamp(0, _lines.length));
    if (candidate.isNotEmpty &&
        !lyricFitsCard(mq.size.width, mq.size.height, candidate)) {
      toast(context, tr("Won't fit on the card"));
      return;
    }
    setState(() {
      _selStart = ns;
      _selEnd = ne;
    });
  }

  /// Extend the picked block one line up (-1) or down (+1), Spotify
  /// handle behavior. Stops at the list edges and the max pick count.
  void _extend(int dir) {
    if (_anchor == null) return;
    final mq = MediaQuery.of(context);
    bool fits(int s, int e) {
      final candidate = _lines.sublist(
          s.clamp(0, _lines.length), (e + 1).clamp(0, _lines.length));
      return candidate.isEmpty ||
          lyricFitsCard(mq.size.width, mq.size.height, candidate);
    }

    if (dir < 0) {
      if (_selStart <= 0) return;
      if (_pickCount >= _maxPick) {
        toast(context, "${tr('Max lines')}: $_maxPick");
        return;
      }
      if (!fits(_selStart - 1, _selEnd)) {
        toast(context, tr("Won't fit on the card"));
        return;
      }
      setState(() => _selStart--);
    } else {
      if (_selEnd >= _lines.length - 1) return;
      if (_pickCount >= _maxPick) {
        toast(context, "${tr('Max lines')}: $_maxPick");
        return;
      }
      if (!fits(_selStart, _selEnd + 1)) {
        toast(context, tr("Won't fit on the card"));
        return;
      }
      setState(() => _selEnd++);
    }
  }

  /// Tappable handle box shown above the first / below the last picked
  /// line. Tapping it adds that neighboring line to the share.
  Widget _handle(int dir) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _extend(dir),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: Spots.green.withValues(alpha: .16),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Spots.green, width: 1.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  dir < 0 ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: Spots.green,
                ),
                const SizedBox(width: 4),
                Text(
                  dir < 0 ? tr('line above') : tr('line below'),
                  style: TextStyle(
                      fontSize: 12,
                      color: Spots.green,
                      fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Background picker in its own sheet: always reachable, never part of
  /// the captured card. Auto follows the cover art; presets (incl. Onyx
  /// true-black) override it for this share.

  Future<void> _sharePicked() async {
    final lines = [
      for (var i = _selStart; i <= _selEnd; i++) _lines[i]
    ];
    if (lines.isEmpty || !mounted) return;
    final cur = QueuePlayer.instance.current;
    var artist = (cur?.lyricsArtist ?? '').trim();
    var title = (cur?.lyricsTitle ?? '').trim();
    if (title.isEmpty) {
      final full = _title;
      final k = full.indexOf(' - ');
      if (k > 0) {
        if (artist.isEmpty) artist = full.substring(0, k).trim();
        title = full.substring(k + 3).trim();
      } else {
        title = full;
      }
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _LyricsCardPreview(
          lines: lines,
          title: title.isEmpty ? _title : title,
          artist: artist,
          artUrl: QueuePlayer.instance.currentThumb.value,
        ),
      ),
    );
  }

  void _maybeScroll(int idx) {
    if (idx == _active || idx < 0 || !_scroll.hasClients) return;
    final prev = _active;
    _active = idx;
    final key = _lineKeys.putIfAbsent(idx, () => GlobalKey());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      try {
        final ctx = key.currentContext;
        if (ctx == null) {
          // Far seek jump: row not laid out (virtualized list) — jump by
          // the measured step so it gets built, then fine-tune next tick.
          final target = (idx * _rowStep)
              .clamp(0.0, _scroll.position.maxScrollExtent)
              .toDouble();
          if ((target - _scroll.offset).abs() >= 8) {
            _scrolledIdx = idx;
            _scroll.animateTo(target,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut);
          }
          return;
        }
        final box = ctx.findRenderObject();
        if (box is! RenderBox || !box.attached) return;
        final vp = RenderAbstractViewport.of(box);
        double? target;
        if (prev >= 0 &&
            prev == _scrolledIdx &&
            (idx == prev + 1 || idx == prev - 1)) {
          final pctx = _lineKeys[prev]?.currentContext;
          final pbox = pctx?.findRenderObject();
          if (pbox is RenderBox && pbox.attached) {
            final dy = box.localToGlobal(Offset.zero).dy -
                pbox.localToGlobal(Offset.zero).dy;
            if (dy.isFinite && dy.abs() < 2000 && dy.abs() > 0) {
              _rowStep = dy.abs();
              target = (_scroll.offset + dy)
                  .clamp(0.0, _scroll.position.maxScrollExtent)
                  .toDouble();
            }
          }
        }
        target ??= vp
            .getOffsetToReveal(box, 0.40)
            .offset
            .clamp(0.0, _scroll.position.maxScrollExtent)
            .toDouble();
        if ((target - _scroll.offset).abs() < 8) {
          _scrolledIdx = idx;
          return;
        }
        _scrolledIdx = idx;
        _scroll.animateTo(target,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut);
      } catch (_) {
        // A detached box mid-song-switch must never crash the sheet.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final n = _data?.synced.length ?? _data?.plain.length ?? 0;
    // More room for long lyric sets so they scroll/read comfortably; compact
    // for short ones.
    final factor = n > 30 ? 0.88 : (n > 0 ? 0.7 : 0.5);
    return FractionallySizedBox(
      heightFactor: factor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_selecting)
              Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close),
                    tooltip: tr('Cancel'),
                    onPressed: _toggleSelectMode,
                  ),
                  Expanded(
                    child: Text(
                      _pickCount == 0
                          ? tr('Tap lines to select')
                          : "${tr('Selected')}: $_pickCount/$_maxPick",
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ),
                  TextButton.icon(
                    onPressed:
                        _pickCount > 0 ? () => _sharePicked() : null,
                    icon: const Icon(Icons.share_outlined, size: 18),
                    label: Text(tr('Share')),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Text(_title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                  if (_data != null && _data!.found)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.share_outlined, size: 20),
                      tooltip: tr('Share lyrics'),
                      onPressed: _toggleSelectMode,
                    ),
                ],
              ),
            const SizedBox(height: 4),
            Text(tr('Lyrics'),
                style: TextStyle(color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 8),
            if (_data != null && _data!.isSynced) ...[
              Row(children: [
                Icon(Icons.tune,
                    size: 14, color: Colors.white38),
                const SizedBox(width: 6),
                Text(
                    _offsetS == 0
                        ? "${tr('sync offset')}  0.0 s"
                        : "${tr('sync offset')}  ${_offsetS >= 0 ? '+' : ''}${_offsetS.toStringAsFixed(2)} s",
                    style: const TextStyle(
                        fontSize: 12, color: Colors.white54)),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.fast_rewind, size: 18),
                    tooltip: tr('Lyrics earlier'),
                  onPressed: () => _shift(-0.25),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.fast_forward, size: 18),
                    tooltip: tr('Lyrics later'),
                  onPressed: () => _shift(0.25),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.replay, size: 18),
                    tooltip: tr('Reset offset'),
                  onPressed: _offsetS == 0 ? null : () => _shift(-_offsetS),
                ),
              ]),
              const SizedBox(height: 4),
            ],
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    final data = _data;
    if (data == null || (!data.found)) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('No lyrics found for this track.'),
              style: TextStyle(color: Colors.white54)),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _fetch,
            icon: const Icon(Icons.refresh),
            label: Text(tr('Try again')),
          ),
        ]),
      );
    }
    if (data.isSynced) {
      return ValueListenableBuilder<Duration>(
        valueListenable: QueuePlayer.instance.position,
        builder: (_, pos, __) {
          final idx = _indexAt(pos);
          if (idx >= 0) _maybeScroll(idx);
          return ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: data.synced.length,
            itemBuilder: (_, i) {
              final active = i == idx;
              final line = data.synced[i].text;
              final n = data.synced.length;
              final maxed = _pickCount >= _maxPick;
              final showUp = _selecting &&
                  _anchor != null &&
                  !maxed &&
                  i == _selStart &&
                  i > 0;
              final showDown = _selecting &&
                  _anchor != null &&
                  !maxed &&
                  i == _selEnd &&
                  i < n - 1;
              return GestureDetector(
                key: _lineKeys.putIfAbsent(i, () => GlobalKey()),
                behavior: HitTestBehavior.opaque,
                onTap: _selecting
                    ? () => _tapPick(i)
                    : () {
                        try {
                          QueuePlayer.instance.seek(Duration(
                              milliseconds:
                                  ((data.synced[i].t + _offsetS) * 1000)
                                      .round()));
                        } catch (_) {
                          // ignore: tapping a line is best effort
                        }
                      },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showUp) _handle(-1),
                    Container(
                      width: double.infinity,
                      color: _picked(i)
                          ? Spots.green.withValues(alpha: .22)
                          : Colors.transparent,
                      child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 150),
                    style: TextStyle(
                      fontSize: 19,
                      height: 1.75,
                      color: active ? Spots.green : Colors.white70,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(line,
                          softWrap: true,
                          overflow: TextOverflow.visible),
                    ),
                  ),
                ),
                    if (showDown) _handle(1),
                  ],
                ),
              );
            },
          );
        },
      );
    }
    // plain text
    return ListView.builder(
      itemCount: data.plain.length,
      itemBuilder: (_, i) {
        final maxed = _pickCount >= _maxPick;
        final showUp =
            _selecting && _anchor != null && !maxed && i == _selStart && i > 0;
        final showDown = _selecting &&
            _anchor != null &&
            !maxed &&
            i == _selEnd &&
            i < data.plain.length - 1;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _selecting ? () => _tapPick(i) : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showUp) _handle(-1),
              Container(
                width: double.infinity,
                color: _picked(i)
                    ? Spots.green.withValues(alpha: .22)
                    : Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(data.plain[i],
                    softWrap: true,
                    overflow: TextOverflow.visible,
                    style: const TextStyle(
                        fontSize: 16, height: 1.5)),
              ),
              if (showDown) _handle(1),
            ],
          ),
        );
      },
    );
  }
}

/// Spotify-style lyrics story card (9:16): picked lines over a dark
/// gradient + cover art, title/artist footer. Shared as a PNG image
/// with no link attached.
class _LyricsCardPreview extends StatefulWidget {
  const _LyricsCardPreview({
    required this.lines,
    required this.title,
    required this.artist,
    required this.artUrl,
  });

  final List<String> lines;
  final String title;
  final String artist;
  final String artUrl;

  @override
  State<_LyricsCardPreview> createState() => _LyricsCardPreviewState();
}

class _LyricsCardPreviewState extends State<_LyricsCardPreview> {
  final _shotKey = GlobalKey();
  bool _sharing = false;
  // Backdrop sampled from the cover art (Spotify paints its card from the
  // artwork): two most vivid hues merge in a diagonal gradient, card is
  // the darkest shade. Falls back to a deep tone with no fetchable art.
  // _manual < 0 follows the auto colors; otherwise a preset pair index.
  // Active colors:
  Color _bgA = const Color(0xFF8E2430);
  Color _bgB = const Color(0xFF5E1620);
  Color _card = const Color(0xFF3A0E14);
  // Auto-sampled colors:
  Color _autoA = const Color(0xFF8E2430);
  Color _autoB = const Color(0xFF5E1620);
  Color _autoCard = const Color(0xFF3A0E14);
  int _manual = -1;
  List<Color>? _custom; // manual color-wheel triple; active when _manual == _presets.length

  void _applyAuto() {
    _bgA = _autoA;
    _bgB = _autoB;
    _card = _autoCard;
  }

  static const _presets = <String>[
    'Onyx',
    'Crimson',
    'Plum',
    'Gold',
    'Forest',
    'Ocean',
    'Slate',
  ];

  static List<Color> _presetTriple(String name) {
    // [gradient-top, gradient-bottom, card]
    switch (name) {
      case 'Onyx':
        return const [
          Color(0xFF2A2A2E),
          Color(0xFF101012),
          Color(0xFF000000)
        ];
      case 'Plum':
        return const [
          Color(0xFF3B2364),
          Color(0xFF1B1032),
          Color(0xFF120B20)
        ];
      case 'Gold':
        return const [
          Color(0xFF9A7B24),
          Color(0xFF574512),
          Color(0xFF2E250A)
        ];
      case 'Forest':
        return const [
          Color(0xFF256B3D),
          Color(0xFF124024),
          Color(0xFF0A2617)
        ];
      case 'Ocean':
        return const [
          Color(0xFF245A8C),
          Color(0xFF12395C),
          Color(0xFF0A2237)
        ];
      case 'Slate':
        return const [
          Color(0xFF484E59),
          Color(0xFF26292F),
          Color(0xFF141619)
        ];
      case 'Crimson':
      default:
        return const [
          Color(0xFFA02A36),
          Color(0xFF631823),
          Color(0xFF3A0E14)
        ];
    }
  }

  @override
  void initState() {
    super.initState();
    _sampleBg();
  }

  static List<double> _toHsl(Color c) {
    final r = c.red / 255, g = c.green / 255, b = c.blue / 255;
    final mx = [r, g, b].reduce((a, e) => a > e ? a : e);
    final mn = [r, g, b].reduce((a, e) => a < e ? a : e);
    var h = 0.0;
    final l = (mx + mn) / 2;
    var s = 0.0;
    if (mx != mn) {
      s = l > 0.5 ? (mx - mn) / (2 - mx - mn) : (mx - mn) / (mx + mn);
      if (mx == r) {
        h = ((g - b) / (mx - mn)) % 6;
      } else if (mx == g) {
        h = (b - r) / (mx - mn) + 2;
      } else {
        h = (r - g) / (mx - mn) + 4;
      }
      h *= 60;
      if (h < 0) h += 360;
    }
    return [h, s, l];
  }

  Future<void> _sampleBg() async {
    // Art bytes from http(s) or a local file. content:// URIs can't be
    // read here (provider lives behind a channel) — those keep defaults.
    Uint8List? artBytes;
    final u = widget.artUrl;
    try {
      if (u.startsWith('http')) {
        final resp = await http
            .get(Uri.parse(u))
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
          artBytes = resp.bodyBytes;
        }
      } else {
        final path = u.startsWith('file://')
            ? Uri.parse(u).toFilePath()
            : (u.startsWith('/') ? u : null);
        if (path != null) {
          final f = File(path);
          if (await f.exists()) artBytes = await f.readAsBytes();
        }
      }
    } catch (_) {
      artBytes = null;
    }
    if (artBytes == null || artBytes.isEmpty || !mounted) return;
    try {
      // 8x8 grid → sampleCardColors: the three most frequent buckets
      // (hue buckets + one neutral-grey bucket) paint gradient-top,
      // gradient-bottom and card. Bucket CENTERS are the colors — never
      // a vector average (averaging yellow+blue drifts to a teal that
      // exists nowhere in the art). Mean saturation inside each winning
      // bucket for depth.
      final codec = await ui.instantiateImageCodec(artBytes,
          targetWidth: 8, targetHeight: 8);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData();
      if (data == null || !mounted) return;
      final px = data.buffer.asUint8List();
      final rows = <List<double>>[];
      for (var i = 0; i + 3 < px.length; i += 4) {
        if (px[i + 3] < 128) continue; // transparent padding is not black
        rows.add(_toHsl(Color.fromARGB(255, px[i], px[i + 1], px[i + 2])));
      }
      if (!mounted) return;
      final (a, b, card) = sampleCardColors(rows);
      if (!mounted) return;
      setState(() {
        _autoA = a;
        _autoB = b;
        _autoCard = card;
        if (_manual < 0) _applyAuto();
      });
    } catch (_) {}
  }

  Widget? _art(double size) {
    final u = widget.artUrl;
    try {
      if (u.startsWith('http')) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(u,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const SizedBox.shrink()),
        );
      }
      final path = u.startsWith('file://')
          ? Uri.parse(u).toFilePath()
          : (u.startsWith('/') ? u : null);
      if (path != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(File(path),
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const SizedBox.shrink()),
        );
      }
    } catch (_) {}
    return null;
  }


  Future<void> _pickColor() async {
    Widget dot(String label, Color c, bool selected, VoidCallback onTap) {
      return GestureDetector(
        onTap: () {
          onTap();
          Navigator.pop(context);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                    color: selected ? Colors.white : Colors.white24,
                    width: selected ? 3 : 1.5),
              ),
              child: label == 'Auto'
                  ? const Icon(Icons.auto_awesome,
                      size: 20, color: Colors.white)
                  : null,
            ),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    color:
                        selected ? Colors.white : Colors.white54)),
          ],
        ),
      );
    }

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('Background'),
                  style:
                      TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              Wrap(
                spacing: 16,
                runSpacing: 14,
                children: [
                  dot(tr('Auto'), _autoA, _manual < 0, () {
                    setState(() {
                      _manual = -1;
                      _applyAuto();
                    });
                  }),
                  for (var i = 0; i < _presets.length; i++)
                    Builder(builder: (_) {
                      final triple = _presetTriple(_presets[i]);
                      return dot(_presets[i], triple[0], _manual == i,
                          () {
                        setState(() {
                          _manual = i;
                          _bgA = triple[0];
                          _bgB = triple[1];
                          _card = triple[2];
                        });
                      });
                    }),
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      _pickCustom();
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: SweepGradient(colors: [
                              Colors.red,
                              Colors.yellow,
                              Colors.green,
                              Colors.cyan,
                              Colors.blue,
                              const Color(0xFFFF00FF),
                              Colors.red,
                            ]),
                            border: Border.all(
                                color: _manual == _presets.length
                                    ? Colors.white
                                    : Colors.white24,
                                width: _manual == _presets.length
                                    ? 3
                                    : 1.5),
                          ),
                          child: _custom == null
                              ? const Icon(Icons.add,
                                  size: 20, color: Colors.white)
                              : null,
                        ),
                        const SizedBox(height: 6),
                        Text(tr('Custom'),
                            style: TextStyle(
                                fontSize: 11,
                                color: _manual == _presets.length
                                    ? Colors.white
                                    : Colors.white54)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Manual color picker: saturation/value plane with a draggable pointer
  /// + hue slider bar + live preview. The picked color becomes the gradient
  /// top; bottom + card are darker shades of the same hue so text stays
  /// readable.
  Future<void> _pickCustom() async {
    final startC = _manual == _presets.length && _custom != null
        ? _custom![0]
        : _bgA;
    final startHsv = HSVColor.fromColor(startC);
    var h = startHsv.hue;
    var s = startHsv.saturation.clamp(0.0, 1.0);
    var v = startHsv.value.clamp(0.25, 1.0);
    const planeH = 190.0;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          Color picked() => HSVColor.fromAHSV(1, h, s, v).toColor();
          final hsl = _toHsl(picked());
          final hh = hsl[0].isNaN ? h : hsl[0];
          final ss = hsl[1].isNaN ? 0.5 : hsl[1].clamp(0.15, 0.85);
          final top = picked();
          final bottom = hslColor(hh, ss, 0.30);
          final card = hslColor(hh, ss, 0.16);
          final hueColor = HSVColor.fromAHSV(1, h, 1, 1).toColor();
          return AlertDialog(
            title: Text(tr('Custom color'),
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            content: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 72,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [top, bottom]),
                    ),
                    alignment: Alignment.bottomLeft,
                    padding: const EdgeInsets.all(10),
                    child: Container(
                      width: 120,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: card,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('Aa preview',
                          style: TextStyle(
                              color: Colors.white, fontSize: 13)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Saturation (x) / value (y) plane for the current hue.
                  LayoutBuilder(builder: (_, box) {
                    final w = box.maxWidth;
                    void setSV(Offset p) => setD(() {
                          s = (p.dx / w).clamp(0.0, 1.0);
                          v = (1 - p.dy / planeH).clamp(0.0, 1.0);
                        });
                    return GestureDetector(
                      onPanDown: (d) => setSV(d.localPosition),
                      onPanUpdate: (d) => setSV(d.localPosition),
                      child: Container(
                        height: planeH,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          gradient: LinearGradient(colors: [
                            Colors.white,
                            hueColor,
                          ]),
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black,
                              ],
                            ),
                          ),
                          child: Stack(
                            children: [
                              Positioned(
                                left: s * w - 11,
                                top: (1 - v) * planeH - 11,
                                child: Container(
                                  width: 22,
                                  height: 22,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: picked(),
                                    border: Border.all(
                                        color: Colors.white, width: 2.5),
                                    boxShadow: const [
                                      BoxShadow(
                                          color: Colors.black54,
                                          blurRadius: 4),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 12),
                  // Hue bar: every color, drag the thumb.
                  LayoutBuilder(builder: (_, box) {
                    final w = box.maxWidth;
                    void setH(Offset p) => setD(() {
                          h = (p.dx / w).clamp(0.0, 1.0) * 360;
                        });
                    return GestureDetector(
                      onPanDown: (d) => setH(d.localPosition),
                      onPanUpdate: (d) => setH(d.localPosition),
                      child: Container(
                        height: 28,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: const LinearGradient(colors: [
                            Colors.red,
                            Colors.yellow,
                            Colors.green,
                            Colors.cyan,
                            Colors.blue,
                            Color(0xFFFF00FF),
                            Colors.red,
                          ]),
                        ),
                        child: Stack(
                          children: [
                            Positioned(
                              left: (h / 360 * w - 11)
                                  .clamp(0.0, w - 22),
                              top: 3,
                              child: Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: hueColor,
                                  border: Border.all(
                                      color: Colors.white, width: 2.5),
                                  boxShadow: const [
                                    BoxShadow(
                                        color: Colors.black54,
                                        blurRadius: 4),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(tr('Cancel'))),
              FilledButton(
                  onPressed: () {
                    final triple = [top, bottom, card];
                    setState(() {
                      _custom = triple;
                      _manual = _presets.length;
                      _bgA = triple[0];
                      _bgB = triple[1];
                      _card = triple[2];
                    });
                    Navigator.pop(ctx);
                  },
                  child: Text(tr('Apply'))),
            ],
          );
        },
      ),
    );
  }

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      await Future.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      final obj = _shotKey.currentContext?.findRenderObject();
      if (obj is! RenderRepaintBoundary) return;
      final img = await obj.toImage(pixelRatio: 2.5);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || !mounted) return;
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/lyrics-card.png');
      await f.writeAsBytes(data.buffer.asUint8List());
      await SharePlus.instance.share(ShareParams(
        files: [XFile(f.path)],
        subject: 'Lyrics',
      ));
    } catch (_) {
      if (mounted) {
        toast(context, tr('Sharing failed'), icon: Icons.error_outline);
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final art = _art(lyricCardHeader);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(tr('Share lyrics')),
        actions: [
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            tooltip: tr('Background color'),
            onPressed: _pickColor,
          ),
          TextButton.icon(
            onPressed: _sharing ? null : _share,
            icon: _sharing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.share_outlined, size: 20),
            label: Text(tr('Share')),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              // Cap the card well below full height: the swatch row must
              // always stay on screen and tappable (on small screens the
              // 9:16 card pushed it out of reach entirely).
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight:
                      MediaQuery.of(context).size.height * 0.68,
                ),
                child: AspectRatio(
                aspectRatio: 9 / 16,
                child: RepaintBoundary(
                  key: _shotKey,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [_bgA, _bgB],
                      ),
                    ),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: lyricCardInnerH,
                              vertical: lyricCardOuterV),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(28),
                          child: Container(
                            color: _card,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  lyricCardInnerH,
                                  lyricCardInnerV,
                                  lyricCardInnerH,
                                  lyricCardInnerV),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      if (art != null) ...[
                                        art,
                                        const SizedBox(width: 14),
                                      ],
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        widget.title,
                                        maxLines: 1,
                                        // Fixed scale (see below): the header
                                        // must stay 64px on every device.
                                        textScaler: TextScaler.noScaling,
                                        style: const TextStyle(
                                            fontSize: 17,
                                            fontWeight:
                                                FontWeight.w800,
                                            color: Colors.white),
                                      ),
                                    ),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        widget.artist.isNotEmpty
                                            ? "${tr('Song')} · ${widget.artist}"
                                            : tr('Song'),
                                        maxLines: 1,
                                        textScaler: TextScaler.noScaling,
                                        style: const TextStyle(
                                            fontSize: 14,
                                            color: Colors.white70),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                                    ],
                                  ),
                                  const SizedBox(height: 26),
                                  Expanded(
                                    child: LayoutBuilder(
                                      builder: (ctx, cons) {
                                        // Fixed scale: the card is an exported
                                        // image, not UI — it must look the
                                        // same regardless of system font size.
                                        final size = lyricFitSize(
                                            cons.maxWidth,
                                            cons.maxHeight,
                                            widget.lines);
                                        return Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize:
                                              MainAxisSize.min,
                                          children: [
                                            for (final l
                                                in widget.lines)
                                              Padding(
                                                padding:
                                                    const EdgeInsets.only(
                                                        bottom: 12),
                                                child: Text(
                                                  l,
                                                  // Fixed scale: the card is
                                                  // an exported image, not
                                                  // UI — it must look the
                                                  // same regardless of system
                                                  // font size, exactly what
                                                  // the fit gate measured.
                                                  textScaler:
                                                      TextScaler.noScaling,
                                                  style: TextStyle(
                                                      fontSize: size,
                                                      height: 1.3,
                                                      color: Colors.white,
                                                      fontWeight:
                                                          FontWeight
                                                              .w700),
                                                ),
                                              ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                          const SizedBox(height: 20),
],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
        ),
],
),
);
}

}