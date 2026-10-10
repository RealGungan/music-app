import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/playback_engine.dart';

/// Pins the SINGLE-engine guard: one process-wide birth; a second birth
/// replaces (disposes) the prior and bumps the birth count.
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

  test('second birth disposes prior + bumps count', () {
    engineBirthCount = 0;
    soleEngine = null;
    final first = buildSingleEngine(remote: false);
    expect(engineBirthCount, 1);
    expect(identical(soleEngine, first), isTrue);
    // Loud in debug (assert) — replacement still lands.
    expect(() => buildSingleEngine(remote: false),
        throwsA(isA<AssertionError>()));
    expect(engineBirthCount, 2);
    expect(identical(soleEngine, first), isFalse);
    ((soleEngine!) as dynamic).dispose();
    soleEngine = null;
  });
}
