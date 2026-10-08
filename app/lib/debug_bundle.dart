import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'diag_log.dart';
import 'queue_player.dart';

/// One-tap debug bundle: `logcat -d` (own UID, no permission needed) +
/// DiagLog disk logs (restart + car) + versions + queue state, written to one
/// .txt in app docs and opened in the system share sheet.
class DebugBundle {
  /// Pure text assembler — unit-tested, no device needed.
  static String buildText({
    required String appVersion,
    required String server,
    required String user,
    required String queue,
    required String logcat,
    required String restartLog,
    required String carLog,
    required DateTime now,
  }) {
    final sb = StringBuffer()
      ..writeln('gungan.fm debug bundle ${now.toIso8601String()}')
      ..writeln('app: $appVersion')
      ..writeln('server: $server')
      ..writeln('user: $user')
      ..writeln('queue: $queue')
      ..writeln()
      ..writeln('=== LOGCAT (logcat -d, own UID) ===')
      ..writeln(logcat.isEmpty ? '(empty)' : logcat)
      ..writeln()
      ..writeln('=== RESTART LOG (disk) ===')
      ..writeln(restartLog.isEmpty ? '(empty)' : restartLog)
      ..writeln()
      ..writeln('=== CAR LOG (disk) ===')
      ..writeln(carLog.isEmpty ? '(empty)' : carLog);
    return sb.toString();
  }

  /// Queue one-liner + first titles (cap 30) for the bundle header.
  static String queueState(QueuePlayer qp) {
    final items = qp.items;
    final cur = qp.index >= 0 && qp.index < items.length
        ? items[qp.index].title
        : '';
    final head =
        items.take(30).map((e) => e.title).join(' | ');
    return 'index=${qp.index}/${items.length} current=$cur playing=${qp.playing} [$head]';
  }

  /// Build the bundle, save `nasmusic_debug_<ts>.txt` to app docs, share it.
  /// Returns true when the system sheet was used.
  static Future<bool> export({
    required String server,
    required String user,
  }) async {
    String logcat = '';
    try {
      // -d dumps the in-memory buffer and exits; own-UID rows need no permission.
      final r = await Process.run('logcat', ['-d', '-t', '1500']);
      logcat = ((r.stdout as String?) ?? '').trim();
      if ((r.exitCode) != 0 && logcat.isEmpty) {
        logcat = 'logcat exit ${r.exitCode}: ${(r.stderr ?? '').toString().trim()}';
      }
    } catch (e) {
      logcat = 'logcat unavailable (desktop?): $e';
    }
    String appVersion = '';
    try {
      final pi = await PackageInfo.fromPlatform();
      appVersion = '${pi.version}+${pi.buildNumber}';
    } catch (_) {
      appVersion = '(unknown)';
    }
    final qp = QueuePlayer.instance;
    final text = buildText(
      appVersion: appVersion,
      server: server,
      user: user,
      queue: queueState(qp),
      logcat: logcat,
      restartLog: DiagLog.restart.tail(400),
      carLog: DiagLog.car.tail(400),
      now: DateTime.now(),
    );
    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final f = File('${dir.path}/nasmusic_debug_$ts.txt');
    await f.writeAsString(text);
    try {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(f.path)],
        subject: 'gungan.fm debug bundle',
      ));
      return true;
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      return false;
    }
  }
}
