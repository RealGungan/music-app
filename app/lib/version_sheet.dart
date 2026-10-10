import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import 'api_client.dart';
import 'auth_store.dart';
import 'lang.dart';
import 'queue_player.dart';
import 'replace_tracker.dart';
import 'theme.dart';
import 'toast.dart';
import 'widgets.dart';

/// Open the "select a version to replace" sheet for a NAS song (shared by
/// Settings → Check songs and the per-song "Check song" menu).
///
/// Loads the version data, shows the audition/replace sheet, and runs the
/// replace flow (confirm → download job → poll → toasts). [onReplaced] runs
/// after a finished replacement so callers can refresh (e.g. re-check).
Future<void> openVersionPicker(
  BuildContext context, {
  required ApiClient api,
  required String baseName,
  Future<void> Function()? onReplaced,
}) async {
  final SongVersions data;
  try {
    data = await api.songVersions(baseName);
  } catch (e) {
    if (context.mounted) {
      toast(context, "${tr('Could not load versions')}: $e",
          icon: Icons.error_outline);
    }
    return;
  }
  if (!context.mounted) return;
  if (data.error != null) {
    toast(context, data.error!, icon: Icons.info_outline);
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => VersionSheet(
      api: api,
      data: data,
      onReplace: (v) {
        Navigator.pop(ctx);
        _confirmAndReplace(
          context,
          api: api,
          baseName: baseName,
          version: v,
          onReplaced: onReplaced,
        );
      },
    ),
  );
}

Future<void> _confirmAndReplace(
  BuildContext context, {
  required ApiClient api,
  required String baseName,
  required SongVersion version,
  Future<void> Function()? onReplaced,
}) async {
  if (!context.mounted) return;
  // Replace rewrites the shared library file: owner-only server-side.
  // Stop here with a clear note instead of a raw 403 "access denied".
  if (!AuthStore.instance.isOwner) {
    toast(
      context,
      tr('Only the library owner can replace NAS copies.'),
      icon: Icons.info_outline,
    );
    return;
  }
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('Replace the NAS copy?')),
      content: Text(
        'Download "${version.name}" by ${version.artist} as a replacement and remove '
        'the current "$baseName" file. Its added date and album art '
        'are kept. This can take a moment.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(tr('Cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('Replace')),
        ),
      ],
    ),
  );
  if (confirm != true || !context.mounted) return;
  String jobId;
  try {
    jobId = await api.checkReplace(
      baseName,
      version.artist,
      version.name,
      versionDuration: version.durationS,
      versionExplicit: version.explicit,
      versionImage: version.albumImage.isNotEmpty ? version.albumImage : null,
    );
  } catch (e) {
    if (context.mounted) {
      toast(context, "${tr('Replace failed')}: $e", icon: Icons.error_outline);
    }
    return;
  }
  if (!context.mounted) return;
