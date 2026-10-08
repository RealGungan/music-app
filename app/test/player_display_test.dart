import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/now_playing.dart' show durationLabel;

String _fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = (d.inSeconds.remainder(60)).toString().padLeft(2, '0');
  return '$m:$s';
}

void main() {
  group('player-screen duration label (late stream metadata)', () {
    test('unknown duration shows –:––, not 00:00', () {
      expect(durationLabel(Duration.zero, _fmt), '–:––');
      expect(durationLabel(const Duration(milliseconds: -1), _fmt), '–:––');
    });
    test('known duration formats normally', () {
      expect(durationLabel(const Duration(minutes: 3, seconds: 7), _fmt),
          '03:07');
      expect(
          durationLabel(const Duration(seconds: 1), _fmt), '00:01');
    });
  });
}
