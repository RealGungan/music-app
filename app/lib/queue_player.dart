import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

class QueueItem {
  final String title;
  final String url;
  final String? thumbUrl;

  /// Non-null for discovery tracks whose [url] is a `/staging/resolve/<vid>`
  /// placeholder that must be resolved to a direct audio URL before playing.
  final String? videoId;
  QueueItem(this.title, this.url, {this.thumbUrl, this.videoId});
}

/// Turns a discovery [videoId] into a direct streamable audio URL.
typedef UrlResolver = Future<String> Function(String videoId);

/// App-wide playback queue with shuffle — the "streaming engine".
class QueuePlayer {
  QueuePlayer._() {
    _player.onPlayerComplete.listen((_) {
      if (repeatEnabled.value) {
        _playCurrent();
      } else {
        next();
      }
    });
    _player.onPositionChanged.listen((d) {
      position.value = d;
      _onTick();
    });
    _player.onDurationChanged.listen((d) {
      trackDuration.value = d;
      _onTick();
    });
    _player.onPlayerStateChanged.listen((s) {
      if (s == PlayerState.playing) loading.value = false;
    });
  }

  static final QueuePlayer instance = QueuePlayer._();
  final AudioPlayer _player = AudioPlayer();

  List<QueueItem> items = [];
  int index = -1;
  bool _shuffle = false;

  /// Set by discovery UI so resolve placeholders can be resolved lazily.
  UrlResolver? resolver;

  final ValueNotifier<String> currentTitle = ValueNotifier('');
  final ValueNotifier<bool> shuffleEnabled = ValueNotifier(false);
  final ValueNotifier<bool> repeatEnabled = ValueNotifier(false);
  final ValueNotifier<String> currentThumb = ValueNotifier('');
  final ValueNotifier<bool> loading = ValueNotifier(false);
  final ValueNotifier<String?> lastError = ValueNotifier(null);
  final ValueNotifier<double> volume = ValueNotifier(1.0);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> trackDuration = ValueNotifier(Duration.zero);
  final ValueNotifier<double> progressFractionNotifier = ValueNotifier(0);
  final ValueNotifier<int> queueLength =
      ValueNotifier(0);

  // keep progress notifier in sync as the player moves
  void _onTick() {
    final d = trackDuration.value;
    progressFractionNotifier.value =
        d <= Duration.zero ? 0 : (position.value.inMilliseconds / d.inMilliseconds);
  }

  Stream<PlayerState> get stateStream => _player.onPlayerStateChanged;
  bool get playing => _player.state == PlayerState.playing;
  Duration get currentPosition => position.value;

  /// Filled fraction (0..1) for progress indicators.
  double get progressFraction {
    final d = trackDuration.value;
    if (d <= Duration.zero) return 0;
    return position.value.inMilliseconds / d.inMilliseconds;
  }

  Future<void> playList(List<QueueItem> q,
      {int startIndex = 0, bool startShuffled = false}) async {
    if (q.isEmpty) return;
    items = List.of(q);
    queueLength.value = items.length;
    _shuffle = startShuffled;
    shuffleEnabled.value = _shuffle;
    if (_shuffle) items.shuffle();
    index = startIndex.clamp(0, items.length - 1);
    await _playCurrent();
  }

  Future<void> playOne(QueueItem it) => playList([it]);

  Future<void> toggleShuffle() async {
    if (items.isEmpty) return;
    _shuffle = !_shuffle;
    shuffleEnabled.value = _shuffle;
    final cur = index >= 0 && index < items.length ? items[index] : null;
    if (_shuffle) {
      items.shuffle(Random());
      if (cur != null) {
        items
          ..remove(cur)
          ..insert(index, cur);
      }
    }
  }

  Future<void> toggleRepeat() {
    repeatEnabled.value = !repeatEnabled.value;
    return Future.value();
  }

  Future<void> next() async {
    if (items.isEmpty) return;
    index = (index + 1) % items.length;
    await _playCurrent();
  }

  Future<void> previous() async {
    if (items.isEmpty) return;
    if (position.value > const Duration(seconds: 4)) {
      await _player.seek(Duration.zero);
      return;
    }
    index = (index - 1 + items.length) % items.length;
    await _playCurrent();
  }

  /// Play the item at [i] without touching the shuffle order.
  Future<void> jumpTo(int i) async {
    if (i < 0 || i >= items.length) return;
    index = i;
    await _playCurrent();
  }

  Future<void> seek(Duration d) => _player.seek(d);

  Future<void> setVolume(double v) async {
    volume.value = v.clamp(0.0, 1.0);
    await _player.setVolume(volume.value);
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.resume();
  Future<void> stop() => _player.stop();

  Future<void> resumeOrPause() => playing ? _player.pause() : _player.resume();

  Future<void> _playCurrent() async {
    if (index < 0 || index >= items.length) {
      currentTitle.value = '';
      loading.value = false;
      return;
    }
    currentTitle.value = items[index].title;
    currentThumb.value = items[index].thumbUrl ?? '';
    loading.value = true;
    try {
      var url = items[index].url;
      final item = items[index];
      final vid = item.videoId;
      if (vid != null &&
          url.contains('/staging/resolve/') &&
          resolver != null) {
        url = await resolver!(vid);
        items[index] =
            QueueItem(item.title, url, thumbUrl: item.thumbUrl, videoId: vid);
      }
      await _player.stop();
      await _player.play(UrlSource(url));
      _prefetchNext();
    } catch (e) {
      loading.value = false;
      lastError.value = e.toString();
    }
  }

  /// Warm the next track's URL in the background so next() starts instantly.
  void _prefetchNext() {
    if (items.isEmpty || resolver == null) return;
    final n = (index + 1) % items.length;
    final it = items[n];
    if (it.videoId == null || !it.url.contains('/staging/resolve/')) return;
    resolver!(it.videoId!)
        .then((u) {
          if (n < items.length && identical(items[n], it) && it.videoId == items[n].videoId) {
            items[n] = QueueItem(it.title, u,
                thumbUrl: it.thumbUrl, videoId: it.videoId);
          }
        })
        .catchError((_) {});
  }
}
