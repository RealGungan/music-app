import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:music_app/main.dart';
import 'package:music_app/screens/now_playing.dart';
import 'package:music_app/queue_player.dart';

void main() {
  testWidgets('app shell renders', (tester) async {
    await tester.pumpWidget(MusicApp(
      initialServer: 'http://127.0.0.1:6680',
      onServerChanged: (_) {},
    ));
    await tester.pump();
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('mini player controls are visible when a track plays',
      (tester) async {
    final qp = QueuePlayer.instance;
    addTearDown(() {
      qp.currentTitle.value = '';
      qp.currentThumb.value = '';
    });

    await tester.pumpWidget(MusicApp(
      initialServer: 'http://127.0.0.1:6680',
      onServerChanged: (_) {},
    ));
    // simulate a playing track
    qp.items = [QueueItem('x', 'http://x/a.mp3')];
    qp.index = 0;
    qp.currentTitle.value = 'Some Song';
    await tester.pumpAndSettle();

    // every control must exist AND be hittable (visible, not clipped)
    for (final icon in [Icons.skip_next]) {
      final f = find.byIcon(icon);
      expect(f, findsOneWidget, reason: '$icon missing');
      expect(
          tester.getRect(f),
          paintsWithin(screenBoundsOf(tester)),
          reason: '$icon outside window bounds');
    }
  });

  testWidgets('now playing page shows all controls fully on-screen',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 700); // desktop-ish
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final qp = QueuePlayer.instance;
    qp.currentTitle.value = 'Some Song';
    qp.currentThumb.value = '';

    await tester.pumpWidget(const MaterialApp(home: NowPlayingPageHost()));
    await tester.pumpAndSettle();

    bool anyOf(Widget w, List<IconData> cs) =>
        w is Icon && cs.contains(w.icon);
    final shuffleish = find.byWidgetPredicate(
        (w) => anyOf(w, [Icons.shuffle, Icons.shuffle_outlined]));
    expect(shuffleish, findsOneWidget, reason: 'shuffle missing');
    for (final icon in [
      Icons.skip_previous,
      Icons.skip_next,
      Icons.play_arrow,
      Icons.keyboard_arrow_down,
    ]) {
      final f = find.byIcon(icon);
      expect(f, findsOneWidget, reason: '$icon missing');
      expect(tester.getRect(f), paintsWithin(screenBoundsOf(tester)),
          reason: '$icon outside window bounds');
    }
  });
}

Rect screenBoundsOf(WidgetTester t) =>
    Offset.zero &
    (t.view.physicalSize / t.view.devicePixelRatio);

Matcher paintsWithin(Rect bounds) => predicate(
    (Rect r) =>
        r.left >= bounds.left &&
        r.top >= bounds.top &&
        r.right <= bounds.right &&
        r.bottom <= bounds.bottom,
    'inside $bounds');

class NowPlayingPageHost extends StatelessWidget {
  const NowPlayingPageHost({super.key});
  @override
  Widget build(BuildContext context) => const NowPlayingPage();
}
