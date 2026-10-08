import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_client.dart';
import '../announcer.dart';
import '../auth_store.dart';
import '../debug_overlay.dart';
import '../diag_log.dart';
import '../import_sheet.dart';
import '../lang.dart';
import '../offline_store.dart';
import '../prefetch_store.dart';
import '../queue_player.dart';
import '../replace_tracker.dart';
import '../song_context.dart';
import '../theme.dart';
import '../toast.dart';
import '../version_sheet.dart';
import '../widgets.dart';
import 'player_layout_screen.dart';
import 'self_test_screen.dart';
import 'user_errors_screen.dart';

/// Push the settings page from any tab's app bar.
Future<void> openSettings(
  BuildContext context, {
  required ApiClient api,
  required Future<String?> Function() onServer,
}) async {
  // Preload persisted UI state BEFORE the route builds: every section
  // card + the dev toggle used to fetch prefs in initState and setState
  // after first layout, yanking content extents mid-scroll (the
  // "scroll jumps back to the bottom" bug in Diagnostics).
  bool showDev = false;
  final openSections = <String, bool>{};
  try {
    final prefs = await SharedPreferences.getInstance();
    showDev = prefs.getBool('show_dev_tools') ?? false;
    for (final t in _sectionTitles) {
      final v = prefs.getBool('sec.open.$t');
      if (v != null) openSections[t] = v;
    }
  } catch (_) {}
  if (!context.mounted) return;
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => SettingsScreen(
        api: api,
        baseUrl: api.baseUrl,
        onServer: onServer,
        initialShowDev: showDev,
        initialOpenSections: openSections,
      ),
    ),
  );
}

/// Section titles in display order (must match the _sectionCard calls).
const _sectionTitles = [
  'Appearance',
  'Connection',
  'Account',
  'Deep links',
  'Integrity',
  'Diagnostics',
  'Phone storage',
  'Import music',
];

