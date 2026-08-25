import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

class QueueItem {
  final String title;
  final String url;
  final String? thumbUrl;
  QueueItem(this.title, this.url, {this.thumbUrl});
}

/// App-wide playback queue with shuffle — the "Spotify" engine.
class QueuePlayer {
  QueuePlayer._() {
    _player.onPlayerComplete.listen((_) => next());
    _player.onPositionChanged
        .listen((d) => position.value = d);
    _player.onDurationChanged
        .listen((d) => trackDuration.value = d);
    _player.onPlayerStateChanged.listen((s) => status.value = s);
  }

  static final QueuePlayer instance = QueuePlayer._();
  final AudioPlayer _player = AudioPlayer();

  List<QueueItem> items = [];
  int index = -1;
  bool _shuffle = false;

  final ValueNotifier<String> currentTitle = ValueNotifier('');
  final ValueNotifier<bool> shuffleEnabled = ValueNotifier(false);
  final ValueNotifier<String> currentThumb = ValueNotifier('');
  final ValueNotifier<double> volume = ValueNotifier(1.0);
  final ValueNotifier<PlayerState> status =
      ValueNotifier(PlayerState.stopped);
  final ValueNotifier<int> queueIndex = ValueNotifier(-1);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> trackDuration = ValueNotifier(Duration.zero);

  Stream<PlayerState> get stateStream => _player.onPlayerStateChanged;
  bool get playing => _player.state == PlayerState.playing;

  Future<void> playList(List<QueueItem> q,
      {int startIndex = 0, bool startShuffled = false}) async {
    if (q.isEmpty) return;
    items = List.of(q);
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
        items..remove(cur)..insert(index, cur);
      }
    }
    // un-shuffle keeps current order; nothing to rebuild
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

  Future<void> seek(Duration d) => _player.seek(d);
  Future<void> setVolume(double v) async {
    volume.value = v.clamp(0.0, 1.0);
    await _player.setVolume(volume.value);
  }
  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.resume();
  Future<void> stop() => _player.stop();

  Future<void> _playCurrent() async {
    queueIndex.value = index;
    if (index < 0 || index >= items.length) {
      currentTitle.value = '';
      currentThumb.value = '';
      return;
    }
    currentTitle.value = items[index].title;
    currentThumb.value = items[index].thumbUrl ?? '';
    try {
      await _player.stop();
      await _player.play(UrlSource(items[index].url));
    } catch (_) {/* surfaced via player error stream */}
  }
}