// The pinned banner (Settings → Check songs) carries the live progress;
  // plus a persistent bottom sheet (showUndoBar-style slide-in, but it
  // lives until the job finishes instead of timing out) so the run is
  // visible wherever the user navigates.
  ReplaceTracker.start(baseName, version.name);
  _showReplaceProgress(context);
  // The server-side swap runs AFTER the download lands in staging
  // ('staged' = downloaded, NOT replaced) and can take minutes
  // (download + duration verify + in-place swap, up to ~15 min). Only
  // 'kept' means the NAS copy was actually swapped. Termination is
  // airtight by construction below: every iteration either observes a
  // terminal phase, an unknown (never-seen-before) phase, a vanished
  // job, or a failed poll — nothing spins forever, including a phase
  // stuck non-terminal by a server restart mid-job.
  var seen = false;
  var failures = 0;
  var stable = 0;
  var lastPhase = '';
  // /api/jobs is the primary source; the /api/downloads fallback below runs
  // at most every 3rd tick — unthrottled it doubled downloads traffic for
  // the whole watch whenever the job left the jobs list early.
  var emptyTicks = 0;
  bool _finished = false;
  try {
    for (var i = 0; i < 450; i++) {
    await Future.delayed(const Duration(seconds: 2));
    String phase = '';
    String error = '';
    try {
      final jobs = await api.jobs();
      for (final j in jobs) {
        if (j.id == jobId) {
          phase = j.status;
          error = j.error ?? '';
          break;
        }
      }
      if (phase.isEmpty) {
        if (++emptyTicks % 3 != 0) continue;
        final rows = await api.downloads();
        for (final d in rows) {
          if (d.id == jobId) {
            phase = d.status;
            break;
          }
        }
      } else {
        emptyTicks = 0;
      }
      failures = 0;
    } catch (_) {
      // poll best-effort (offline mid-run, server restarting, ...)
      failures++;
      if (failures >= 20) break; // ~40s+ unreachable: same as timeout
      continue;
    }
    if (phase.isEmpty) {
      if (seen) {
        // The job left both lists after having been observed: finished
        // and pruned (or user-deleted). Either way there is nothing
        // left to watch — clear the banner quietly.
        _finished = true;
        ReplaceTracker.finish(success: true, detail: 'Done.');
        return;
      }
      continue;
    }
    seen = true;
    ReplaceTracker.progress(_replacePhaseText(phase), error);
    if (phase == 'kept') {
      _finished = true;
      ReplaceTracker.finish(success: true);
      if (context.mounted) {
        toast(
          context,
          "${tr('Replacement done')} — \"$baseName\" ${tr('swapped.')}",
          icon: Icons.check_circle,
        );
      }
      await onReplaced?.call();
      return;
    }
    if (phase == 'failed' ||
        phase == 'giveup' ||
        phase == 'no_results' ||
        phase == 'no_official' ||
        phase == 'expired' ||
        phase == 'deleted') {
      _finished = true;
      final reason = error.isNotEmpty ? ' ($error)' : '';
      ReplaceTracker.finish(success: false, detail: error);
      if (context.mounted) {
        toast(
          context,
          "${tr('Replacement failed')}$reason ${tr('— old copy kept.')}",
          icon: Icons.error_outline,
        );
      }
      api.logClientError('replace-failed', '$baseName — $reason');
      return;
    }
// Stability tripwire: a healthy run changes phase every minute or two
  // (queued → searching → downloading → staged → verifying → kept). The
  // same non-terminal phase for 5 minutes means stuck (e.g. a deploy
  // restarted the server mid-job and the phase froze) — stop watching
  // instead of spinning the full 15 minutes.
  if (phase == lastPhase) {
    stable++;
    if (stable >= 150) break;
  } else {
    stable = 0;
    lastPhase = phase;
  }
}
  } finally {
    // Only dismiss if we didn't already finish with a terminal state.
    if (!_finished) {
      ReplaceTracker.finish(success: false, detail: 'Dismissed.');
    }
  }
  if (!_finished) {
    api.logClientError('replace-timeout', '$baseName — poll timed out');
    if (context.mounted) {
      toast(
        context,
        tr('Replace timed out — still running on the server; '
        'check the downloads screen.'),
        icon: Icons.info_outline,
      );
    }
  }
}

/// Replace progress banner, pinned to the TOP (slide-down on show): same
/// green look as the undo bar, but it lives until the job finishes
/// instead of timing out. Spinner + live phase from [ReplaceTracker];
/// auto-removes when the run completes (the completion toast/dialog
/// takes over). The undo bar stays bottom — only this one goes top.
OverlayEntry? _replaceOverlay;
void _showReplaceProgress(BuildContext context) {
  if (_replaceOverlay != null) return; // one banner at a time
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _ReplaceProgressTop(onDone: () {
      try {
        entry.remove();
      } catch (_) {}
      if (identical(_replaceOverlay, entry)) _replaceOverlay = null;
    }),
  );
  _replaceOverlay = entry;
  overlay.insert(entry);
}

class _ReplaceProgressTop extends StatefulWidget {
  const _ReplaceProgressTop({required this.onDone});
  final VoidCallback onDone;

  @override
  State<_ReplaceProgressTop> createState() => _ReplaceProgressTopState();
}

class _ReplaceProgressTopState extends State<_ReplaceProgressTop> {
  bool _gone = false;

