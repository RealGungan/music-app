import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

enum RepeatMode { off, all, one }

class QueueItem {
  String title;
  String url;
  String? thumbUrl;
  String? videoId; // set when url needs resolving before playback
  String? genreHint; // playlist taxonomy this track came from
  String? filePath; // '/staging/file/<rel>' for local tracks (.lrc lookup)
  QueueItem(this.title, this.url,
      {this.thumbUrl, this.videoId, this.genreHint, this.filePath});
  QueueItem? get selfIfCurrent => null;

  @override
  String toString() => 'QueueItem($title)';
}

/// Queue engine. Structural changes notifyListeners(); time/volume-ish
/// streams stay as ValueNotifiers for fine-grained rebuilds.
///
/// AudioPlayer is created lazily so engine logic is unit-testable.
class QueuePlayer extends ChangeNotifier {
  QueuePlayer._();
  static final QueuePlayer instance = QueuePlayer._();

  AudioPlayer? _playerRef;
  bool _wired = false;

  AudioPlayer get _player {
    final p = _playerRef ??= AudioPlayer();
    if (!_wired) {
      _wired = true;
      p.onPlayerComplete.listen((_) async {
        if (repeat.value == RepeatMode.one) {
          await seek(Duration.zero);
          await resume();
          return;
        }
        await next(manual: false);
      });
      p.onPositionChanged.listen((d) => position.value = d);
      p.onDurationChanged.listen((d) => trackDuration.value = d);
      p.onPlayerStateChanged.listen((s) => status.value = s);
    }
    return p;
  }

  List<QueueItem> items = [];
  List<QueueItem> _original = [];
  int index = -1;
  bool _shuffle = false;
  bool _extending = false;
  final Set<String> _seededSources = {};

  // ---- notifiers ------------------------------------------------------
  final ValueNotifier<String> currentTitle = ValueNotifier('');
  final ValueNotifier<String> currentThumb = ValueNotifier('');
  final ValueNotifier<bool> shuffleEnabled = ValueNotifier(false);
  final ValueNotifier<double> volume = ValueNotifier(1.0);
  final ValueNotifier<PlayerState> status =
      ValueNotifier(PlayerState.stopped);
  final ValueNotifier<int> queueIndex = ValueNotifier(-1);
  final ValueNotifier<int> revision = ValueNotifier(0);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> trackDuration = ValueNotifier(Duration.zero);
  final ValueNotifier<RepeatMode> repeat = ValueNotifier(RepeatMode.off);

  bool get playing => status.value == PlayerState.playing;
  bool get hasTrack => index >= 0 && index < items.length;
  QueueItem? get currentItem => hasTrack ? items[index] : null;

  /// Injected by the shell.
  Future<String> Function(String videoId)? resolveVideo;
  /// Injected by the shell: query text -> candidate QueueItems.
  Future<List<QueueItem>> Function(String query,
      {List<String> excludeTitles})? fetchSimilar;

  void _bump() {
    queueIndex.value = index;
    revision.value++;
    notifyListeners();
  }

  // ---- playback control ----------------------------------------------
  /// Load a queue without starting playback (also used by tests).
  void loadQueue(List<QueueItem> q,
      {int startIndex = 0, String? genreHint}) {
    assert(q.isNotEmpty);
    if (genreHint != null) {
      for (final it in q) {
        it.genreHint ??= genreHint;
      }
    }
    items = List.of(q);
    _original = List.of(q);
    index = startIndex.clamp(0, items.length - 1);
    queueIndex.value = index;
    notifyListeners();
  }

  Future<void> playList(List<QueueItem> q,
      {int startIndex = 0,
      bool startShuffled = false,
      String? genreHint}) async {
    if (q.isEmpty) return;
    loadQueue(q, startIndex: startIndex, genreHint: genreHint);
    if (startShuffled) {
      // Spotify 'shuffle play': random first track, rest randomized
      _shuffle = true;
      shuffleEnabled.value = true;
      items.shuffle();
      index = 0;
      queueIndex.value = 0;
    } else if (_shuffle) {
      // jumped into an existing shuffled session: keep upcoming shuffled
      final head = items.sublist(0, index + 1);
      final tail = items.sublist(index + 1)..shuffle();
      items = [...head, ...tail];
    }
    _player; // wire listeners
    await _playCurrent();
    notifyListeners(); // reflect final (possibly shuffled) order NOW
  }

  /// Jump to an existing queue position. NEVER reorders or reshuffles.
  Future<void> jumpTo(int i) async {
    if (i < 0 || i >= items.length) return;
    index = i;
    await _playCurrent();
  }

  Future<void> playOne(QueueItem it) => playList([it]);

