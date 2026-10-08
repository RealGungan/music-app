import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/prefetch_store.dart';

void main() {
  List<String> queue(int n) => List.generate(n, (i) => 'Song $i');

  group('PrefetchStore.window', () {
    test('includes current plus next aheadCount rows', () {
      final q = queue(50);
      final w = PrefetchStore.window(q, 5, 1 + PrefetchStore.aheadCount);
      expect(w.length, 1 + PrefetchStore.aheadCount);
      expect(w.first, 'Song 5');
      expect(w.last, 'Song ${5 + PrefetchStore.aheadCount}');
    });

    test('single-item queue still prefetches the current song', () {
      final w = PrefetchStore.window(queue(1), 0, 11);
      expect(w, ['Song 0']);
    });

    test('clamps at the tail (fewer rows remain)', () {
      final w = PrefetchStore.window(queue(50), 47, 11);
      expect(w, ['Song 47', 'Song 48', 'Song 49']);
    });

    test('empty queue and bad index yield nothing', () {
      expect(PrefetchStore.window(queue(0), 0, 11), isEmpty);
      expect(PrefetchStore.window(queue(10), -1, 11), isEmpty);
      expect(PrefetchStore.window(queue(10), 10, 11), isEmpty);
    });

    test('zero count yields nothing', () {
      expect(PrefetchStore.window(queue(10), 3, 0), isEmpty);
    });
  });
}