/// Settings page. Hosts the "Server address" (change server) setting that
/// previously lived as a standalone affordance on the Discover app bar, plus
/// the song-integrity checker ("Check songs").
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.api,
    required this.baseUrl,
    required this.onServer,
    this.initialShowDev = false,
    this.initialOpenSections = const {},
  });
  final ApiClient api;
  final String baseUrl;
  final Future<String?> Function() onServer;

  /// Prefetched UI state (see openSettings): avoids post-layout
  /// setState churn that yanks scroll extents mid-gesture.
  final bool initialShowDev;
  final Map<String, bool> initialOpenSections;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late String _baseUrl = widget.baseUrl;
  CheckSongsStatus? _check;
  bool _checking = false;
  bool _loggingOut = false;
  late bool _showDev = widget.initialShowDev;
  String? _checkError;
  Timer? _poll;
  int _filter = 0;
  final Set<String> _replacing = {};
  String _songQuery = '';
  String _lyricQuery = '';

  // Per-user error count badge for Settings "User errors" tile
  final ValueNotifier<int> _userErrorCount = ValueNotifier(0);

  // Checker scope: 0 = whole library, 1 = one playlist, 2 = one song.
  int _scopeMode = 0;
  String _scopePlaylist = '';
  String _scopeSong = '';
  List<String> _playlistNames = [];
  final TextEditingController _scopeSongCtrl = TextEditingController();

  String? _currentScope() {
    switch (_scopeMode) {
      case 1:
        return _scopePlaylist.isNotEmpty
            ? 'playlist:$_scopePlaylist'
            : null;
      case 2:
        return _scopeSong.trim().isNotEmpty
            ? 'song:${_scopeSong.trim()}'
            : null;
      default:
        return null;
    }
  }

  String _scopeModeLabel() => switch (_scopeMode) {
        1 => _scopePlaylist.isNotEmpty
            ? "${tr('playlist')} \"$_scopePlaylist\""
            : tr('a playlist'),
        2 => _scopeSong.trim().isNotEmpty
            ? "${tr('song')} \"${_scopeSong.trim()}\""
            : tr('a song'),
        _ => tr('whole library'),
      };

  Future<void> _loadScopePlaylists() async {
    try {
      final pls = await widget.api.playlists();
      if (!mounted) return;
      setState(() {
        _playlistNames = pls.map((p) => p.name).toList();
        if (_scopePlaylist.isEmpty && _playlistNames.isNotEmpty) {
          _scopePlaylist = _playlistNames.first;
        }
      });
    } catch (_) {}
  }

  Future<void> _changeServer() async {
    final newUrl = await widget.onServer();
    if (newUrl != null && mounted) {
      setState(() => _baseUrl = newUrl);
    }
  }

  /// Sign out this device: revoke the session token server-side, drop the
  /// local session, and pop back to the login screen (the gate rebuilds
  /// behind, but this Settings page would otherwise sit open on top).
  Future<void> _logout() async {
    if (_loggingOut) return;
    setState(() => _loggingOut = true);
    try {
      await widget.api.logout();
    } catch (_) {
      // best-effort: the local session is dropped regardless
    }
    widget.api.authToken = null;
    await AuthStore.instance.expire();
    if (mounted) {
      setState(() => _loggingOut = false);
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  /// Jump to Android's "Open supported links" page for this app so the user can
  /// make Spotify / YT-Music links open here by default — no manual reaching
  /// through Settings > Apps.
  Future<void> _openSupportedLinks() async {
    const channel = MethodChannel('com.nasmusic.nasmusic/system');
    try {
      final ok = await channel.invokeMethod<bool>('openSupportedLinks');
      if (!mounted) return;
      if (ok != true) {
        toast(context, tr('Could not open the links settings page.'),
            icon: Icons.info_outline);
      }
    } catch (e) {
      debugPrint('[_openSupportedLinks] FAILED: $e');
      if (mounted) {
        toast(context, "${tr('Could not open the links settings page')}: $e",
            icon: Icons.error_outline);
      }
    }
  }

  Future<void> _startCheck() async {
    setState(() {
      _checking = true;
      _checkError = null;
    });
    _poll?.cancel();
    final scope = _currentScope();
    try {
      final first = await widget.api.checkSongs(scope: scope);
      if (!mounted) return;
      setState(() {
        _check = first;
        _checking = false;
      });
      if (first.running || !first.done) _startPolling(scope);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _checkError = e.toString();
      });
    }
  }

  void _startPolling([String? scope]) {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final s = await widget.api.checkSongs(scope: scope, poll: true);
        if (!mounted) return;
        // Skip no-change ticks: rebuilding hundreds of report tiles
        // every 2s freezes scrolling (worst at the bottom).
        final cur = _check;
        if (cur != null &&
            cur.reports.length == s.reports.length &&
            cur.done == s.done &&
            cur.running == s.running &&
            cur.scanned == s.scanned) {
          if (!s.running && s.done) _poll?.cancel();
          return;
        }
        setState(() => _check = s);
        if (!s.running && s.done) _poll?.cancel();
      } catch (_) {
        _poll?.cancel();
      }
    });
  }

  LyricsStatus? _lyrics;
  bool _lyricsChecking = false;
  String? _lyricsError;
  Timer? _lyricsPoll;
  int _lyricsFilter = 0;

  Future<void> _startLyricsCheck() async {
    setState(() {
      _lyricsChecking = true;
      _lyricsError = null;
    });
    _lyricsPoll?.cancel();
    final scope = _currentScope();
    try {
      final first = await widget.api.checkLyrics(scope: scope);
      if (!mounted) return;
      setState(() {
        _lyrics = first;
        _lyricsChecking = false;
      });
      if (first.running || !first.done) _startLyricsPolling(scope);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lyricsChecking = false;
        _lyricsError = e.toString();
      });
    }
  }

  void _startLyricsPolling([String? scope]) {
    _lyricsPoll?.cancel();
    _lyricsPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final s = await widget.api.checkLyrics(scope: scope, poll: true);
        if (!mounted) return;
        // Skip no-change ticks (same scroll-freeze reason as above).
        final cur = _lyrics;
        if (cur != null &&
            cur.reports.length == s.reports.length &&
            cur.done == s.done &&
            cur.running == s.running &&
            cur.scanned == s.scanned) {
          if (!s.running && s.done) _lyricsPoll?.cancel();
          return;
        }
        setState(() => _lyrics = s);
        if (!s.running && s.done) _lyricsPoll?.cancel();
      } catch (_) {
        _lyricsPoll?.cancel();
      }
    });
  }

  List<LyricsReport> _filteredLyrics(LyricsStatus l) {
    final problems = l.reports.where((r) => r.isProblem);
    List<LyricsReport> base;
    switch (_lyricsFilter) {
      case 1:
        base = problems.where((r) => r.status == 'none').toList();
        break;
      case 2:
        base = problems.where((r) => r.status == 'mismatch').toList();
        break;
      case 3:
        base = problems.where((r) => r.status == 'error').toList();
        break;
      default:
        // Only problems — good/ok lyrics are meaningless to "fix", so they are
        // never listed here.
        base = problems.toList();
    }
    return _filterByQueryLyrics(base);
  }

  /// Narrow the problem list by the lyric checker's search box (matches
  /// song/artist, case-insensitive).
  List<LyricsReport> _filterByQueryLyrics(List<LyricsReport> base) {
    final q = _lyricQuery.trim().toLowerCase();
    if (q.isEmpty) return base;
    return base.where((r) {
      final hay = '${r.baseName} ${r.theirArtist ?? ''}'.toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _scopeSongCtrl.addListener(() {
      if (mounted) setState(() => _scopeSong = _scopeSongCtrl.text);
    });
    _loadScopePlaylists();
    // NOTE: _showDev + section open-states arrive preloaded via
    // openSettings (widget.initial*) — no post-mount prefs setState here
    // (that extent churn mid-scroll was the reset-to-bottom bug).

    // Flush offline-queued client logs first: cached screens make no API
    // calls, so without this the queue never leaves the phone.
    widget.api.flushQueuedLogs().whenComplete(_refreshUserErrorCount);
  }

  Future<void> _refreshUserErrorCount() async {
    if (!AuthStore.instance.isOwner || !_showDev) return;
    try {
      final j = await widget.api.userErrors(limit: 500, unseen: true);
      final rows = (j['errors'] as List?) ?? [];
      int count = 0;
      for (final r in rows) {
        final user = (r['username'] as String? ?? '');
        if (user.isNotEmpty) {
          count++;
        }
      }
      if (mounted) _userErrorCount.value = count;
    } catch (_) {}
  }

  @override
  void dispose() {
    _poll?.cancel();
    _lyricsPoll?.cancel();
    _scopeSongCtrl.dispose();
    super.dispose();
  }

  Widget _statusLabel(CheckSongReport r, [CheckSongReport? _]) {
    final act = r.actualDur, exp = r.expectedDur;
    if (r.mismatch && (r.realTitle?.isNotEmpty ?? false)) {
      final real =
          '${r.realArtist?.isNotEmpty == true ? '${r.realArtist} - ' : ''}${r.realTitle}';
      return Text(
        tr('Filename may be WRONG — audio is actually ') + '"$real"',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.deepOrangeAccent, fontSize: 12),
      );
    }
    String reason;
    switch (r.status) {
      case 'too_short':
        reason = act != null && exp != null
            ? "${tr('Shorter than studio')} (${fmtClock(act.round())} vs "
                  '${fmtClock(exp.round())}) ${tr('— likely censored / cut')}'
            : tr('Too short — possibly censored / cut');
        return Text(
          reason,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.redAccent, fontSize: 12),
        );
      case 'too_long':
        reason = act != null && exp != null
            ? "${tr('Longer than studio')} (${fmtClock(act.round())} vs "
                  '${fmtClock(exp.round())}) ${tr('— maybe live / remix / extended')}'
            : tr('Too long — maybe live / remix / extended');
        return Text(
          reason,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
        );
      case 'no_ref':
      case 'unverified':
        return Text(
          tr('No studio reference — identity unverified, check manually'),
          style: TextStyle(color: Colors.white54, fontSize: 12),
        );
      case 'needs_explicit_check':
        return Text(
          tr('Clean/explicit versions exist — listen to confirm yours'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Colors.amberAccent, fontSize: 12),
        );
      default:
        return Text(
          tr('OK · matches studio'),
          style: TextStyle(color: Colors.greenAccent, fontSize: 12),
        );
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'ok':
        return Icons.check_circle;
      case 'too_short':
        return Icons.block;
      case 'too_long':
        return Icons.timer;
      case 'needs_explicit_check':
        return Icons.explicit;
      default:
        return Icons.help_outline;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'ok':
        return Colors.greenAccent;
      case 'too_short':
        return Colors.redAccent;
      case 'too_long':
        return Colors.orangeAccent;
      case 'needs_explicit_check':
        return Colors.amberAccent;
      default:
        return Colors.white54;
    }
  }

  /// One settings group as a small expandable card window (no bare
  /// headers). Open state persists per section.
  Widget _sectionCard(String title, List<Widget> children) => _SectionCard(
        key: ValueKey('sec-$title'),
        title: title,
        initialOpen: widget.initialOpenSections[title] ?? true,
        children: children,
      );

  @override
  Widget build(BuildContext context) {
    final check = _check;
    final okCount = check == null
        ? 0
        : check.reports.where((r) => r.status == 'ok').length;
    final problemCount = check == null
        ? 0
        : check.reports.where((r) => r.isProblem).length;
    final showing = check == null
        ? 0
        : check.total > 0
        ? check.scanned
        : check.reports.length;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Settings'))),
      body: ListTileTheme(
        // NOTE: not const — Spots.green resolves per theme preset.
        data: ListTileThemeData(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          iconColor: Spots.green,
          textColor: Colors.white,
          titleTextStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            height: 1.25,
          ),
          subtitleTextStyle: const TextStyle(
            fontSize: 12.5,
            color: Colors.white54,
          ),
          dense: true,
        ),
        child: ListView(
          padding:
              const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        children: [
          _sectionCard(tr('Appearance'), [
          ListenableBuilder(
            listenable: ThemeStore.instance,
            builder: (_, __) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "${tr('Theme')}: ${ThemeStore.instance.current.name}",
                    style: const TextStyle(
                        fontSize: 13, color: Colors.white70),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final t in AppThemes.all)
                          Padding(
                            padding:
                                const EdgeInsets.only(right: 10),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () =>
                                  ThemeStore.instance.set(t.id),
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: t.accent,
                                  border: Border.all(
                                    color: t.id ==
                                            ThemeStore.instance.current.id
                                        ? Colors.white
                                        : Colors.transparent,
                                    width: 2.5,
                                  ),
                                ),
                              ),
                            ),
                              ),
                            ],
                          ),
                  ),
              ],
            ),
            ),
          ),
          ListenableBuilder(
            listenable: UiStore.instance,
            builder: (_, __) => ListTile(
              leading: const Icon(Icons.navigation_outlined),
              title: Text(tr('Bottom bar')),
              trailing: DropdownButton<String>(
                value: UiStore.instance.navStyle,
                dropdownColor: Spots.elevated,
                underline: const SizedBox.shrink(),
                items: [
                  for (final o in kNavStyleOptions)
                    DropdownMenuItem(
                      value: o.id,
                      child: Text(o.name,
                          style: const TextStyle(fontSize: 13)),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) UiStore.instance.setNavStyle(v);
                },
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.tune, color: Colors.white54),
            title: Text(tr('Arrange player buttons')),
            trailing:
                const Icon(Icons.chevron_right, color: Colors.white38),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const PlayerLayoutScreen()),
            ),
          ),
          ]),
          _sectionCard(tr('Connection'), [
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(tr('Server address')),
            subtitle: Text(
              _baseUrl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _changeServer,
          ),
          ]),
          _sectionCard(tr('Account'), [
          ListTile(
            leading: const Icon(Icons.person_outlined),
            title: Text(AuthStore.instance.username ?? tr('Signed in')),
            subtitle: Text(tr('Private playlists belong to this account')),
            trailing: _loggingOut
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.logout),
            onTap: _loggingOut ? null : _logout,
          ),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: Text(tr('Change password')),
            subtitle: Text(tr('Needs your current password')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _changePassword(),
          ),
          ListenableBuilder(
            listenable: LocaleStore.instance,
            builder: (_, __) => ListTile(
              leading: const Icon(Icons.language_outlined),
              title: Text(tr('Language')),
              trailing: DropdownButton<String>(
                value: LocaleStore.instance.lang,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'en', child: Text('English')),
                  DropdownMenuItem(value: 'es', child: Text('Español')),
                ],
                onChanged: (v) {
                  if (v != null) LocaleStore.instance.setLang(v);
                },
              ),
            ),
          ),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (_, snap) => ListTile(
              leading: const Icon(Icons.info_outlined),
              title: Text(tr('App version')),
              subtitle: Text(snap.hasData
                  ? 'gungan.fm ${snap.data!.version}+${snap.data!.buildNumber}'
                  : '…'),
            ),
          ),
          ]),
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            _sectionCard(tr('Deep links'), [
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(tr('Open links by default')),
              subtitle: Text(
                tr('Make Spotify and YouTube Music links open here instead of ') +
                    tr('their own apps.'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openSupportedLinks,
            ),
          ]),
          // Integrity (check songs/lyrics) is for everyone; replace and
          // diagnostics stay owner-only (server 403s + section gate).
          _sectionCard('Integrity', [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.manage_search_outlined,
                        size: 18, color: Colors.white54),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButton<int>(
                        value: _scopeMode,
                        isExpanded: true,
                        dropdownColor: Spots.elevated,
                        underline: const SizedBox.shrink(),
                        items: [
                          DropdownMenuItem<int>(
                            value: 0,
                            child: Text(tr('Whole library'),
                                style: TextStyle(color: Colors.white70, fontSize: 13)),
                          ),
                          DropdownMenuItem<int>(
                            value: 1,
                            child: Text(tr('One playlist'),
                                style: TextStyle(color: Colors.white70, fontSize: 13)),
                          ),
                          DropdownMenuItem<int>(
                            value: 2,
                            child: Text(tr('One song…'),
                                style: TextStyle(color: Colors.white70, fontSize: 13)),
                          ),
                        ],
                        onChanged: (v) => setState(() {
                          _scopeMode = v ?? 0;
                          if (v == 1 && _playlistNames.isEmpty) {
                            _loadScopePlaylists();
                          }
                        }),
                      ),
                    ),
                  ],
                ),
                if (_scopeMode == 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: DropdownButton<String>(
                      value: _scopePlaylist.isEmpty ? null : _scopePlaylist,
                      isExpanded: true,
                      hint: Text(tr('Pick a playlist…'),
                          style: TextStyle(color: Colors.white38, fontSize: 13)),
                      dropdownColor: Spots.elevated,
                      underline: const SizedBox.shrink(),
                      items: _playlistNames
                          .map((n) => DropdownMenuItem<String>(
                                value: n,
                                child: Text(n,
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 13)),
                              ))
                          .toList(),
                      onChanged: (v) => setState(() => _scopePlaylist = v ?? ''),
                    ),
                  ),
                if (_scopeMode == 2)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: TextField(
                      controller: _scopeSongCtrl,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: tr('Song name to check…'),
                        hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.verified_outlined),
            title: Text(tr('Check songs')),
            subtitle: Text(
              tr('Verify every downloaded track against its studio original — ') +
                  tr('flags censored, cut, live or wrong versions.'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _checking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _checking ? null : _startCheck,
          ),
          if (_checkError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                "${tr('Error')}: $_checkError",
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
if (check != null && check.running)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                tr('Checking ') + '${check.scanned}/${check.total} ${tr('songs…')} '
                '(${_scopeModeLabel()})',
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ValueListenableBuilder<ReplaceState?>(
            valueListenable: ReplaceTracker.active,
            builder: (_, rs, __) {
              if (rs == null) return const SizedBox.shrink();
              final ok = rs.done && rs.success;
              final bad = rs.done && !rs.success;
              return Container(
                margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (bad ? Colors.redAccent : Spots.green).withOpacity(
                    .12,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: (bad ? Colors.redAccent : Spots.green).withOpacity(
                      .4,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    if (!rs.done)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        ok ? Icons.check_circle : Icons.error_outline,
                        size: 20,
                        color: ok ? Spots.green : Colors.redAccent,
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            rs.done && rs.success
                                ? "${tr('Replaced')} \"${rs.baseName}\""
                                : "${tr('Replacing')} \"${rs.baseName}\" — "
                                      '${rs.phase}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.white,
                            ),
                          ),
                          if (rs.detail.isNotEmpty)
                            Text(
                              rs.detail,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white54,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (rs.done)
                      IconButton(
                        tooltip: tr('Dismiss'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: ReplaceTracker.dismiss,
                      ),
                  ],
                ),
              );
            },
          ),
          if (check != null && (check.done || check.reports.isNotEmpty))
            ExpansionTile(
              initiallyExpanded: true,
              tilePadding: const EdgeInsets.symmetric(horizontal: 16),
              childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: Icon(
                _statusIcon('ok'),
                color: problemCount > 0
                    ? Colors.orangeAccent
                    : Colors.greenAccent,
              ),
              title: Text(
                check.done
                    ? '$okCount ${tr('fine')} · $problemCount ${tr('need attention')} '
                          '(${check.reports.length} ${tr('checked')})'
                    : '${check.reports.length} ${tr('checked so far')} '
                          '($showing ${tr('total')})',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              subtitle: Text(
                tr('Tap to expand / collapse'),
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _checkerSearchBox(
                    'Search in songs…',
                    _songQuery,
                    (v) => setState(() => _songQuery = v),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _filterChip(0, 'All'),
                    _filterChip(1, 'Too long'),
                    _filterChip(2, 'Too short'),
                    _filterChip(3, 'No reference'),
                  ],
                ),
                const SizedBox(height: 6),
                // Cap rendered rows: thousands of inline tiles rebuilt
                // on every 2s poll tick freeze scrolling (worst at the
                // bottom, where extent churn traps the offset).
                for (final r in _filtered(check).take(200))
                  ListTile(
                    dense: true,
                    // Tapping a song opens the check sheet: fingerprint +
                    // versions auto-run on open, and the actions (play,
                    // versions/replace) are always offered — even when every
                    // check passes. The quick-play button is in the trailing
                    // row.
                    onTap: r.rel == null
                        ? null
                        : () => openCheckSongSheet(
                            context,
                            api: widget.api,
                            report: r,
                            onPlay: () => _playNasSong(r),
                            onVersions: () => _openVersionPicker(r),
                          ),
                    leading: Icon(
                      _statusIcon(r.status),
                      color: _statusColor(r.status),
                    ),
                    title: Text(
                      r.baseName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: _statusLabel(r, r),
                    trailing: _replacing.contains(r.baseName)
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Play only when the report has a servable URL:
                              // staging-dir rows (url=null) have no play
                              // route and would die with a playback error.
                              if (r.isPlayable)
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: tr('Play this NAS song'),
                                  icon: Icon(
                                    Icons.play_arrow,
                                    color: Spots.green,
                                  ),
                                  onPressed: () => _playNasSong(r),
                                ),
                              PopupMenuButton<String>(
                                tooltip: tr('Check versions / replace'),
                                icon: const Icon(Icons.more_vert),
                                onSelected: (v) {
                                  if (v == 'versions') _openVersionPicker(r);
                                  if (v == 'identify') _identifyFile(r);
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'versions',
                                    child: Text(tr('Check versions / replace')),
                                  ),
                                  PopupMenuItem(
                                    value: 'identify',
                                    child: Text(
                                      tr('Fingerprint this file') +
                                      tr(' (verify what it really is)'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                  ),
                if (_filtered(check).length > 200)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      tr('…and more below — type in Search to narrow it down.'),
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ),
              ],
            ),
          const Divider(height: 24),
          ListTile(
            leading: const Icon(Icons.lyrics_outlined),
            title: Text(tr('Check lyrics')),
            subtitle: Text(
              tr('Verify every NAS song has lyrics that actually belong to it — ') +
                  tr("flags songs with no lyrics or the wrong song's lyrics."),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _lyricsChecking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _lyricsChecking ? null : _startLyricsCheck,
          ),
          if (_lyricsError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                "${tr('Error')}: $_lyricsError",
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          if (_lyrics != null && _lyrics!.running)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                tr('Checking ') + '${_lyrics!.scanned}/${_lyrics!.total} ${tr('songs…')} '
                '(${_scopeModeLabel()})',
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          if (_lyrics != null && (_lyrics!.done || _lyrics!.reports.isNotEmpty))
            ExpansionTile(
              initiallyExpanded: true,
              tilePadding: const EdgeInsets.symmetric(horizontal: 16),
              childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: Icon(
                _lyricsIcon('none'),
                color: _lyrics!.reports.any((r) => r.isProblem)
                    ? Colors.redAccent
                    : Colors.greenAccent,
              ),
              title: Text(
                _lyrics!.done
                    ? '${_lyrics!.reports.where((r) => r.status == "ok").length} '
                          "${tr('fine')} · ${_lyrics!.reports.where((r) => r.isProblem).length} "
                          "${tr('need attention')} (${_lyrics!.reports.length} ${tr('checked')})"
                    : '${_lyrics!.reports.length} ${tr('checked so far')} '
                          '(${_lyrics!.scanned}/${_lyrics!.total})',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              subtitle: Text(
                tr('Tap to expand / collapse'),
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _checkerSearchBox(
                    'Search in lyrics…',
                    _lyricQuery,
                    (v) => setState(() => _lyricQuery = v),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _lyricsFilterChip(0, 'Problems'),
                    _lyricsFilterChip(1, 'No lyrics'),
                    _lyricsFilterChip(2, 'Mismatch'),
                    _lyricsFilterChip(3, 'Error'),
                  ],
                ),
                const SizedBox(height: 6),
                for (final r in _filteredLyrics(_lyrics!).take(200))
                  ListTile(
                    dense: true,
                    leading: Icon(
                      _lyricsIcon(r.status),
                      color: _lyricsColor(r.status),
                    ),
                    title: Text(
                      r.baseName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: _lyricsLabel(r),
                  ),
                if (_filteredLyrics(_lyrics!).length > 200)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      tr('…and ') + '${_filteredLyrics(_lyrics!).length - 200} ' +
                      tr('more — refine the search above to see them.'),
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ]),
          if (AuthStore.instance.isOwner)
          _sectionCard(tr('Diagnostics'), [
          SwitchListTile(
            secondary: const Icon(Icons.developer_mode_outlined),
            title: Text(tr('Developer tools')),
            subtitle: Text(
              tr('Photo reports, self-test, player/car logs. Off keeps ') +
                  tr('Settings clean.'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            value: _showDev,
            onChanged: (v) async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('show_dev_tools', v);
              if (mounted) setState(() => _showDev = v);
            },
          ),
          if (_showDev)
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: Text(tr('Artist photo report')),
              subtitle: Text(
                tr('Test the Spotify credentials and dump what Spotify / Deezer ') +
                    tr('return for an artist, then copy the report to hand back.'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openDiagnostics,
            ),
          if (_showDev)
            ListTile(
              leading: const Icon(Icons.health_and_safety_outlined),
              title: Text(tr('Device self-test')),
              subtitle: Text(
                tr('Run local + server checks for the open bugs: songs cutting ') +
                    tr('short, background audio, playlist latency, missing art. ') +
                    tr('Copy the results to hand back.'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SelfTestScreen(api: widget.api),
                ),
              ),
            ),
          if (_showDev)
            SwitchListTile(
              secondary: const Icon(Icons.restart_alt_outlined),
              title: Text(tr('Track restart log')),
              subtitle: Text(
                tr('Record what the player does around a restart, then share ') +
                    tr('the file. Turn on, reproduce the ~15s restart, share.'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              value: DiagLog.restart.enabled,
              onChanged: (v) async {
                await DiagLog.restart.setEnabled(v);
                if (mounted) setState(() {});
              },
            ),
          if (_showDev)
            SwitchListTile(
              secondary: const Icon(Icons.directions_car_outlined),
              title: Text(tr('Car session log')),
              subtitle: Text(
                tr('Record what the app publishes for the car display, then ') +
                    tr('share the file. Turn on, connect to the car, share.'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              value: DiagLog.car.enabled,
              onChanged: (v) async {
                await DiagLog.car.setEnabled(v);
                if (mounted) setState(() {});
              },
            ),
          if (_showDev)
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: Text(tr('Share diagnostic logs')),
              subtitle: Text(
                tr('Send the restart and car logs (plus a copy saved to the ') +
                    tr('app documents folder).'),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _shareDiagLogs(),
            ),
          if (_showDev && AuthStore.instance.isOwner)
            ValueListenableBuilder<int>(
              valueListenable: _userErrorCount,
              builder: (_, count, __) => ListTile(
                leading: const Icon(Icons.people_outline),
                title: Text(tr('User errors')),
                subtitle: Text(
                  tr('Every error, per user: login, download, playback, timeout, import. ') +
                      tr('Search, filter, copy.'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (count > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$count',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () => Navigator.of(context)
                    .push(
                      MaterialPageRoute(
                        builder: (_) => UserErrorsScreen(api: widget.api),
                      ),
                    )
                    // Detail marks rows seen: refresh on pop so the badge
                    // clears immediately.
                    .then((_) => _refreshUserErrorCount()),
              ),
            ),
          if (_showDev)
            ListTile(
              leading: const Icon(Icons.campaign_outlined),
              title: Text(tr('Broadcast')),
              subtitle: Text(
                tr('Send a notification to all devices now.'),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _broadcast(),
            ),
          if (_showDev)
            ListTile(
              leading: const Icon(Icons.celebration_outlined),
              title: Text(tr('Test Wrapped')),
              subtitle: Text(
                tr('Fire a test Wrapped notification with sample stats.'),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Announcer.testWrapped();
                if (mounted) {
                  toast(context, tr('Test Wrapped sent — check notifications.'),
                      icon: Icons.check_circle);
                }
              },
            ),
          ]),
          // NOT owner-gated: any tester (emutest2 included) must be able to
          // enable the ground-truth HUD without the owner's account.
          _sectionCard(tr('Debug'), [
          ValueListenableBuilder<bool>(
            valueListenable: DebugInfo.enabled,
            builder: (_, on, __) => SwitchListTile(
              secondary: const Icon(Icons.bug_report),
              title: Text(tr('Debug overlay')),
              subtitle: Text(
                tr('Tiny ground-truth HUD: engine, queue, last actions.'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              value: on,
              onChanged: (v) async {
                await DebugInfo.setEnabled(v);
              },
            ),
          ),
          ]),
          _sectionCard(tr('Phone storage'), [
          ValueListenableBuilder<int>(
            valueListenable: OfflineStore.change,
            builder: (_, __, ___) {
              final used = OfflineStore.bytesUsed;
              final quota = OfflineStore.quotaBytes;
              final frac =
                  quota > 0 ? (used / quota).clamp(0.0, 1.0) : 0.0;
              return Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.phone_android_outlined),
                    title: Text(
                      '${OfflineStore.fmtBytes(used)} ${tr('of')} '
                      '${OfflineStore.fmtBytes(quota)} '
                      '(${OfflineStore.count} ${tr('songs')})',
                    ),
                    subtitle: LinearProgressIndicator(value: frac),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openOfflineList(),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                    child: Row(
                      children: [
                        Text(tr('Limit')),
                        Expanded(
                          child: Slider(
                            min: 0.5,
                            max: 16,
                            divisions: 31,
                            label:
                                '${OfflineStore.quotaGb.toStringAsFixed(1)} GB',
                            value: OfflineStore.quotaGb
                                .clamp(0.5, 16.0),
                            onChanged: (v) async {
                              try {
                                await OfflineStore.setQuotaGb(v);
                              } on OfflineQuotaError catch (e) {
                                if (mounted) {
                                  toast(context, e.message,
                                      icon: Icons.error_outline);
                                }
                              }
                            },
                          ),
                        ),
                        Text(
                          '${OfflineStore.quotaGb.toStringAsFixed(1)} GB',
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.wifi_off_outlined),
                    title: Text(tr('When offline')),
                    trailing: DropdownButton<String>(
                      value: OfflineStore.mode,
                      dropdownColor: Spots.elevated,
                      items: [
                        DropdownMenuItem(
                            value: 'ask', child: Text(tr('Ask me'))),
                        DropdownMenuItem(
                            value: 'mine',
                            child: Text(tr('This playlist'))),
                        DropdownMenuItem(
                            value: 'any',
                            child: Text(tr('Any downloads'))),
                        DropdownMenuItem(
                            value: 'off', child: Text(tr('Never'))),
                      ],
                      onChanged: (v) {
                        if (v != null) OfflineStore.setMode(v);
                      },
                    ),
                  ),
                  ListenableBuilder(
                    listenable: PrefetchStore.change,
                    builder: (_, __) => SwitchListTile(
                      secondary: const Icon(
                          Icons.download_for_offline_outlined),
                      title: Text(tr('Prefetch upcoming songs')),
                      subtitle: Text(tr(
                          'Keep the next 10 ready for offline listening')),
                      value: PrefetchStore.enabled,
                      onChanged: (v) async {
                        if (v && !PrefetchStore.enabled) {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(tr('Enable prefetch?')),
                              content: Text(
                                  tr('This will download the next 10 queued songs '
                                  'over WiFi so they play offline. '
                                  'Each song is ~5 MB (up to ~50 MB total). '
                                  'Cached songs are auto-removed when space runs low.')),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: Text(tr('Cancel')),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: Text(tr('Enable')),
                                ),
                              ],
                            ),
                          );
                          if (ok != true) return;
                        }
                        await PrefetchStore.setEnabled(v);
                      },
                    ),
                  ),
                  ListenableBuilder(
                    listenable: PrefetchStore.change,
                    builder: (_, __) => SwitchListTile(
                      secondary: const Icon(Icons.wifi_outlined),
                      title: Text(tr('Prefetch on WiFi only')),
                      subtitle: Text(
                        '${tr('Look-ahead cache')}: '
                        '${OfflineStore.fmtBytes(PrefetchStore.bytesUsed)}',
                      ),
                      value: PrefetchStore.wifiOnly,
                      onChanged: (v) => PrefetchStore.setWifiOnly(v),
                    ),
                  ),
                ],
              );
            },
          ),
          ]),
          _sectionCard(tr('Import music'), [
          ListTile(
            leading: const Icon(Icons.playlist_add_outlined),
            title: Text(tr('Import a playlist')),
            subtitle: Text(
              tr('Spotify or YouTube Music link → downloads every song ') +
              tr('to the NAS in order.'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openImportSheet(context, api: widget.api),
          ),
          ]),
        ],
        ),
      ),
    );
  }

  /// Change your own password (stays logged in; other devices log out).
  Future<void> _changePassword() async {
    final cur = TextEditingController();
    final nw = TextEditingController();
    final nw2 = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Change password')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: cur,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: tr('Current password'),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nw,
              obscureText: true,
              decoration: InputDecoration(
                labelText: tr('New password (min 6)'),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nw2,
              obscureText: true,
              decoration: InputDecoration(
                labelText: tr('Repeat new password'),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Change')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (nw.text != nw2.text) {
      toast(context, tr('New passwords do not match.'),
          icon: Icons.error_outline);
      return;
    }
    try {
      await widget.api.changePassword(cur.text, nw.text);
      if (!mounted) return;
      toast(context, tr('Password changed.'), icon: Icons.check_circle);
    } catch (e) {
      if (mounted) {
        toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
      }
    }
  }

  /// Phone downloads on this device, with per-song delete + clear-all.
  Future<void> _openOfflineList() async {
    final entries = OfflineStore.all();
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('On this phone (') + '${entries.length})'),
        content: SizedBox(
          width: double.maxFinite,
          child: entries.isEmpty
              ? Text(tr('Nothing downloaded yet.'))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    return ListTile(
                      dense: true,
                      leading: CoverThumb(
                        title: e.base,
                        thumbUrl: e.thumb,
                        size: 40,
                      ),
                      title: Text(e.base,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${OfflineStore.fmtBytes(e.size)}'
                        '${e.playlist.isNotEmpty ? ' · ${e.playlist}' : ''}',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await OfflineStore.remove(e.base);
                          if (ctx.mounted) Navigator.pop(ctx);
                          _openOfflineList();
                        },
                      ),
                    );
                  },
                ),
        ),
        actions: [
          if (entries.isNotEmpty)
            TextButton(
              onPressed: () async {
                final yes = await showDialog<bool>(
                  context: ctx,
                  builder: (c2) => AlertDialog(
                    title: Text(tr('Delete all downloads?')),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c2, false),
                        child: Text(tr('Cancel')),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(c2, true),
                        child: Text(tr('Delete')),
                      ),
                    ],
                  ),
                );
                if (yes == true) {
                  await OfflineStore.clear();
                  if (ctx.mounted) Navigator.pop(ctx);
                }
              },
              child: Text(tr('Clear all')),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Close')),
          ),
        ],
      ),
    );
  }

  /// Owner broadcast: compose a notification card for all devices
  /// (title + body + optional link). Devices pick it up within minutes.

  /// Owner broadcast: compose a title/body/link card and push it to all
  /// devices (they notify on next check), or clear all live cards.
  Future<void> _broadcast() async {
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    var updatesOn = true;
    try {
      updatesOn =
          (await widget.api.announcements())['app_updates'] != false;
    } catch (_) {}
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        // Fields scroll; Send/Cancel stay pinned in actions so they
        // can never scroll off-screen. Clear-all + Send-update live
        // in the title overflow menu.
        builder: (ctx, setD) => AlertDialog(
        title: Row(
          children: [
            Expanded(child: Text(tr('Broadcast to apps'))),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (v) => Navigator.pop(ctx, v),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'clear',
                  child: Text(tr('Clear all')),
                ),
                PopupMenuItem(
                  value: 'update',
                  child: Text(tr('Send update')),
                ),
              ],
            ),
          ],
        ),
        content: SingleChildScrollView(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                      child: Text(tr('Auto app-update notices'))),
                  Switch(
                    value: updatesOn,
                    onChanged: (v) async {
                      try {
                        updatesOn =
                            await widget.api.setAppUpdates(v);
                      } catch (e) {
                        if (mounted) {
                          toast(context, "${tr('Failed')}: $e",
                              icon: Icons.error_outline);
                        }
                      }
                      setD(() {});
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: titleCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: tr('Title'),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bodyCtrl,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: tr('Message'),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: urlCtrl,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: tr('Link (optional)'),
                  hintText: 'https://… opens on tap',
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'send'),
            child: Text(tr('Send')),
          ),
        ],
      ),
    ));
    if (res == null || !mounted) return;
    try {
      if (res == 'clear') {
        await widget.api.clearAnnouncements();
        if (mounted) {
          toast(context, tr('Broadcasts cleared'), icon: Icons.check_circle);
        }
        return;
      }
      if (res == 'update') {
        final a = await widget.api.announcements();
        final v = (a['app_version'] ?? '').toString().trim();
        await widget.api.publishAnnouncement(
          tr('Update available'),
          'gungan.fm ${v.isEmpty ? tr('new version') : v} ${tr('is ready — tap to download.')}',
          widget.api.apkUrl,
        );
        if (mounted) {
          toast(context, tr('Update notice sent — devices ping within minutes.'),
              icon: Icons.check_circle);
        }
        return;
      }
      final title = titleCtrl.text.trim();
      final body = bodyCtrl.text.trim();
      final url = urlCtrl.text.trim();
      if (title.isEmpty || body.isEmpty) {
        toast(context, tr('Title + message required.'),
            icon: Icons.error_outline);
        return;
      }
      await widget.api.publishAnnouncement(title, body, url);
      if (mounted) {
        toast(context, tr('Broadcast sent — devices ping within minutes.'),
            icon: Icons.check_circle);
      }
    } catch (e) {
      if (mounted) {
        toast(context, "${tr('Failed')}: $e", icon: Icons.error_outline);
      }
    }
  }

  /// Share both diagnostic logs: save copies to the app documents folder,
  /// then send the content through the native share sheet (clipboard
  /// fallback on desktop).
  Future<void> _shareDiagLogs() async {
    String rPath = '';
    String cPath = '';
    try {
      rPath = await DiagLog.restart.writeFile();
    } catch (_) {}
    try {
      cPath = await DiagLog.car.writeFile();
    } catch (_) {}
    final text =
        '=== RESTART LOG${rPath.isNotEmpty ? ' ($rPath)' : ''} ===\n'
        '${DiagLog.restart.snapshot().isEmpty ? tr('(empty — toggle the log on and reproduce first)') : DiagLog.restart.tail(400)}\n'
        '\n=== CAR LOG${cPath.isNotEmpty ? ' ($cPath)' : ''} ===\n'
        '${DiagLog.car.snapshot().isEmpty ? tr('(empty — toggle the log on and reproduce first)') : DiagLog.car.tail(400)}';
    final usedSheet = await DiagLog.shareText(text, 'gungan.fm logs');
    if (!mounted) return;
    toast(
      context,
      usedSheet ? tr('Logs shared.') : tr('Logs copied to clipboard.'),
      icon: Icons.check_circle,
      background: Spots.green,
    );
  }

  Future<void> _openDiagnostics() async {
    final c = TextEditingController(text: 'Eminem');
    final artist = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Artist photo report')),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('Artist name')),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: Text(tr('Run')),
          ),
        ],
      ),
    );
    if (artist == null || artist.isEmpty) return;
    String text;
    try {
      final j = await widget.api.diagnostics(artist);
      final sb = StringBuffer();
      sb.writeln('Diagnostics for "$artist"');
      sb.writeln('========================');
      _writePretty(sb, j, '');
      text = sb.toString();
    } catch (e) {
      text = 'Diagnostics failed for "$artist":\n$e';
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  tr('Report'),
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                FilledButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: text));
                      toast(
                        ctx,
                        tr('Report copied to clipboard.'),
                      icon: Icons.check_circle,
                      background: Spots.green,
                    );
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(tr('Copy all')),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.6,
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _writePretty(StringBuffer sb, dynamic v, String indent) {
    if (v is Map) {
      v.forEach((k, val) {
        sb.write('$indent$k: ');
        if (val is Map || val is List) {
          sb.write('\n');
          _writePretty(sb, val, indent + '  ');
        } else {
          sb.writeln(val);
        }
      });
    } else if (v is List) {
      for (final it in v) {
        _writePretty(sb, it, indent);
      }
    } else {
      sb.writeln(v);
    }
  }

  List<CheckSongReport> _filtered(CheckSongsStatus check) {
    final problems = check.reports.where((r) => r.isProblem);
    List<CheckSongReport> base;
    switch (_filter) {
      case 1:
        base = problems.where((r) => r.status == 'too_long').toList();
        break;
      case 2:
        base = problems.where((r) => r.status == 'too_short').toList();
        break;
      case 3:
        // The server emits 'unverified' for no-reference hits since
        // 2026-09-18 ('no_ref' is the legacy string) — match both so
        // these songs are actually picked by this filter.
        base = problems
            .where((r) => r.status == 'no_ref' || r.status == 'unverified')
            .toList();
        break;
      default:
        base = problems.toList();
    }
    return _filterByQuerySongs(base);
  }

  List<CheckSongReport> _filterByQuerySongs(List<CheckSongReport> base) {
    final q = _songQuery.trim().toLowerCase();
    if (q.isEmpty) return base;
    return base.where((r) => r.baseName.toLowerCase().contains(q)).toList();
  }

  Widget _filterChip(int v, String label) {
    final selected = _filter == v;
    return ChoiceChip(
      label: Text(tr(label)),
      selected: selected,
      visualDensity: VisualDensity.compact,
      labelStyle: TextStyle(
        color: selected ? Colors.black : Colors.white70,
        fontSize: 12,
      ),
      selectedColor: Spots.green,
      backgroundColor: Colors.white10,
      side: BorderSide(color: Colors.white24),
      onSelected: (_) => setState(() => _filter = v),
    );
  }

  Widget _lyricsFilterChip(int v, String label) {
    final selected = _lyricsFilter == v;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      visualDensity: VisualDensity.compact,
      labelStyle: TextStyle(
        color: selected ? Colors.black : Colors.white70,
        fontSize: 12,
      ),
      selectedColor: Spots.green,
      backgroundColor: Colors.white10,
      side: BorderSide(color: Colors.white24),
      onSelected: (_) => setState(() => _lyricsFilter = v),
    );
  }

  /// Shared search box for the song and lyric checkers. Each caller supplies
  /// its own query value + setter so typing filters the correct checker's list.
  Widget _checkerSearchBox(
    String hint,
    String query,
    ValueChanged<String> onChanged,
  ) {
    return TextField(
      decoration: InputDecoration(
        hintText: tr(hint),
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () => onChanged(''),
              ),
        filled: true,
        fillColor: Colors.white10,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
      style: const TextStyle(fontSize: 14),
      onChanged: onChanged,
    );
  }

  IconData _lyricsIcon(String status) {
    switch (status) {
      case 'ok':
        return Icons.check_circle;
      case 'none':
        return Icons.library_music_outlined;
      case 'mismatch':
        return Icons.report_problem_outlined;
      default:
        return Icons.error_outline;
    }
  }

  Color _lyricsColor(String status) {
    switch (status) {
      case 'ok':
        return Colors.greenAccent;
      case 'none':
        return Colors.orangeAccent;
      case 'mismatch':
        return Colors.redAccent;
      default:
        return Colors.redAccent;
    }
  }

  Widget _lyricsLabel(LyricsReport r) {
    final String text;
    switch (r.status) {
      case 'ok':
        text = "${tr('Lyrics present')}${r.source != null ? ' · ${r.source}' : ''}";
        return Text(
          text,
          style: const TextStyle(color: Colors.greenAccent, fontSize: 12),
        );
      case 'none':
        text = "${tr('No lyrics found')}${r.reason != null ? ' — ${r.reason}' : ''}";
        return Text(
          text,
          style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
        );
      case 'mismatch':
        text =
            "${tr('Lyrics may be for another song. Got')} \""
            '${r.theirTitle ?? "? "}" ${tr('by')} ${r.theirArtist ?? "? "}';
        return Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.redAccent, fontSize: 12),
        );
      default:
        text = "${tr('Could not check')}${r.reason != null ? ' — ${r.reason}' : ''}";
        return Text(
          text,
          style: const TextStyle(color: Colors.redAccent, fontSize: 12),
        );
    }
  }

  Future<void> _playNasSong(CheckSongReport r) async {
    // No servable NAS URL (e.g. staging-dir file): stream it instead.
    if (!r.isPlayable || r.url == null || r.url!.isEmpty) {
      final parts = r.baseName.split(' - ');
      await playArtistTitle(
        context,
        api: widget.api,
        artist: parts.length > 1 ? parts.first.trim() : '',
        title: parts.length > 1
            ? parts.sublist(1).join(' - ').trim()
            : r.baseName,
      );
      return;
    }
    final url = r.url!;
    final fullUrl = widget.api.fileUrl(url);
    debugPrint('[_playNasSong] url=$url fullUrl=$fullUrl');
    try {
      await QueuePlayer.instance.playOne(
        QueueItem(r.baseName, fullUrl, thumbUrl: widget.api.coverUrl(url)),
      );
    } catch (e) {
      debugPrint('[_playNasSong] FAILED: $e');
      // NAS copy unreachable (moved / replaced / ownership) — fall back
      // to streaming the same song instead of erroring.
      if (!mounted) return;
      final parts = r.baseName.split(' - ');
      await playArtistTitle(
        context,
        api: widget.api,
        artist: parts.length > 1 ? parts.first.trim() : '',
        title: parts.length > 1
            ? parts.sublist(1).join(' - ').trim()
            : r.baseName,
      );
      return;
    }
    if (!mounted) return;
    toast(context, tr('Playing: ') + r.baseName, icon: Icons.music_note);
    QueuePlayerShim.instance.openNowPlaying(context);
  }

  Future<void> _identifyFile(CheckSongReport r) async {
    if (mounted) {
      toast(context, "${tr('Fingerprinting')} ${r.baseName}…", icon: Icons.graphic_eq);
    }
    try {
      final res = await widget.api.identify(r.baseName);
      if (!mounted) return;
      if (res['error'] != null && (res['error'] as String).isNotEmpty) {
        toast(context, "${tr('Identify')}: ${res['error']}", icon: Icons.error_outline);
        return;
      }
      final real =
          '${res['artist']?.toString().isNotEmpty == true ? '${res['artist']} - ' : ''}${res['title']}';
      final match = ((res['score'] as num?) ?? 0) >= 0.5
          ? tr('High confidence')
          : tr('Low confidence');
      toast(
        context,
        "${tr('Audio is')}: $real\n($match, ${tr('score')} ${res['score']})",
        icon: Icons.verified,
      );
    } catch (e) {
      if (mounted) {
        toast(context, "${tr('Could not fingerprint')}: $e", icon: Icons.error_outline);
      }
    }
  }

  Future<void> _openVersionPicker(CheckSongReport r) async {
    // Shared sheet (version_sheet.dart): audition + replace. The row
    // spinner covers the replace job; the checker list refreshes after.
    if (!mounted) return;
    setState(() => _replacing.add(r.baseName));
    try {
      await openVersionPicker(
        context,
        api: widget.api,
        baseName: r.baseName,
        onReplaced: () async {
          if (mounted) await _startCheck();
        },
      );
    } finally {
      if (mounted) setState(() => _replacing.remove(r.baseName));
    }
  }
}

/// Expandable settings card. Open/collapsed persists per title.
/// [initialOpen] arrives preloaded from openSettings so the first frame
/// already has final extents (no post-mount collapse jumps mid-scroll).
class _SectionCard extends StatefulWidget {
  const _SectionCard(
      {super.key,
      required this.title,
      required this.children,
      this.initialOpen = true});
  final String title;
  final List<Widget> children;
  final bool initialOpen;

  @override
  State<_SectionCard> createState() => _SectionCardState();
}

class _SectionCardState extends State<_SectionCard> {
  late bool _open = widget.initialOpen;

  @override
  void initState() {
    super.initState();
    // No prefs fetch here by design: open state arrives preloaded via
    // openSettings so the first frame already has final extents.
  }

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        color: Spots.elevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () async {
                  setState(() => _open = !_open);
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('sec.open.${widget.title}', _open);
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      Icon(
                        _open ? Icons.expand_less : Icons.expand_more,
                        size: 22,
                        color: Spots.green,
                      ),
                    ],
                  ),
                ),
              ),
              if (_open) ...widget.children,
            ],
          ),
        ),
      );
}