  Future<void> toggleShuffle({Random? rng}) async {
    if (items.isEmpty) return;
    _shuffle = !_shuffle;
    shuffleEnabled.value = _shuffle;
    final cur = hasTrack ? items[index] : null;

    if (_shuffle) {
      final head = items.sublist(0, index + 1);
      final tail = items.sublist(index + 1);
      tail.shuffle(rng ?? Random());
      items = [...head, ...tail];
      items = [...head, ...tail];
    } else if (_original.isNotEmpty) {
      final restored = _original.where(items.contains).toList();
      final extras = items.where((it) => !_original.contains(it)).toList();
      items = [...restored, ...extras];
    }
    if (cur != null) index = items.indexOf(cur);
    _bump();
  }

  Future<void> cycleRepeat() async {
    repeat.value = switch (repeat.value) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
  }

  Future<void> next({bool manual = true}) async {
    if (items.isEmpty) return;
    if (index >= items.length - 2 && repeat.value != RepeatMode.one) {
      await extendQueue();
    }
    if (index >= items.length - 1) {
      if (repeat.value == RepeatMode.off && !manual) {
        await stop();
        return;
      }
      index = 0;
    } else {
      index += 1;
    }
    await _playCurrent();
  }

  /// Spotify semantics: first press restarts the song, second goes back.
  Future<void> previous() async {
    if (items.isEmpty) return;
    if (position.value > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    if (items.length < 2) {
      await seek(Duration.zero);
      return;
    }
    index = index - 1 < 0 ? items.length - 1 : index - 1;
    await _playCurrent();
  }

  Future<void> seek(Duration d) => _player.seek(d);
  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.resume();
  Future<void> stop() => _player.stop();

  Future<void> setVolume(double v) async {
    volume.value = v.clamp(0.0, 1.0);
    await _player.setVolume(volume.value);
  }

  Future<void> _playCurrent() async {
    queueIndex.value = index;
    if (!hasTrack) {
      currentTitle.value = '';
      currentThumb.value = '';
      notifyListeners();
      return;
    }
    currentTitle.value = items[index].title;
    currentThumb.value = items[index].thumbUrl ?? '';
    try {
      final it = items[index];
      var src = it.url;
      if (it.videoId != null && !src.startsWith('http')) {
        final r = resolveVideo;
        if (r != null) src = await r(it.videoId!);
        it.url = src;
      }
      await _player.stop();
      await _player.play(UrlSource(src));
    } catch (_) {/* error surfaced via status stream */}
    notifyListeners();
  }

  // ---- endless queue ---------------------------------------------------
  /// Endless-queue: seed more tracks when nearing the end.
  Future<void> extendQueue() async {
    final fetch = fetchSimilar;
    if (fetch == null || _extending || !hasTrack) return;
    final cur = items[index];
    final source = cur.genreHint ??
        (cur.title.contains(' - ')
            ? cur.title.split(' - ').first.trim()
            : '');
    if (source.isEmpty || _seededSources.contains(source)) return;
    _seededSources.add(source);
    _extending = true;
    try {
      final added = await fetch(source,
          excludeTitles: items.map((e) => e.title).toList());
      if (added.isNotEmpty) {
        items.addAll(added);
        _bump();
      }
    } catch (_) {}
    finally {
      _extending = false;
    }
  }

  // ---- queue management -------------------------------------------------
  void removeAt(Set<int> targets) {
    final doomed = [
      for (final i in targets)
        if (i != index && i >= 0 && i < items.length) items[i]
    ];
    if (doomed.isEmpty) return;
    final cur = hasTrack ? items[index] : null;
    items.removeWhere(doomed.contains);
    _original.removeWhere(doomed.contains);
    index = cur != null ? items.indexOf(cur) : -1;
    if (!_shuffle) _original = List.of(items);
    _bump();
  }

  /// Move selected tracks right after the currently playing one.
  void playNext(Set<int> targets) {
    final cur = hasTrack ? items[index] : null;
    if (cur == null) return;
    final picked = [
      for (final i in targets.toList()..sort())
        if (i != index && i >= 0 && i < items.length) items[i]
    ];
    if (picked.isEmpty) return;
    items.removeWhere(picked.contains);
    var at = items.indexOf(cur) + 1;
    for (final it in picked) {
      items.insert(at++, it);
    }
    index = items.indexOf(cur);
    if (!_shuffle) _original = List.of(items);
    _bump();
  }

  /// Drag-reorder within the upcoming region (any positions allowed).
  void reorder(int oldI, int newI) {
    if (oldI < 0 || oldI >= items.length) return;
    newI = newI.clamp(0, items.length - 1);
    if (oldI == newI) return;
    final it = items.removeAt(oldI);
    items.insert(newI, it);
    index = items.indexOf(it); // keep following the dragged one
    if (!_shuffle) _original = List.of(items);
    _bump();
  }
}
