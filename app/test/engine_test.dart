import 'dart:math';
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


  test('OFF restores exact original order, ON reshuffles differently', () {
    qp.loadQueue([
      QueueItem('T1', 'u1'),
      QueueItem('T2', 'u2'),
      QueueItem('T3', 'u3'),
      QueueItem('T4', 'u4'),
      QueueItem('T5', 'u5'),
    ]);
    final original = qp.items.map((e) => e.title).toList();

    // seed a fixed rng so the first shuffle is deterministic
    qp.toggleShuffle(rng: Random(42));
    expect(qp.shuffleEnabled.value, true);
    expect(qp.items[0].title, 'T1'); // current pinned
    final firstShuffle = qp.items.map((e) => e.title).toList();

    qp.toggleShuffle(); // OFF -> restore
    expect(qp.items.map((e) => e.title).toList(), original);

    qp.toggleShuffle(rng: Random(7)); // ON again with different seed
    final secondShuffle = qp.items.map((e) => e.title).toList();
    expect(secondShuffle.toSet(), original.toSet()); // same multiset
    // pinned current still first, upcoming reshuffled vs first attempt
    expect(secondShuffle.first, 'T1');
    expect(
        secondShuffle.sublist(1), isNot(firstShuffle.sublist(1)),
        reason: 'a fresh ON should reshuffle the upcoming tail');
  });

  test('playNext successive swipes stack A then B after current', () {
    qp.loadQueue([
      QueueItem('A - one', 'a'),
      QueueItem('B - two', 'b'),
      QueueItem('C - three', 'c'),
      QueueItem('D - four', 'd'),
    ]);
    qp.index = 0; // playing A
    qp.playNext({3}); // swipe D -> right after A
    expect(qp.items[1].title, 'D - four');
    qp.playNext({3}); // then swipe C (now idx3) -> goes after A, before D
    expect(qp.items[1].title, 'C - three');
    expect(qp.items[2].title, 'D - four');
  });

  test('removeAt keeps playing song and order', () {
    qp.removeAt({1});
    expect(qp.items.map((e) => e.title).toList(),
        ['A - One', 'C - Three', 'D - Four']);
    expect(qp.index, 0);
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

extension ShuffleTests on void {}
