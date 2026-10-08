import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/debug_bundle.dart';

void main() {
  String base() => DebugBundle.buildText(
        appVersion: '1.0.266+269',
        server: 'http://music.rg.nig:8004',
        user: 'emutest2',
        queue: 'index=2/10 current=X playing=true [X]',
        logcat: 'logline',
        restartLog: 'rlog',
        carLog: '',
        now: DateTime.utc(2026, 10, 8),
      );

  test('bundle carries versions, queue, logcat and both disk logs', () {
    final t = base();
    expect(t, contains('app: 1.0.266+269'));
    expect(t, contains('server: http://music.rg.nig:8004'));
    expect(t, contains('user: emutest2'));
    expect(t, contains('queue: index=2/10'));
    expect(t, contains('logline'));
    expect(t, contains('rlog'));
    expect(t, contains('=== CAR LOG (disk) ==='));
  });

  test('empty sections render an (empty) marker, never blank-gaps', () {
    final t = DebugBundle.buildText(
      appVersion: 'v',
      server: 's',
      user: 'u',
      queue: 'q',
      logcat: '',
      restartLog: '',
      carLog: '',
      now: DateTime.utc(2026, 10, 8),
    );
    expect('(empty)'.allMatches(t).length, 3);
  });
}
