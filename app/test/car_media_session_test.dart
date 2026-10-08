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

  group('self-echo window (tap-to-play focus echo)', () {
    test('echo inside the window is ignored', () {
      final t0 = DateTime(2026, 1, 1);
      // Observed 1.7s echo after network plays must be ignored.
      expect(
        isSelfFocusEcho(
            lastOwnPlayAt: t0, now: t0.add(const Duration(milliseconds: 1700))),
        isTrue,
      );
      expect(
        isSelfFocusEcho(
            lastOwnPlayAt: t0, now: t0.add(const Duration(milliseconds: 10))),
        isTrue,
      );
    });
    test('genuine takeover after the window is honored', () {
      final t0 = DateTime(2026, 1, 1);
      expect(
        isSelfFocusEcho(
            lastOwnPlayAt: t0, now: t0.add(const Duration(seconds: 10))),
        isFalse,
      );
    });
    test('window is 3s (covers the 1.7s network-play echo)', () {
      expect(selfFocusEchoWindow, const Duration(seconds: 3));
    });
  });

  group('new-track publish (timestamp flash guard)', () {
    test('fresh pub carries zero duration until measured', () {
      expect(durationForNewTrackPub(), Duration.zero);
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
