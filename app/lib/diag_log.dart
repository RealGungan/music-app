import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On-device diagnostic logs so bugs can be diagnosed without a PC/adb.
///
/// Two independent ring-buffer logs, toggled from Settings > Diagnostics:
/// - [restart]: queue/heal/playback events for the "~15s restart" bug.
/// - [car]: media-session publications + handler events for the car/AVRCP bug.
///
/// Logs live in memory (cap 800 lines each) and are shared via the native
/// share sheet (Android) or clipboard (desktop) plus a file copy under the
/// app documents dir. Off by default; zero overhead when disabled.
class DiagLog {
  DiagLog._(this._prefKey, this.fileName);

  static final DiagLog restart = DiagLog._(
    'diag_restart_log',
    'nasmusic_restart.log',
  );
  static final DiagLog car = DiagLog._('diag_car_log', 'nasmusic_car.log');

  final String _prefKey;
  final String fileName;
  bool enabled = false;
  final List<String> _ring = [];
  static const int _max = 800;

  static Future<void> initAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      restart.enabled = prefs.getBool(restart._prefKey) ?? false;
      car.enabled = prefs.getBool(car._prefKey) ?? false;
    } catch (_) {}
    // Reload what was persisted: failures logged before a restart stay
    // visible in Settings → Diagnostics without adb.
    await restart._loadFile();
    await car._loadFile();
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, v);
    } catch (_) {}
    if (v) {
      _append('--- log started ${DateTime.now().toIso8601String()} ---');
    } else {
      _append('--- log stopped ${DateTime.now().toIso8601String()} ---');
    }
  }

  void clear() => _ring.clear();

  bool get isEmpty => _ring.isEmpty;

  void log(String msg) {
    if (!enabled) return;
    _append(msg);
  }

  void _append(String msg) {
    final t = DateTime.now();
    final ts =
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
    _ring.add('[$ts] $msg');
    if (_ring.length > _max) {
      _ring.removeRange(0, _ring.length - _max);
    }
    // Append-through to disk (fire-and-forget): the ring alone dies with
    // the process, and release builds strip debugPrint — this file is the
    // on-device record. _loadFile replays it on the next start.
    unawaited(_persistLine('[$ts] $msg'));
  }

  static String? _docsPath;

  Future<void> _persistLine(String line) async {
    try {
      _docsPath ??= (await getApplicationDocumentsDirectory()).path;
      await File('$_docsPath/$fileName')
          .writeAsString('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// Replay the persisted file tail into the ring (cap [_max]).
  Future<void> _loadFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$fileName');
      if (!await f.exists()) return;
      final lines = await f.readAsLines();
      final tail =
          lines.length > _max ? lines.sublist(lines.length - _max) : lines;
      _ring.addAll(tail);
    } catch (_) {}
  }

  /// Full snapshot (oldest first).
  String snapshot() => _ring.join('\n');

  /// Last [n] lines — used for sharing (binder-safe size).
  String tail(int n) =>
      (_ring.length <= n ? _ring : _ring.sublist(_ring.length - n)).join('\n');

  /// Write the full snapshot to the app documents dir. Returns the path.
  Future<String> writeFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/$fileName');
    await f.writeAsString(snapshot());
    return f.path;
  }

  /// Share via the native sheet, falling back to clipboard. Returns true
  /// when the native sheet was used.
  static Future<bool> shareText(String text, String subject) async {
    try {
      const channel = MethodChannel('com.nasmusic.nasmusic/share');
      final sent = await channel.invokeMethod<bool>('shareText', {
        'text': text,
        'subject': subject,
      });
      if (sent == true) return true;
    } catch (_) {}
    await Clipboard.setData(ClipboardData(text: text));
    return false;
  }
}
