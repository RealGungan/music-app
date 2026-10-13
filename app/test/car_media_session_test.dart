import 'package:audio_service/audio_service.dart';
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

  group('focus-gain audit (no strand at ducked 25%)', () {
    test('gain-restores-volume: ducked gain returns USER volume', () {
      expect(gainRestoreVolume(ducked: true, userVolume: 0.6), 0.6);
      // Never blasts to full when the user had lowered it.
      expect(gainRestoreVolume(ducked: true, userVolume: 1.0), isNotNull);
    });
    test('unducked gain touches nothing', () {
      expect(gainRestoreVolume(ducked: false, userVolume: 0.6), isNull);
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

  group('BT transport report (AVRCP action mapping)', () {
    test('pause/play report fold to queue intent', () {
      expect(transportReportFor('pause'), TransportReport.paused);
      expect(transportReportFor('play'), TransportReport.resumed);
    });
    test('unknown ops are ignored, never crash', () {
      expect(transportReportFor('stop'), isNull);
      expect(transportReportFor('next'), isNull);
      expect(transportReportFor(null), isNull);
      expect(transportReportFor(''), isNull);
    });
  });

  group('session art uri (metadata art vs notification art)', () {
    test('file art publishes the exported content:// uri', () {
      final u = artUriFor(
        isFile: true,
        filePath: '/sdcard/Android/data/x/nasmusic_art.jpg',
        remote: 'https://img/a.jpg',
        bust: 42,
      );
      expect(
        u.toString(),
        'content://com.nasmusic.nasmusic.art/nasmusic_art.jpg?v=42',
      );
    });
    test('no file falls back to the remote http url, never null', () {
      final u = artUriFor(
        isFile: false,
        filePath: null,
        remote: 'https://img/a.jpg',
        bust: 7,
      );
      expect(u.toString(), 'https://img/a.jpg');
    });
    test('nothing known publishes null (never a placeholder)', () {
      expect(
        artUriFor(isFile: false, filePath: null, remote: null, bust: 0),
        isNull,
      );
      expect(
        artUriFor(isFile: false, filePath: null, remote: '', bust: 0),
        isNull,
      );
      expect(
        artUriFor(
          isFile: false,
          filePath: null,
          remote: 'ftp://x/a.jpg',
          bust: 0,
        ),
        isNull,
      );
    });
  });

  group('car queue-tap routing (skipToQueueItem)', () {
    test('index 0 replays the current item', () {
      expect(
        queueTapAction(index: 0, hasPrePushed: false),
        QueueTapAction.replayCurrent,
      );
      expect(
        queueTapAction(index: 0, hasPrePushed: true),
        QueueTapAction.replayCurrent,
      );
    });
    test('index 1 starts the warm pre-push, ignores a cold one', () {
      expect(
        queueTapAction(index: 1, hasPrePushed: true),
        QueueTapAction.startPrePushed,
      );
      expect(
        queueTapAction(index: 1, hasPrePushed: false),
        QueueTapAction.ignore,
      );
    });
    test('out-of-range indices are ignored, never crash', () {
      expect(
        queueTapAction(index: 2, hasPrePushed: true),
        QueueTapAction.ignore,
      );
      expect(
        queueTapAction(index: -1, hasPrePushed: false),
        QueueTapAction.ignore,
      );
    });
  });

  group('BT headset press mapping (single/double/triple)', () {
    test('single-press toggles, double skips next, triple previous', () {
      expect(clickActionFor(MediaButton.media), ClickAction.toggle);
      expect(clickActionFor(MediaButton.next), ClickAction.next);
      expect(clickActionFor(MediaButton.previous), ClickAction.previous);
    });
  });
}
