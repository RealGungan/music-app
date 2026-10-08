import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/audio_handler.dart';

void main() {
  group('car focus policy (nav duck vs call pause)', () {
    test('CAN_DUCK begin lowers volume, never pauses', () {
      expect(
          carFocusAction(
              begin: true, type: AudioInterruptionType.duck),
          CarFocusAction.duck);
    });
    test('CAN_DUCK end restores volume, never resumes playback', () {
      expect(
          carFocusAction(
              begin: false, type: AudioInterruptionType.duck),
          CarFocusAction.restoreDuck);
    });
    test('transient loss pauses, regain resumes', () {
      expect(
          carFocusAction(
              begin: true, type: AudioInterruptionType.pause),
          CarFocusAction.pause);
      expect(
          carFocusAction(
              begin: false, type: AudioInterruptionType.pause),
          CarFocusAction.resume);
    });
    test('permanent loss pauses (never ducks)', () {
      expect(
          carFocusAction(
              begin: true, type: AudioInterruptionType.unknown),
          CarFocusAction.pause);
    });
  });

  group('media session id stability (car flicker guard)', () {
    test('strips re-resolving ?token= query', () {
      expect(
          stableMediaId('http://x/stream?vid=a&token=1', 'f'), 'http://x/stream');
    });
    test('falls back when url missing/empty', () {
      expect(stableMediaId(null, 'A - T'), 'A - T');
      expect(stableMediaId('', 'A - T'), 'A - T');
    });
  });
}