  void _maybeDone(ReplaceState? rs) {
    if (!_gone && rs != null && rs.done) {
      _gone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onDone());
      // Belt-and-braces: if the first removal misfires (stale overlay),
      // a second attempt a few seconds later still clears it.
      Future.delayed(const Duration(seconds: 5), () {
        try {
          widget.onDone();
        } catch (_) {}
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ReplaceState?>(
      valueListenable: ReplaceTracker.active,
      builder: (_, rs, __) {
        _maybeDone(rs);
        if (rs == null || _gone) return const SizedBox.shrink();
        final top = MediaQuery.of(context).padding.top + 8;
        return Positioned(
          top: top,
          left: 12,
          right: 12,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: -90.0, end: 0.0),
            duration: const Duration(milliseconds: 300),
            builder: (_, v, child) => Transform.translate(
              offset: Offset(0, v),
              child: child,
            ),
            child: Material(
              color: Spots.green,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    if (!rs.done)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black87),
                      )
                    else
                      const Icon(Icons.check_circle,
                          color: Colors.black87),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        rs.done
                            ? (rs.success
                                ? tr('Replaced.')
                                : tr('Replace failed.'))
                            : "${tr('Replacing')} \"${rs.baseName}\" — ${rs.phase}",
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.w600,
                            fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Friendly one-liner for a raw job/download phase.
String _replacePhaseText(String phase) => switch (phase) {
  'queued' || 'pending' => 'Queued…',
  'searching' => 'Finding the version…',
  'downloading' || 'retrying' => 'Downloading replacement…',
  'staged' => 'Downloaded — verifying…',
  'verifying' => 'Verifying replacement…',
  'kept' => 'Replaced.',
  _ => phase,
};

/// Open the per-song "Check song" sheet: it AUTOMATICALLY runs the
/// fingerprint (identify) + version lookup on open and shows the verdicts,
/// and it always offers the actions (play the NAS copy, open versions /
/// replace) — even when every check passes.
Future<void> openCheckSongSheet(
  BuildContext context, {
  required ApiClient api,
  required CheckSongReport report,
  required Future<void> Function() onPlay,
  required Future<void> Function() onVersions,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => CheckSongSheet(
      api: api,
      report: report,
      onPlay: () async {
        Navigator.pop(ctx);
        await onPlay();
      },
      onVersions: () async {
        Navigator.pop(ctx);
        await onVersions();
      },
    ),
  );
}

class CheckSongSheet extends StatefulWidget {
  const CheckSongSheet({
    super.key,
    required this.api,
    required this.report,
    required this.onPlay,
    required this.onVersions,
  });
  final ApiClient api;
  final CheckSongReport report;
  final Future<void> Function() onPlay;
  final Future<void> Function() onVersions;

  @override
  State<CheckSongSheet> createState() => _CheckSongSheetState();
}

class _CheckSongSheetState extends State<CheckSongSheet> {
  bool _idLoading = true;
  Map<String, dynamic>? _idResult;
  String? _idError;
  bool _vLoading = true;
  SongVersions? _versions;
  String? _vError;

  @override
  void initState() {
    super.initState();
    _runChecks();
  }

  Future<void> _runChecks() async {
    try {
      final res = await widget.api.identify(widget.report.baseName);
      if (!mounted) return;
      setState(() {
        _idResult = res;
        _idLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _idError = e.toString();
        _idLoading = false;
      });
    }
    try {
      final v = await widget.api.songVersions(widget.report.baseName);
      if (!mounted) return;
      setState(() {
        _versions = v;
        _vLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _vError = e.toString();
        _vLoading = false;
      });
    }
  }

  String _fingerprintLine() {
    if (_idLoading) return tr('Checking fingerprint…');
    if (_idError != null) return "${tr('Fingerprint')}: $_idError";
    final r = _idResult ?? {};
    final err = (r['error'] ?? '').toString();
    if (err.isNotEmpty) return "${tr('Fingerprint')}: $err";
    final artist = (r['artist'] ?? '').toString();
    final title = (r['title'] ?? '').toString();
    if (artist.isEmpty && title.isEmpty) {
      return tr('Fingerprint: no match in database.');
    }
    final score = r['score'];
    final real =
        '${artist.isNotEmpty ? '$artist - ' : ''}$title'
        '${score != null ? ' (score $score)' : ''}';
    final match =
        real.toLowerCase().contains(widget.report.baseName.toLowerCase()) ||
        widget.report.baseName.toLowerCase().contains(
          title.toLowerCase(),
        );
    return "${tr('Fingerprint hears')}: $real${match ? '' : tr(' — MISMATCH')}";
  }

  String _versionLine() {
    if (_vLoading) return tr('Loading versions…');
    if (_vError != null) return "${tr('Versions')}: $_vError";
    final v = _versions!;
    if (v.error != null) return "${tr('Versions')}: ${v.error}";
    final n = v.versions.where((e) => !e.isNas).length;
    final exp = v.expectedDur != null ? ' · studio ≈${v.expectedDur}s' : '';
    final cur = v.currentDur != null ? ' · yours ${v.currentDur}s' : '';
    return '$n ${tr('alternative version')}${n == 1 ? '' : tr('s')}$cur$exp';
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final checksDone = !_idLoading && !_vLoading;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              r.baseName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            _checkLine(
              _idLoading || _vLoading
                  ? Icons.hourglass_top
                  : Icons.graphic_eq,
              _fingerprintLine(),
            ),
            const SizedBox(height: 4),
            _checkLine(
              _vLoading ? Icons.hourglass_top : Icons.library_music_outlined,
              _versionLine(),
            ),
            const SizedBox(height: 12),
            // Options are ALWAYS offered, even when every check passes.
            FilledButton.icon(
              onPressed: r.isPlayable ? () => widget.onPlay() : null,
              icon: const Icon(Icons.play_arrow),
              label: Text(tr('Play NAS copy')),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: checksDone && _versions != null
                  ? () => widget.onVersions()
                  : null,
              icon: const Icon(Icons.swap_horiz),
              label: Text(tr('Versions & replace')),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('Close')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _checkLine(IconData icon, String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 18, color: Colors.white54),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
      ),
    ],
  );
}

class VersionSheet extends StatefulWidget {
  const VersionSheet({
    super.key,
    required this.api,
    required this.data,
    required this.onReplace,
  });
  final ApiClient api;
  final SongVersions data;
  final void Function(SongVersion v) onReplace;

  @override
  State<VersionSheet> createState() => _VersionSheetState();
}

class _VersionSheetState extends State<VersionSheet> {
  bool _studioOnly = false;

  final AudioPlayer _preview = AudioPlayer();
  SongVersion? _previewVersion;
  bool _previewPlaying = false;
  bool _wasPlaying = false;
  bool _loadingPreview = false;
  Duration _previewPos = Duration.zero;
  Duration _previewDur = Duration.zero;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;

  bool _showLyrics = false;
  LyricsData? _previewLyrics;
  bool _loadingLyrics = false;

  @override
  void initState() {
    super.initState();
    _posSub = _preview.onPositionChanged.listen(
      (d) => setState(() => _previewPos = d),
    );
    _stateSub = _preview.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      final playing = s == PlayerState.playing;
      setState(() => _previewPlaying = playing);
    });
    _preview.onDurationChanged.listen((d) => setState(() => _previewDur = d));
    _preview.onPlayerComplete.listen((_) {
      // A finished live stream is indistinguishable from completion; on
      // completion just stop (restores the main queue) like a real stop.
      _stopPreview();
    });
  }

  @override
  void dispose() {
    _stopPreview();
    _posSub?.cancel();
    _stateSub?.cancel();
    _preview.dispose();
    super.dispose();
  }

  bool _mainWasListening() =>
      QueuePlayer.instance.items.isNotEmpty && QueuePlayer.instance.playing;

  /// Direct (already-streamable) source for a version: the NAS row uses the
  /// server's file endpoint and plays the WHOLE file. Returns null when we
  /// must resolve the track over the internet first.
  String? _directSource(SongVersion v) {
    if (v.isNas) {
      final url = v.nasUrl;
      if (url != null && url.isNotEmpty) {
        return widget.api.fileUrl(url);
      }
      final rel = v.nasRel;
      return (rel == null || rel.isEmpty) ? null : widget.api.nasFileUrl(rel);
    }
    return null;
  }

  /// The user wants to hear the WHOLE song and scrub through it — not a 30s
  /// teaser. So non-NAS versions are resolved to their full track (YouTube)
  /// and streamed entirely, giving a real seekable timer.
  Future<String?> _resolveSource(SongVersion v) async {
    try {
      final r = await widget.api.resolveByName(artist: v.artist, title: v.name);
      return r.url;
    } catch (_) {
      return null;
    }
  }

  Future<void> _startPreview(SongVersion v) async {
    if (_previewVersion == v && _previewPlaying) {
      _pausePreview();
      return;
    }
    if (_previewVersion == v && _loadingPreview) return;
    final alreadyPreviewing = _previewVersion != null && _previewVersion != v;
    if (alreadyPreviewing) _preview.stop();
    if (!alreadyPreviewing && _previewVersion == null) {
      _wasPlaying = _mainWasListening();
      if (_wasPlaying) QueuePlayer.instance.pause();
    }
    setState(() {
      _previewVersion = v;
      _previewPos = Duration.zero;
      _previewDur = Duration.zero;
      _previewPlaying = false;
      _loadingPreview = true;
      _previewLyrics = null;
      _showLyrics = false;
    });
    var url = _directSource(v);
    if (url == null && v.isNas) {
      // A NAS row must play the NAS file; never fall back to YouTube here or
      // the user hears a different song instead of the one they picked (L).
      setState(() => _loadingPreview = false);
      if (mounted) {
        toast(
          context,
          "${tr('No playable NAS file for')} \"${v.name}\".",
          icon: Icons.error_outline,
        );
      }
      return;
    }
    if (url == null) url = await _resolveSource(v);
    if (!mounted || _previewVersion != v) return;
    if (url == null) {
      setState(() => _loadingPreview = false);
      if (mounted)
        toast(
          context,
          tr('No playable source for this version.'),
          icon: Icons.error_outline,
        );
      return;
    }
    setState(() => _loadingPreview = false);
    try {
      await _preview.play(UrlSource(url));
    } catch (e) {
      if (mounted) {
        setState(() {
          _previewPlaying = false;
          _previewVersion = null;
        });
        toast(context, "${tr('Playback failed')}: $e", icon: Icons.error_outline);
      }
    }
  }

  void _pausePreview() => _preview.pause();
  void _resumePreview() => _preview.resume();

  void _seekPreview(Duration d) => _preview.seek(d);

  void _stopPreview() {
    if (_previewVersion == null && !_previewPlaying && !_loadingPreview) {
      return;
    }
    _preview.stop();
    if (!mounted) return;
    setState(() {
      _previewVersion = null;
      _previewPlaying = false;
      _loadingPreview = false;
      _previewPos = Duration.zero;
      _previewDur = Duration.zero;
      _previewLyrics = null;
      _showLyrics = false;
    });
    // Restore the main queue song if it was playing before we previewed.
    if (_wasPlaying &&
        QueuePlayer.instance.items.isNotEmpty &&
        !QueuePlayer.instance.playing) {
      QueuePlayer.instance.resume();
    }
    _wasPlaying = false;
  }

  Future<void> _toggleLyrics() async {
    final v = _previewVersion;
    if (v == null) return;
    if (_showLyrics && _previewLyrics != null) {
      setState(() => _showLyrics = false);
      return;
    }
    setState(() {
      _showLyrics = true;
      _loadingLyrics = _previewLyrics == null;
    });
    if (_previewLyrics == null) {
      final lyrics = await widget.api.lyrics('${v.artist} - ${v.name}');
      if (!mounted || _previewVersion != v) return;
      setState(() {
        _previewLyrics = lyrics;
        _loadingLyrics = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final spotify = data.spotify;
    final versions = data.versions;
    // The copy you already own is shown separately — it is NOT a replace
    // candidate, so it never appears (and never greys out) in the list.
    final nasRow = versions.where((v) => v.isNas).toList();
    final candidates = _studioOnly
        ? versions.where((v) => v.isStudio && !v.isNas).toList()
        : versions.where((v) => !v.isNas).toList();
    // Best match = studio original closest to the expected duration.
    SongVersion? best;
    for (final v in candidates) {
      if (!v.isStudio) continue;
      if (best == null) {
        best = v;
        continue;
      }
      final vd = v.durationS;
      final e = data.expectedDur;
      if (e != null && vd != null) {
        if (best.durationS == null ||
            (vd - e).abs() < (best.durationS! - e).abs())
          best = v;
      } else if (vd != null && best.durationS == null) {
        best = v;
      }
    }
    return FractionallySizedBox(
      heightFactor: 0.85,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.baseName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                if (data.reason.isNotEmpty)
                  Text(
                    data.reason,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                const SizedBox(height: 6),
                if (spotify != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Spots.green.withOpacity(.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Spots.green.withOpacity(.4)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.music_note, color: Spots.green, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Spotify reference: ${spotify.name}'
                            ' · ${spotify.artists.join(', ')}'
                            '${spotify.durationS != null ? ' · ${fmtClock(spotify.durationS!)}' : ''}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (nasRow.isNotEmpty) _nasSection(nasRow.first),
                if (candidates.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text(
                        tr('No other versions found for this track.'),
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          candidates.length == 1
                              ? tr('1 version to replace with')
                              : '${candidates.length} '
                                    '${tr('versions to replace with')}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                      FilterChip(
                        selected: _studioOnly,
                        showCheckmark: false,
                        avatar: Icon(
                          _studioOnly
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          size: 16,
                          color: _studioOnly
                              ? Colors.black
                              : Colors.white54,
                        ),
                        label: Text(tr('Studio originals only')),
                        onSelected: (_) =>
                            setState(() => _studioOnly = !_studioOnly),
                      ),
                    ],
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 190),
                      itemCount: candidates.length,
                      itemBuilder: (_, i) {
                        final v = candidates[i];
                        return _versionTile(
                          v,
                          data,
                          isBest: identical(v, best),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (_previewVersion != null)
            Align(alignment: Alignment.bottomCenter, child: _controlsPanel()),
        ],
      ),
    );
  }

  Widget _nasSection(SongVersion nas) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Spots.green.withOpacity(.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Spots.green.withOpacity(.35)),
      ),
      child: Row(
        children: [
          Icon(
            _previewVersion == nas ? Icons.headphones : Icons.cloud_done,
            color: Spots.green,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'You own this on the NAS',
                  style: TextStyle(fontSize: 11, color: Spots.green),
                ),
                Text(
                  nas.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: Colors.white),
                ),
                if (nas.durationS != null)
                  Text(
                    '${fmtClock(nas.durationS!)} · On NAS',
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip:
                _previewVersion == nas && (_previewPlaying || _loadingPreview)
                ? 'Stop'
                : 'Play this song',
            icon: Icon(
              _previewVersion == nas && _previewPlaying
                  ? Icons.pause_circle
                  : _previewVersion == nas && _loadingPreview
                  ? Icons.hourglass_top
                  : Icons.play_circle,
              size: 36,
              color: Spots.green,
            ),
            onPressed: () =>
                _previewVersion == nas && (_previewPlaying || _loadingPreview)
                ? _stopPreview()
                : _startPreview(nas),
          ),
        ],
      ),
    );
  }

  Widget _controlsPanel() {
    final v = _previewVersion!;
    final playing = _previewPlaying;
    final totalMs = _previewDur.inMilliseconds;
    final posMs = _previewPos.inMilliseconds.clamp(
      0,
      totalMs > 0 ? totalMs : 0,
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: const Color(0xF21E1C1C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CoverThumb(
                title: '${v.artist} - ${v.name}',
                thumbUrl: v.albumImage.isEmpty ? null : v.albumImage,
                size: 40,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      v.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      '${v.artist} · ${_sourceLabel(v)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),
              if (_loadingPreview)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          Row(
            children: [
              Text(
                fmtClock(Duration(milliseconds: posMs.toInt()).inSeconds),
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
              Expanded(
                child: Slider(
                  value: totalMs > 0 ? posMs.toDouble() : 0,
                  max: totalMs > 0 ? totalMs.toDouble() : 1,
                  activeColor: Spots.green,
                  inactiveColor: Colors.white24,
                  onChangeStart: (_) {},
                  onChanged: totalMs > 0
                      ? (d) => _seekPreview(Duration(milliseconds: d.round()))
                      : null,
                ),
              ),
              Text(
                fmtClock(_previewDur.inSeconds),
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: _showLyrics ? 'Hide lyrics' : 'Show lyrics',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  _showLyrics ? Icons.lyrics : Icons.lyrics_outlined,
                  color: _showLyrics ? Spots.green : Colors.white70,
                ),
                onPressed: _toggleLyrics,
              ),
              const SizedBox(width: 16),
              IconButton(
                tooltip: playing ? 'Pause' : 'Play',
                icon: Icon(
                  playing ? Icons.pause_circle : Icons.play_circle,
                  size: 52,
                  color: Spots.green,
                ),
                onPressed: playing ? _pausePreview : _resumePreview,
              ),
              const SizedBox(width: 16),
              IconButton(
                tooltip: tr('Stop'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 24),
                onPressed: _stopPreview,
              ),
            ],
          ),
          if (_showLyrics) _lyricsPanel(),
        ],
      ),
    );
  }

  Widget _lyricsPanel() {
    if (_loadingLyrics) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final l = _previewLyrics;
    if (l == null || !l.found) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No lyrics found.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      );
    }
    final lines = l.isSynced ? l.synced.map((e) => e.text).toList() : l.plain;
    return Container(
      constraints: const BoxConstraints(maxHeight: 160),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final ln in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                ln,
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
            ),
        ],
      ),
    );
  }

  Widget _versionTile(SongVersion v, SongVersions data, {bool isBest = false}) {
    final typeColor = v.isStudio ? Spots.green : Colors.white54;
    return Card(
      elevation: 0,
      color: Colors.white.withOpacity(0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isBest ? Spots.green.withOpacity(.5) : Colors.white10,
        ),
      ),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 40,
          height: 40,
          child: v.albumImage.isNotEmpty
              ? Image.network(
                  v.albumImage,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _coverFallback(v),
                )
              : _coverFallback(v),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              v.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: v.isStudio ? Colors.white : Colors.white70,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (isBest)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Spots.green,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                tr('BEST MATCH'),
                style: TextStyle(
                    fontSize: 9,
                    color: Colors.black,
                    fontWeight: FontWeight.w800),
              ),
            ),
          if (v.explicit)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.explicit, size: 14, color: Colors.white38),
            ),
        ],
      ),
      subtitle: Text(
        '${v.artist}${v.album.isNotEmpty ? ' · ${v.album}' : ''}'
        '${v.durationS != null ? ' · ${fmtClock(v.durationS!)}' : ''}'
        ' · ${tr(_typeLabel(v.type))}'
        ' · ${tr(_sourceLabel(v))}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: typeColor),
      ),
      isThreeLine: false,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: tr('Preview'),
            visualDensity: VisualDensity.compact,
            icon: Icon(
              _previewVersion == v && _previewPlaying
                  ? Icons.pause_circle_outline
                  : _previewVersion == v && _loadingPreview
                  ? Icons.hourglass_top
                  : Icons.play_circle_outline,
              size: 20,
              color: Spots.green,
            ),
            onPressed: () => _startPreview(v),
          ),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => widget.onReplace(v),
            icon: const Icon(Icons.download, size: 16),
            label: Text(tr('Replace')),
          ),
        ],
      ),
      ),
    );
  }

  String _sourceLabel(SongVersion v) {
    switch (v.source) {
      case 'nas':
        return 'On NAS';
      case 'deezer':
        return 'Deezer';
      default:
        return v.source;
    }
  }

  Widget _coverFallback(SongVersion v) => Container(
    width: 40,
    height: 40,
    color: Colors.white12,
    alignment: Alignment.center,
    child: const Icon(Icons.music_note, size: 18, color: Colors.white38),
  );

  String _typeLabel(String t) {
    switch (t) {
      case 'studio':
        return 'studio';
      case 'live':
        return 'live';
      case 'remix':
        return 'remix';
      case 'acoustic':
        return 'acoustic';
      case 'instrumental':
        return 'instrumental';
      case 'clean':
        return 'clean/censored';
      default:
        return 'alternate';
    }
  }
}
