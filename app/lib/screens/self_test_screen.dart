import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_client.dart';
import '../audio_session_state.dart';
import '../lang.dart';
import '../offline_store.dart';
import '../prefetch_store.dart';
import '../queue_player.dart';
import '../theme.dart';
import '../toast.dart';

/// A candidate song to run the playback-health test on.
class _TestTarget {
  final String label;
  final String url;
  final bool browse;
  final String? playlist;
  const _TestTarget({
    required this.label,
    this.url = '',
    this.browse = false,
    this.playlist,
  });
}

/// Results of one self-test step.
class SelfTestResult {
  final String name;
  final String status; // ok / fail / warn / info / skip
  final String detail;
  const SelfTestResult(this.name, this.status, this.detail);
}

/// A button in Settings that runs a battery of on-device checks against the
/// live server + local player. Purpose: surface the "can't fix blind" bugs
/// (songs cutting short, background audio, playlist latency, missing art) as
/// concrete, readable results the user can act on or hand back.
class SelfTestScreen extends StatefulWidget {
  const SelfTestScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<SelfTestScreen> createState() => _SelfTestScreenState();
}

class _SelfTestScreenState extends State<SelfTestScreen> {
  List<SelfTestResult> _results = [];
  bool _running = false;
  bool _playingTest = false;
  bool _testEverStarted = false;
  AudioPlayer? _testPlayer;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<void>? _completeSub;
  StreamSubscription<String>? _logSub;
  bool _sawPlaying = false;
  String? _sampleEnd;
  final _pos = ValueNotifier<Duration>(Duration.zero);
  final _dur = ValueNotifier<Duration>(Duration.zero);
  String? _liveSample;

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _completeSub?.cancel();
    _logSub?.cancel();
    _pos.dispose();
    _dur.dispose();
    super.dispose();
  }

  void _add(String name, String status, String detail) {
    if (mounted)
      setState(() => _results.add(SelfTestResult(name, status, detail)));
  }

  Color _statusColor(String s) => switch (s) {
    'ok' => Spots.green,
    'warn' => Colors.orangeAccent,
    'fail' => Colors.redAccent,
    _ => Colors.white54,
  };

  /// Poll our own [audioSessionReady] flag (set right after [AudioService.init]
  /// returns). We deliberately avoid `AudioService.running`/`runningStream`,
  /// which are broken in audio_service 0.18.19 + rxdart 0.28 (the deprecated
  /// compat getters cast a non-ValueStream `_MapStream` and throw).
  Future<bool> _sessionUp() async {
    for (var i = 0; i < 100; i++) {
      if (audioSessionReady.value) return true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return audioSessionReady.value;
  }

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _results = [];
    });

    // 1. Server reachability + playlist latency (J).
    await _testServer();

    // 2. Audio service / media session status (I).
    await _testAudioService();

    // 3. A chosen artist's photo resolves (F).
    await _testArtistPhoto();

    // 4. Look-ahead cache: prefetch rows + next-10 coverage.
    await _testCache();

    // 5. Error pipeline: sentinel playback row written + read back.
    await _testErrorPipeline();

    // 4. Playback health: play a picked song and watch for early stop (H).
    _results.add(
      const SelfTestResult(
        'Playback health',
        'info',
        'Press "Play test song" — pick a queue item or a playlist song. As it '
            'plays we report buffering + any early stop; tap "It cut here" if '
            'it ends before the track really ends.',
      ),
    );

    if (mounted) setState(() => _running = false);
  }

  Future<void> _testServer() async {
    final sw = Stopwatch()..start();
    try {
      final pls = await widget.api.playlists();
      sw.stop();
      final ms = sw.elapsedMilliseconds;
      _add(
        'Server / playlists',
        ms < 1500 ? 'ok' : 'warn',
        '${pls.length} playlists in ${ms}ms '
            '${ms >= 1500 ? '(slow — playlists disappear issue)' : ''}',
      );
    } catch (e) {
      _add('Server / playlists', 'fail', 'Error: $e');
    }
  }

  Future<void> _testAudioService() async {
    if (!_isMobile) {
      _add(
        'Background audio (media session)',
        'skip',
        'Mobile-only (no audio_service on Linux desktop).',
      );
      return;
    }
    try {
      final up = await _sessionUp();
      _add(
        'Background audio (media session)',
        up ? 'ok' : 'warn',
        up
            ? 'AudioService initialized; the notification/lock-screen '
                  'session should be available. Verify the notification shows '
                  'while this screen is open.'
            : 'AudioService is NOT initialized — background / lock-screen '
                  'playback is off. This explains item I.',
      );
    } catch (e) {
      _add('Background audio (media session)', 'fail', 'Error: $e');
    }
  }

  Future<void> _testArtistPhoto() async {
    // Probe a couple of known artists that have been problematic (F).
    const probes = ['D12', 'Eminem'];
    for (final name in probes) {
      try {
        final p = await widget.api.artistPhoto(name);
        _add(
          'Artist photo: $name',
          (p == null || p.isEmpty) ? 'warn' : 'ok',
          (p == null || p.isEmpty)
              ? 'No photo resolved for "$name".'
              : 'Photo resolved (${p.length}s URL).',
        );
      } catch (e) {
        _add('Artist photo: $name', 'fail', 'Error: $e');
      }
    }
  }

  /// Look-ahead cache self-test: stored prefetch rows + coverage of the
  /// next-10 window (phone downloads count as covered).
  Future<void> _testCache() async {
    try {
      final qp = QueuePlayer.instance;
      final idx = qp.index < 0 ? 0 : qp.index;
      final win =
          PrefetchStore.window(qp.items, idx + 1, PrefetchStore.aheadCount);
      var covered = 0;
      for (final it in win) {
        if (OfflineStore.isDownloaded(it.title, it.baseName)) {
          covered++;
        } else if (await PrefetchStore.fileFor(it.title, it.baseName) !=
            null) {
          covered++;
        }
      }
      final rows = PrefetchStore.count;
      final size = OfflineStore.fmtBytes(PrefetchStore.bytesUsed);
      if (win.isEmpty) {
        _add('Look-ahead cache', 'info',
            '$rows prefetch rows ($size). Queue is empty — nothing to cover.');
        return;
      }
      _add(
        'Look-ahead cache',
        covered == win.length ? 'ok' : 'warn',
        '$rows prefetch rows ($size); $covered/${win.length} upcoming songs '
        'cached${covered < win.length ? ' — let it play online to fill' : ''}.',
      );
    } catch (e) {
      _add('Look-ahead cache', 'fail', 'Error: $e');
    }
  }

  Future<void> _testErrorPipeline() async {
    try {
      final ok = await widget.api.verifyLogPipeline();
      _add('Error pipeline', ok ? 'ok' : 'fail',
          ok ? 'Sentinel playback row written + read back from user-errors.'
              : 'Sentinel row not found — offline queue or client-log broken.');
    } catch (e) {
      _add('Error pipeline', 'fail', 'Error: $e');
    }
  }

  // --- Playback health (H): pick a song, then watch for premature stop. ---
  Future<void> _onTestButton() async {
    if (_playingTest) {
      _stopTestPlayer(_testPlayer);
      return;
    }
    final qp = QueuePlayer.instance;
    if (qp.items.isNotEmpty) {
      final target = await _pickQueueTarget();
      if (target == null) return;
      await _playTest(target.url, target.label);
    } else {
      await _pickPlaylistTarget();
    }
  }

  Future<_TestTarget?> _pickQueueTarget() async {
    final qp = QueuePlayer.instance;
    final items = List<QueueItem>.of(qp.items);
    final cur = qp.index;
    final indexed = <({int i, QueueItem it})>[];
    if (cur >= 0 && cur < items.length) {
      indexed.add((i: cur, it: items[cur]));
    }
    for (var i = 0; i < items.length; i++) {
      if (i == cur) continue;
      indexed.add((i: i, it: items[i]));
    }
    final shown = indexed.take(15).toList();
    return showModalBottomSheet<_TestTarget>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                tr('Pick a song to test'),
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            ...shown.map(
              (e) => ListTile(
                dense: true,
                leading: Icon(
                  e.i == cur ? Icons.play_circle : Icons.music_note,
                  color: e.i == cur ? Spots.green : null,
                ),
                title: Text(
                  e.it.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  e.i == cur ? 'Now playing' : 'Queue position ${e.i + 1}',
                ),
                onTap: () => Navigator.pop(
                  ctx,
                  _TestTarget(label: e.it.title, url: e.it.url),
                ),
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(tr('Browse playlists instead…')),
              onTap: () => Navigator.pop(
                ctx,
                const _TestTarget(browse: true, label: ''),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickPlaylistTarget() async {
    List<PlaylistInfo> pls;
    try {
      pls = await widget.api.playlists();
    } catch (e) {
      if (mounted) {
        toast(
          context,
          "${tr('Could not load playlists')}: $e",
          icon: Icons.error_outline,
        );
      }
      return;
    }
    if (!mounted) return;
    if (pls.isEmpty) {
      _add(
        'Playback health',
        'fail',
        'Queue is empty and no playlists exist — nothing to play.',
      );
      return;
    }
    final pick = await showModalBottomSheet<_TestTarget>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                tr('Queue is empty — pick a playlist'),
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            ...pls.map(
              (p) => ListTile(
                dense: true,
                leading: const Icon(Icons.queue_music),
                title: Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(tr('Tap to test its first song')),
                onTap: () => Navigator.pop(
                  ctx,
                  _TestTarget(label: '', browse: false, playlist: p.name),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (pick == null || pick.playlist == null) return;
    if (!mounted) return;
    try {
      final detail = await widget.api.playlistEntries(pick.playlist!);
      PlaylistEntry? entry;
      for (final e in detail.entries) {
        if (e.exists && (e.url?.isNotEmpty ?? false)) {
          entry = e;
          break;
        }
      }
      if (entry == null || entry.url == null || entry.url!.isEmpty) {
        _add(
          'Playback health',
          'fail',
          'Playlist "${pick.playlist}" has no playable NAS file.',
        );
        return;
      }
      await _playTest(
        widget.api.fileUrl(entry.url!),
        '${pick.playlist} — ${entry.baseName}',
      );
    } catch (e) {
      _add('Playback health', 'fail', 'Could not load playlist: $e');
    }
  }

  Future<void> _playTest(String url, String label) async {
    if (_playingTest) return;
    setState(() {
      _playingTest = true;
      _testEverStarted = true;
      _sawPlaying = false;
      _liveSample = 'Listening to: $label';
      _sampleEnd = null;
    });
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _completeSub?.cancel();
    _logSub?.cancel();
    final player = AudioPlayer();
    _testPlayer = player;
    _pos.value = Duration.zero;
    _dur.value = Duration.zero;
    _posSub = player.onPositionChanged.listen((d) => _pos.value = d);
    _durSub = player.onDurationChanged.listen((d) => _dur.value = d);
    _completeSub = player.onPlayerComplete.listen((_) {
      _add(
        'Playback health',
        'info',
        'Completed event fired at '
            '${_fmt(_pos.value)} / ${_fmt(_dur.value)}.',
      );
    });
    _stateSub = player.onPlayerStateChanged.listen((s) {
      if (s == PlayerState.playing && !_sawPlaying) {
        _sawPlaying = true;
        _add(
          'Playback health',
          'ok',
          '"$label" started playing (buffered fine). Watch it to the end — '
              'if it stops before ${_fmt(_dur.value)} that is bug H.',
        );
      } else if (s == PlayerState.completed) {
        final pos = _pos.value;
        final dur = _dur.value;
        final early =
            dur > Duration.zero && pos < dur - const Duration(seconds: 3);
        if (early) {
          _add(
            'Playback health',
            'fail',
            'STOPPED EARLY at ${_fmt(pos)} / ${_fmt(dur)} while "$label" was '
                'still playing. If "Song ended" shows before the real end, '
                'this is the stream cut-short bug (H).',
          );
        } else if (dur > Duration.zero) {
          _add(
            'Playback health',
            'ok',
            'Reached the natural end at ${_fmt(pos)} / ${_fmt(dur)} '
                '("$label"). Full-length playback confirmed.',
          );
        } else {
          _add(
            'Playback health',
            'warn',
            'Player reported completion ("$label") but no duration loaded — '
                'could not verify it was the real end.',
          );
        }
        _sampleEnd = 'Stopped at ${_fmt(pos)} / ${_fmt(dur)}';
        _stopTestPlayer(player);
      }
    });
    _logSub = player.onLog.listen((line) {
      final l = line.toLowerCase();
      if (l.contains('buffer')) {
        _add(
          'Buffering',
          'info',
          '"$label" buffering: $line (pos ${_fmt(_pos.value)}).',
        );
      } else if (l.contains('error')
      // Android MediaPlayer logs error codes like E/MediaPlayer(1234).
      ) {
        _add('Playback health', 'warn', 'Player log error on "$label": $line');
      }
    });
    try {
      await player.play(UrlSource(url));
    } catch (e) {
      _add('Playback health', 'fail', 'Could not start test playback: $e');
      _stopTestPlayer(player);
    }
  }

  /// Manual "the song cut right here" report (H): logs the exact stop point
  /// even when the player never emitted a completed event.
  void _reportCut() {
    final pos = _pos.value;
    final dur = _dur.value;
    final stateDesc = switch (_testPlayer?.state) {
      PlayerState.playing => 'still playing',
      PlayerState.paused => 'paused',
      PlayerState.completed => 'completed',
      _ => _sampleEnd ?? 'stopped',
    };
    _add(
      'Playback health',
      'warn',
      'USER: "it cut here" at ${_fmt(pos)} / ${_fmt(dur)} (player: $stateDesc). '
          'If the real track is longer, this is bug H.',
    );
  }

  void _stopTestPlayer(AudioPlayer? p) {
    _playingTest = false;
    _posSub?.cancel();
    _posSub = null;
    _durSub?.cancel();
    _durSub = null;
    _stateSub?.cancel();
    _stateSub = null;
    _completeSub?.cancel();
    _completeSub = null;
    _logSub?.cancel();
    _logSub = null;
    if (p != null) {
      p.stop();
      p.dispose();
    }
    _testPlayer = null;
    if (mounted) setState(() {});
  }

  Future<void> _copyResults() async {
    final buf = StringBuffer()
      ..writeln('gungan.fm device self-test')
      ..writeln('Time: ${DateTime.now().toIso8601String()}')
      ..writeln(
        'Platform: ${defaultTargetPlatform.name}'
        '${kIsWeb ? ' (web)' : ''}',
      )
      ..writeln('Server: ${widget.api.baseUrl}');
    if (_results.isEmpty) {
      buf.writeln('(no results yet — run the self-test first)');
    }
    for (final r in _results) {
      buf.writeln('');
      buf.writeln('[${r.status.toUpperCase()}] ${r.name}');
      buf.writeln('   ${r.detail}');
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (mounted) {
      toast(context, tr('Results copied to clipboard'), icon: Icons.copy_all);
    }
  }

  String _fmt(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Device self-test')),
        actions: [
          IconButton(
            tooltip: tr('Copy results'),
            onPressed: _copyResults,
            icon: const Icon(Icons.copy_all),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            tr('Runs local + server checks to pin down bugs we can\'t see from '
            'here: songs cutting short, background audio, playlist latency, '
            'missing artist art. Copy results with the top-right icon.'),
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(tr('Run self-test')),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _onTestButton,
            icon: _playingTest
                ? const Icon(Icons.stop)
                : const Icon(Icons.music_note),
            label: Text(_playingTest ? 'Stop test song' : 'Play test song'),
          ),
          if (_testEverStarted) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _reportCut,
              icon: const Icon(Icons.content_cut, size: 18),
              label: Text(tr('It cut here (report early stop)')),
            ),
          ],
          if (_liveSample != null) ...[
            const SizedBox(height: 4),
            Text(
              _liveSample!,
              style: TextStyle(color: Spots.green, fontSize: 13),
            ),
            const SizedBox(height: 4),
            ValueListenableBuilder<Duration>(
              valueListenable: _pos,
              builder: (_, pos, _) => ValueListenableBuilder<Duration>(
                valueListenable: _dur,
                builder: (_, dur, _) => Text(
                  '${_fmt(pos)} / ${_fmt(dur)}',
                  style: const TextStyle(color: Colors.white54),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          for (final r in _results)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.circle,
                color: _statusColor(r.status),
                size: 12,
              ),
              title: Text(
                r.name,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                r.detail,
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ),
        ],
      ),
    );
  }
}
