import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/queue_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Search-tap single-play contract: tapping a search row plays EXACTLY that
/// song and STOPS — no completion advance, no autoplay refill (the "loads it,
/// skips to another, again and again" bug: _playDiscovery queued the whole
/// results page and completion + resolve-skip walked it).
/// Simulates 30s of natural completions (advance + force-refill each) against
/// the post-tap state playList([item], single: true) establishes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'), (c) async => null);
    m.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'),
        (c) async => null);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final qp = QueuePlayer.instance;
    qp.items = [QueueItem('Tap - Song', 'https://cdn/tap')];
    qp.index = 0;
    qp.playPos = 0;
    qp.explicitSingle = true;
    qp.autoplayEnabled.value = true;
  });

  test('single search tap: 30s of completions = exactly 1 play, no refill',
      () async {
    final qp = QueuePlayer.instance;
    var relatedCalls = 0;
    qp.relatedSource = (current, {limit = 0, excludeTitles = const []}) async {
      relatedCalls++;
      return [QueueItem('R1 - Other', 'https://cdn/r1')];
    };
    // 30 simulated completions: advance half + force-refill half (what the
    // completion listener runs: next() then _maybeAutoplay(force: true),
    // reached here via the autoplay toggle).
    for (var s = 0; s < 30; s++) {
      await qp.next();
      await qp.toggleAutoplay(); // off
      await qp.toggleAutoplay(); // on -> force refill attempt
    }
    expect(qp.index, 0);
    expect(qp.items.length, 1);
    expect(qp.items.single.title, 'Tap - Song');
    expect(relatedCalls, 0);
  });

  test('explicit continue still works: addMore clears single-play + fills',
      () async {
    final qp = QueuePlayer.instance;
    qp.relatedSource = (current, {limit = 0, excludeTitles = const []}) async {
      return [QueueItem('R1 - Other', 'https://cdn/r1')];
    };
    await qp.addMore();
    expect(qp.explicitSingle, isFalse);
    expect(qp.items.length, greaterThan(1));
  });

  test(
      'gate check: a NON-single one-row queue refills on completion '
      '(the state playOne() establishes: playList single defaults false, '
      'queue_player.dart:903+910 — this is why every search tap must use '
      'playList([item], single: true))', () async {
    final qp = QueuePlayer.instance;
    qp.items = [QueueItem('Anos - Song', 'https://cdn/anos')];
    qp.index = 0;
    qp.playPos = 0;
    qp.explicitSingle = false;
    qp.autoplayEnabled.value = true;
    var relatedCalls = 0;
    qp.relatedSource =
        (current, {limit = 0, excludeTitles = const []}) async {
      relatedCalls++;
      // Fresh identity: the singleton's _seenKeys may already hold R1 from
      // the tests above (they share QueuePlayer.instance).
      return [QueueItem('R9 - Fresh', 'https://cdn/r9')];
    };
    // One natural completion: advance (no-op, single row) + force refill.
    await qp.next();
    await qp.toggleAutoplay(); // off
    await qp.toggleAutoplay(); // on -> force refill attempt
    expect(relatedCalls, 1);
    expect(qp.items.length, greaterThan(1));
  });
}
