import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/debug_overlay.dart';
import 'package:nasmusic/playback_engine.dart';

void main() {
  group('Debug overlay', () {
    test('default off', () {
      expect(DebugInfo.enabled.value, isFalse);
    });
    test('record helpers stamp entries', () {
      DebugInfo.pause('tap');
      DebugInfo.resume('ok');
      DebugInfo.heal('stall start');
      DebugInfo.nudge('fired');
      DebugInfo.share('sheet', '');
      expect(DebugInfo.lastPause, contains('tap'));
      expect(DebugInfo.lastResume, contains('ok'));
      expect(DebugInfo.lastHeal, contains('stall'));
      expect(DebugInfo.lastNudge, contains('fired'));
      expect(DebugInfo.shareTier, 'sheet');
    });
    test('pause-drop diagnostic pure', () {
      expect(pauseDropDiagnostic(acked: true), isNull);
      expect(pauseDropDiagnostic(acked: false), 'pause-dropped');
    });
  });
}
