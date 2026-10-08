import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'queue_player.dart';

/// Tiny always-on-top ground-truth HUD (Developer settings toggle).
/// Shows live engine/handler state, last pause/resume/heal/nudge +
/// result, last share tier + error, queue idx/len, offline, version.
/// 1s refresh. Off by default.
class DebugInfo {
  static final ValueNotifier<bool> enabled = ValueNotifier(false);
  static String appVersion = '';
  static String lastPause = '-';
  static String lastResume = '-';
  static String lastHeal = '-';
  static String lastNudge = '-';
  static String shareTier = '-';
  static String shareError = '-';

  static String _ts() {
    final t = DateTime.now();
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }

  static void pause(String r) => lastPause = '${_ts()} $r';
  static void resume(String r) => lastResume = '${_ts()} $r';
  static void heal(String r) => lastHeal = '${_ts()} $r';
  static void nudge(String r) => lastNudge = '${_ts()} $r';
  static void share(String tier, String err) {
    shareTier = tier;
    shareError = err;
  }

  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      enabled.value = p.getBool('debug_overlay') ?? false;
    } catch (_) {}
  }

  static Future<void> setEnabled(bool v) async {
    enabled.value = v;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('debug_overlay', v);
    } catch (_) {}
  }
}

/// Mount once via MaterialApp.builder: Stack(child + overlay).
class DebugOverlay extends StatefulWidget {
  const DebugOverlay({super.key, required this.child, required this.api});
  final Widget? child;
  final ApiClient api;

  @override
  State<DebugOverlay> createState() => _DebugOverlayState();
}

class _DebugOverlayState extends State<DebugOverlay> {
  Timer? _t;
  String _tick = '';

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (DebugInfo.enabled.value && mounted) setState(() => _tick = DateTime.now().toIso8601String());
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (widget.child != null) widget.child!,
        ValueListenableBuilder<bool>(
          valueListenable: DebugInfo.enabled,
          builder: (_, on, __) {
            if (!on) return const SizedBox.shrink();
            final qp = QueuePlayer.instance;
            final n = qp.items.length;
            final idx = n == 0 ? '-' : '${qp.index}/$n';
            final ver = DebugInfo.appVersion.isNotEmpty
                ? DebugInfo.appVersion
                : widget.api.appVersion;
            // _tick forces the 1s repaint; content reads live singletons.
            return IgnorePointer(
              child: Align(
                alignment: Alignment.topCenter,
                child: SafeArea(
                  child: Container(
                    margin: const EdgeInsets.only(top: 2),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    color: Colors.black.withValues(alpha: 0.72),
                    child: Text(
                      'eng=${qp.engineStateName} hdl=${qp.handlerStateName} '
                      'q=$idx off=${qp.isOffline.value} v=$ver $_tick\n'
                      'P:${DebugInfo.lastPause} R:${DebugInfo.lastResume}\n'
                      'H:${DebugInfo.lastHeal} N:${DebugInfo.lastNudge}\n'
                      'share=${DebugInfo.shareTier} err=${DebugInfo.shareError}',
                      style: const TextStyle(fontSize: 9, color: Colors.greenAccent, fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
