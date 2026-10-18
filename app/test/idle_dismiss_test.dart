import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/audio_handler.dart';

const _after = Duration(milliseconds: 10);
const _settle = Duration(milliseconds: 40);

void main() {
  group('IdleDismisser', () {
    test('does not arm while audio is playing', () {
      final d = IdleDismisser(after: _after, onDismiss: () {});
      d.update(playing: true, loading: false, hasMedia: true);
      expect(d.armed, isFalse);
      expect(d.dismissed, isFalse);
    });

    test('fires onDismiss exactly once when idle', () async {
      var fired = 0;
      final d = IdleDismisser(after: _after, onDismiss: () => fired++);

      d.update(playing: false, loading: false, hasMedia: true);
      expect(d.armed, isTrue);

      await Future<void>.delayed(_settle);
      expect(fired, 1);
      expect(d.dismissed, isTrue);
      expect(d.armed, isFalse);

      await Future<void>.delayed(_settle);
      expect(fired, 1);
    });

    test('start() cancels the timer and clears dismissed', () async {
      var fired = 0;
      final d = IdleDismisser(after: _after, onDismiss: () => fired++);

      d.dismissNow();
      expect(d.dismissed, isTrue);

      d.start();
      expect(d.dismissed, isFalse);
      expect(d.armed, isFalse);

      await Future<void>.delayed(_settle);
      expect(fired, 0);
    });
  });
}