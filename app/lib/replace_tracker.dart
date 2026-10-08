import 'package:flutter/foundation.dart';

/// Pinned, on-top progress for a check-songs replacement job.
///
/// The replace flow (download → verify → swap) runs minutes on the server
/// while the user does other things. This global notifier carries the live
/// phase so Settings → Check songs can pin a progress card at the top of
/// the list until the swap is really done — no more "it said downloaded
/// but nothing replaced" confusion.
class ReplaceState {
  final String baseName;
  final String versionName;
  final String phase;
  final String detail;
  final DateTime startedAt;
  final bool done;
  final bool success;
  const ReplaceState({
    required this.baseName,
    required this.versionName,
    required this.phase,
    this.detail = '',
    required this.startedAt,
    this.done = false,
    this.success = false,
  });

  ReplaceState copyWith({
    String? phase,
    String? detail,
    bool? done,
    bool? success,
  }) => ReplaceState(
    baseName: baseName,
    versionName: versionName,
    phase: phase ?? this.phase,
    detail: detail ?? this.detail,
    startedAt: startedAt,
    done: done ?? this.done,
    success: success ?? this.success,
  );
}

class ReplaceTracker {
  ReplaceTracker._();
  static final ValueNotifier<ReplaceState?> active = ValueNotifier(null);

  static void start(String baseName, String versionName) {
    active.value = ReplaceState(
      baseName: baseName,
      versionName: versionName,
      phase: 'Starting…',
      startedAt: DateTime.now(),
    );
  }

  static void progress(String phase, [String detail = '']) {
    final cur = active.value;
    if (cur == null || cur.done) return;
    active.value = cur.copyWith(phase: phase, detail: detail);
  }

  static void finish({required bool success, String detail = ''}) {
    final cur = active.value;
    if (cur == null) return;
    active.value = cur.copyWith(
      phase: success ? 'Replaced.' : 'Failed.',
      detail: detail,
      done: true,
      success: success,
    );
  }

  static void dismiss() {
    final cur = active.value;
    if (cur == null) return;
    active.value = cur.copyWith(
      phase: 'Dismissed.',
      detail: '',
      done: true,
      success: false,
    );
  }
}
