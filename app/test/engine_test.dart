import 'package:flutter_test/flutter_test.dart';
import 'package:music_app/queue_player.dart';

void main() {
  QueuePlayer qp = QueuePlayer.instance;

  setUp(() {
    // reset engine state without touching audio
    qp.loadQueue([
      QueueItem('A - One', 'a1'),
      QueueItem('B - Two', 'b2'),
      QueueItem('C - Three', 'c3'),
      QueueItem('D - Four', 'd4'),
    ]);
    qp.repeat.value = RepeatMode.off;
  });

  test('playNext inserts right after the current song', () {
    qp.playNext({3}); // move D after A
    expect(qp.items.map((e) => e.title).toList(),
        ['A - One', 'D - Four', 'B - Two', 'C - Three']);
    expect(qp.index, 0); // still on A
  });

  test('playNext preserves relative order of multiple picks', () {
    qp.playNext({2, 3}); // C then D after A
    expect(qp.items.map((e) => e.title).toList(),
        ['A - One', 'C - Three', 'D - Four', 'B - Two']);
  });

  test('removeAt never removes the playing track and keeps index', () {
    qp.removeAt({0}); // try removing current (A)
    expect(qp.items.length, 4);
    expect(qp.index, 0);
    qp.removeAt({2}); // remove C
    expect(qp.items.map((e) => e.title).toList(),
        ['A - One', 'B - Two', 'D - Four']);
  });

  test('shuffle pins the current song and restores order on toggle-off',
      () {
    final original = qp.items.map((e) => e.title).toList();
    qp.toggleShuffle();
    expect(qp.shuffleEnabled.value, true);
    expect(qp.items[0].title, 'A - One'); // current pinned at front
    qp.toggleShuffle();
    expect(qp.shuffleEnabled.value, false);
    expect(qp.items.map((e) => e.title).toList(), original);
  });

  test('reorder moves track and keeps following it', () {
    qp.reorder(0, 3); // drag A to the end
    expect(qp.items.map((e) => e.title).toList(),
        ['B - Two', 'C - Three', 'D - Four', 'A - One']);
    expect(qp.index, 3);
    expect(qp.currentItem!.title, 'A - One');
  });

  test('auto-extend appends similar tracks near queue end', () async {
    qp.fetchSimilar = (query, {excludeTitles = const []}) async =>
        [QueueItem('$query - Extra', 'x')];
    qp.index = 3; // on last track
    await qp.extendQueue(); // no audio involved
    final titles = qp.items.map((e) => e.title).toList();
    expect(
        titles.any(
            (t) => t.startsWith('D - ') && t.endsWith('Extra')),
        isTrue,
        reason: 'queue should have auto-extended: $titles');
    // seeding twice for same source must not duplicate
    await qp.extendQueue();
    expect(qp.items.where((t) => t.title == 'D - Extra').length, 1);
  });
}
