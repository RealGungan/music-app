import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/queue_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pins the queue-sheet swipe contract (now_playing.dart resolves the swiped
/// row by song identity, then calls these): the right song moves exactly
/// once to the expected position, stays playable, chains stack in swipe
/// order, and the playing row can never be swiped away.
class _SilentConnectivity extends MockStreamHandler {
  const _SilentConnectivity();
  @override
  void onListen(dynamic args, MockStreamHandlerEventSink events) {}
  @override
  void onCancel(dynamic args) {}
}

QueueItem _song(String name) => QueueItem(name, 'https://cdn/$name');

/// Fresh queue; [playing] is the index of the currently playing row.
void _reset(QueuePlayer qp, List<String> names, int playing) {
  qp.items = [for (final n in names) _song(n)];
  qp.index = playing;
  qp.playPos = playing;
}

List<String> _titles(QueuePlayer qp) => [for (final it in qp.items) it.title];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'), (c) async => null);
    m.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'),
        (c) async => null);
    // QueuePlayer subscribes to connectivity at construction; stay silent.
    m.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      const _SilentConnectivity(),
    );
  });

  group('swipe right = play next (moveToPlayNext)', () {
    test('correct song lands right after the playing row, once', () {
      final qp = QueuePlayer.instance;
      _reset(qp, const ['A', 'B', 'C', 'D'], 0);
      expect(qp.moveToPlayNext(2), isTrue); // swipe C
      expect(_titles(qp), ['A', 'C', 'B', 'D']);
      expect(qp.index, 0); // playhead still on A
      expect(qp.items.where((it) => it.title == 'C').length, 1);
      expect(qp.items[1].manuallyPlaced, isTrue);
      expect(qp.queueLength.value, 4);
    });

    test('moved song stays playable (intact direct url, no placeholder)', () {
      final qp = QueuePlayer.instance;
      _reset(qp, const ['A', 'B', 'C', 'D'], 0);
      final url = qp.items[2].url;
      qp.moveToPlayNext(2);
      final moved = qp.items[1];
      expect(moved.url, url);
      expect(moved.url.isNotEmpty, isTrue);
      expect(moved.videoId, isNull);
      expect(moved.resolveName, isNull);
    });

    test('chained swipes stack in swipe order behind current', () {
      final qp = QueuePlayer.instance;
      _reset(qp, const ['A', 'B', 'C', 'D', 'E'], 0);
      qp.moveToPlayNext(2); // C first
      qp.moveToPlayNext(qp.items.indexWhere((it) => it.title == 'D'));
      expect(_titles(qp), ['A', 'C', 'D', 'B', 'E']);
    });

    test('repeat swipe of the same song never duplicates it', () {
      final qp = QueuePlayer.instance;
      _reset(qp, const ['A', 'B', 'C'], 0);
      qp.moveToPlayNext(qp.items.indexWhere((it) => it.title == 'C'));
      qp.moveToPlayNext(qp.items.indexWhere((it) => it.title == 'C'));
      expect(_titles(qp), ['A', 'C', 'B']);
      expect(qp.items.where((it) => it.title == 'C').length, 1);
    });

    test('swiping the playing row is refused', () {
      final qp = QueuePlayer.instance;
      _reset(qp, const ['A', 'B', 'C'], 1);
      expect(qp.moveToPlayNext(1), isFalse);
      expect(_titles(qp), ['A', 'B', 'C']);
    });

    test('identity resolution survives a shifted list (rapid double swipe)', () {
      final qp = QueuePlayer.instance;
      _reset(qp, const ['A', 'B', 'C', 'D'], 0);
      // First swipe removed B; a second swipe captured pre-removal must
      // resolve C by identity, not by its stale position.
      final c = qp.items[2];
      expect(qp.removeFromQueue(1), isTrue); // B gone: [A C D]
      final idx = qp.items.indexOf(c);
      expect(idx, 1);
      expect(qp.moveToPlayNext(idx), isTrue);
      expect(_titles(qp), ['A', 'C', 'D']);
      expect(qp.items.where((it) => identical(it, c)).length, 1);
    });
  });

  group('swipe left = remove (removeFromQueue + undo)', () {
    test('exactly the swiped song is removed, playhead follows', () {
      final qp = QueuePlayer.instance;
      _reset(qp, const ['A', 'B', 'C', 'D'], 2); // playing C
      final c = qp.items[2];
      expect(qp.removeFromQueue(0), isTrue); // swipe A (above playhead)
      expect(_titles(qp), ['B', 'C', 'D']);
      expect(qp.index, 1);
      expect(identical(qp.current, c), isTrue);
    });

    test('removing the playing row is refused', () {
      final qp = QueuePlayer.instance;
      _reset(qp, const ['A', 'B', 'C'], 1);
      expect(qp.removeFromQueue(1), isFalse);
      expect(_titles(qp), ['A', 'B', 'C']);
      expect(qp.queueLength.value, 3);
    });

    test('undo reinserts the same song at the same position', () {
      final qp = QueuePlayer.instance;
      _reset(qp, const ['A', 'B', 'C', 'D'], 0);
      final removed = qp.items[2];
      expect(qp.removeFromQueue(2), isTrue);
      expect(_titles(qp), ['A', 'B', 'D']);
      expect(qp.insertAt(2, removed), isTrue);
      expect(_titles(qp), ['A', 'B', 'C', 'D']);
      expect(identical(qp.items[2], removed), isTrue);
      expect(qp.index, 0);
    });

    test('removed unknown position is refused', () {
      final qp = QueuePlayer.instance;
      _reset(qp, const ['A', 'B'], 0);
      expect(qp.removeFromQueue(9), isFalse);
      expect(qp.removeFromQueue(-1), isFalse);
      expect(_titles(qp), ['A', 'B']);
    });
  });

  group('long-press = play next at current+1 (playNextNewItem, never bottom)', () {
    test('new song lands right after current, playhead untouched', () {
      final qp = QueuePlayer.instance;
      _reset(qp, const ['A', 'B', 'C'], 0);
      expect(qp.playNextNewItem(_song('X')), isTrue);
      expect(_titles(qp), ['A', 'X', 'B', 'C']);
      expect(qp.index, 0);
      expect(qp.items.where((it) => it.title == 'X').length, 1);
      expect(qp.items[1].manuallyPlaced, isTrue);
      expect(qp.queueLength.value, 4);
    });

    test('lands behind the play-next chain, not after current', () {
      final qp = QueuePlayer.instance;
      _reset(qp, const ['A', 'B', 'C'], 0);
      qp.moveToPlayNext(1); // B queued next: [A B C]
      expect(qp.playNextNewItem(_song('Z')), isTrue);
      expect(_titles(qp), ['A', 'B', 'Z', 'C']);
      expect(qp.items.where((it) => it.title == 'Z').length, 1);
    });

    test('queued copy stays playable (direct url + all resolve keys kept)', () {
      final qp = QueuePlayer.instance;
      _reset(qp, const ['A'], 0);
      final lazy = QueueItem(
        'Artist - NewSong',
        'https://srv/staging/resolve/VID123',
        videoId: 'VID123',
        resolveName: (artist: 'Artist', title: 'NewSong'),
        lyricsArtist: 'Artist',
        lyricsTitle: 'NewSong',
      );
      expect(qp.playNextNewItem(lazy), isTrue);
      final added = qp.items[1];
      expect(identical(added, lazy), isTrue);
      expect(added.url, isNotEmpty);
      expect(added.videoId, 'VID123');
      expect(added.resolveName, isNotNull);
      expect(added.lyricsTitle, 'NewSong');
      expect(added.manuallyPlaced, isTrue);
    });

    test('empty queue starts playing the added song', () {
      final qp = QueuePlayer.instance;
      SharedPreferences.setMockInitialValues({});
      _reset(qp, const [], 0);
      qp.index = 0;
      expect(qp.playNextNewItem(_song('First')), isTrue);
      expect(_titles(qp), ['First']);
      expect(qp.index, 0);
    });
  });
}
