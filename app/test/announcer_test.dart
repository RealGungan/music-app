import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/announcer.dart';

void main() {
  group('isServerNewer', () {
    test('newer patch/minor/major detected', () {
      expect(isServerNewer('1.0.74', '1.0.73'), isTrue);
      expect(isServerNewer('1.1.0', '1.0.99'), isTrue);
      expect(isServerNewer('2.0.0', '1.9.9'), isTrue);
    });
    test('equal or older is not newer', () {
      expect(isServerNewer('1.0.73', '1.0.73'), isFalse);
      expect(isServerNewer('1.0.72', '1.0.73'), isFalse);
      expect(isServerNewer('1.0.73', '1.0.73+76'), isFalse);
    });
    test('missing parts count as 0, junk ignored', () {
      expect(isServerNewer('1.0', '1.0.0'), isFalse);
      expect(isServerNewer('1.0.1', '1.0'), isTrue);
      expect(isServerNewer('', '1.0.73'), isFalse);
    });
  });
}
