import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_client.dart';
import '../lang.dart';
import '../toast.dart';
import '../widgets.dart';

/// "My YouTube Music" batch import: device-code login once, tick any
/// number of library playlists (+ Liked Songs, private included), import
/// them all with one request — the server works through the queue with
/// the app closed. Tokens stay per-user on the server, never on device.
class MyYtMusicScreen extends StatefulWidget {
  const MyYtMusicScreen({super.key, required this.api, this.pickCover = false});
  final ApiClient api;

  /// Cover-pick mode (opened from a playlist's cover changer): tapping a
  /// playlist returns its cover URL instead of ticking it for import.
  final bool pickCover;

  @override
  State<MyYtMusicScreen> createState() => _MyYtMusicScreenState();
}

class _YtEntry {
  final String id; // playlist id, or 'liked'
  final String name;
  final int total;
  final String? sub; // channel subtitle when total unknown
  final String? cover; // source thumbnail (auto-set on import)
  _YtEntry({required this.id, required this.name, required this.total, this.sub, this.cover});
}

class _MyYtMusicScreenState extends State<MyYtMusicScreen> {
  bool _loading = true;
  bool _loggingIn = false;
  String? _userCode;
  String? _verifyUrl;
  String? _error;
  List<_YtEntry> _entries = [];
  final _ticked = <String>{};
  bool _importing = false;
  String _progress = '';
  bool _cancelPoll = false;
  bool _netDown = false;
  bool _connected = false;
  bool _chanLoading = false;
  bool _mineTried = false;
  String? _chanName;
  final _chanCtrl = TextEditingController();

  @override
  void dispose() {
    _chanCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final st = await widget.api.ytmAuthStatus();
      if (!mounted) return;
      _connected = st['connected'] == true;
      if (_connected) {
        await _loadLists();
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _login() async {
    if (!mounted) return;
    setState(() {
      _loggingIn = true;
      _error = null;
      _cancelPoll = false;
    });
    late Map<String, dynamic> start;
    try {
      start = await widget.api.ytmAuthStart();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loggingIn = false;
          _error = e.toString();
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _userCode = (start['user_code'] ?? '').toString();
      _verifyUrl = (start['url'] ?? 'https://www.google.com/device').toString();
    });
    // Poll until approved / denied / expired / cancelled. Transient
    // network blips (DNS, tunnel naps) must NOT abort the flow — only
    // terminal server answers do.
    var netFails = 0;
    if (mounted) setState(() => _netDown = false);
    for (var i = 0; i < 120; i++) {
      await Future.delayed(const Duration(seconds: 5));
      if (!mounted || _cancelPoll) return;
      Map<String, dynamic>? p;
      try {
        p = await widget.api.ytmAuthPoll();
        netFails = 0;
      } catch (_) {
        // Network-level failure (DNS/tunnel): stay on the code screen
        // and keep polling; the code stays valid for ~15 minutes.
        netFails++;
        if (mounted) setState(() => _netDown = true);
        continue;
      }
      if (p!['connected'] == true) break;
      final err = (p['error'] ?? '').toString();
      if (err.isNotEmpty) throw Exception(err);
      if (i >= 119) throw Exception('Approval timed out — start again.');
    }
    if (!mounted || _cancelPoll) return;
    setState(() {
      _loggingIn = false;
      _userCode = null;
    });
    await _loadLists();
  }

  /// Browser-login fallback (Google rejects some TV-client calls):
  /// paste a `curl` of any logged-in music.youtube.com youtubei/v1/browse
  /// request (DevTools → Network → right-click → Copy as cURL). Only the
  /// login headers are kept, per-user on the server.
  Future<void> _pasteCookie() async {
    final ctrl = TextEditingController();
    final curl = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Browser login')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('1. On a PC browser logged into YouTube Music, open '
                'DevTools (F12) → Network.\n'
                '2. Play any song, find a "browse" request to '
                'music.youtube.com/youtubei/v1/browse.\n'
                '3. Right-click → Copy → Copy as cURL.\n'
                '4. Paste it below. Valid ~2 years; redo if it stops.'),
                style: TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: tr('curl command'),
                  border: OutlineInputBorder(),
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
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('Connect')),
          ),
        ],
      ),
    );
    if (curl == null || curl.isEmpty || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.api.ytmCookie(curl);
      if (!mounted) return;
      toast(context, tr('Browser login saved'), icon: Icons.check_circle);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
      return;
    }
    await _loadLists();
  }

  Future<void> _loadLists() async {    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lib = await widget.api.ytmLibrary();
      if (!mounted) return;
      final pls = (lib['playlists'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final liked = (lib['liked'] as num?)?.toInt() ?? 0;
      setState(() {
        _connected = true;
        _entries = [
          if (liked > 0)
            _YtEntry(id: 'liked', name: '❤ Liked Songs', total: liked),
          for (final p in pls)
            _YtEntry(
              id: '${p['id']}',
              name: '${p['name']}',
              total: (p['total'] as num?)?.toInt() ?? 0,
              cover: '${p['cover'] ?? ''}',
            ),
        ];
        _loading = false;
      });
      // Empty YT-Music shelves but logged in: auto-load the user's
      // OWN channel playlists (no typing needed). Falls back to the
      // manual box when 'mine' can't resolve.
      if (mounted && _connected && _entries.isEmpty && !_mineTried) {
        _mineTried = true;
        await _lookupChannel('mine');
      }
    } catch (e) {
      if (mounted) {
        // Auth/connection failures (no Google login, expired token,
        // rejected session) are not errors to display: show the login
        // prompt + public channel box instead of a raw ApiException
        // that reads as "access denied".
        final code = e is ApiException ? e.statusCode : null;
        setState(() {
          _loading = false;
          if (code == 401) {
            _connected = false;
            _error = null;
          } else if (code == 502) {
            // Server reachable but YouTube refused: explain, don't dump
            // the raw error (it reads as gibberish).
            _connected = false;
            _error = 'YouTube is not answering with the saved login. '
                'Reconnect, or use "paste a browser login" below — '
                'no data is lost.';
          } else {
            _error = e.toString();
          }
        });
      }
    }
  }

  /// Public channel import (no login): @handle / name / UC id ->
  /// that channel's playlists, ticked into the same import flow.
  /// q='mine' resolves the logged-in user's own channel, no typing.
  Future<void> _lookupChannel([String? q]) async {
    q ??= _chanCtrl.text.trim();
    if (q.isEmpty || !mounted) return;
    setState(() {
      _chanLoading = true;
      _error = null;
    });
    try {
      final res = await widget.api.ytmChannel(q);
      if (!mounted) return;
      final pls = (res['playlists'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      setState(() {
        _chanName = '${res['channel'] ?? q}';
        _entries = [
          for (final p in pls)
            if ('${p['id']}'.isNotEmpty)
              _YtEntry(
                id: '${p['id']}',
                name: '${p['name']}',
                total: (p['total'] as num?)?.toInt() ?? 0,
                sub: '${p['subtitle'] ?? ''}',
                cover: '${p['cover'] ?? ''}',
              ),
        ];
        _ticked.clear();
        _chanLoading = false;
        if (_entries.isEmpty) _error = 'No playlists on that channel.';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _chanLoading = false;
          // Silent 'mine' failure just leaves the manual box;
          // a typed lookup reports its error.
          if (q != 'mine') _error = e.toString();
        });
      }
    }
  }

  Future<void> _import() async {
    final picked =
        _entries.where((e) => _ticked.contains(e.id)).toList();
    if (picked.isEmpty || !mounted) return;
    setState(() {
      _importing = true;
      _progress = 'Starting import…';
    });
    try {
      // ID form: the server resolves each list in its worker, so the app
      // is free to leave the moment this single POST lands.
      final res = await widget.api.importBatch([
        for (final e in picked)
          {
            'name': e.name.replaceAll('❤ ', ''),
            'id': e.id,
            if ((e.cover ?? '').isNotEmpty) 'cover': e.cover,
          },
      ]);
      if (!mounted) return;
      setState(() => _importing = false);
      Navigator.pop(context);
      toast(
        context,
        "${tr('Importing')} ${picked.length} ${tr('playlists — safe to leave the app.')}",
        icon: Icons.downloading,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _importing = false);
        toast(context, "${tr('Import failed')}: $e", icon: Icons.error_outline);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final allOn =
        _entries.isNotEmpty && _ticked.length == _entries.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('My YT Music Library')),
        actions: [
          if (_entries.isNotEmpty && !_importing)
            TextButton(
              onPressed: () => setState(() {
                if (allOn) {
                  _ticked.clear();
                } else {
                  _ticked.addAll(_entries.map((x) => x.id));
                }
              }),
              child: Text(allOn ? tr('None') : tr('All'),
                  style: const TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _body(),
      bottomNavigationBar: _entries.isEmpty
          ? null
          : widget.pickCover
              ? SafeArea(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      tr('Tap a playlist to use its cover.'),
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ),
                )
              : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: (_ticked.isEmpty || _importing) ? null : _import,
                  icon: const Icon(Icons.download_outlined),
                  label: Text(_ticked.isEmpty
                      ? tr('Tick playlists to import')
                      : "${tr('Import')} ${_ticked.length} ${tr('playlist${_ticked.length == 1 ? '' : 's'}')}"),
                ),
              ),
            ),
    );
  }

  Widget _body() {
    if (_importing) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_progress),
          ],
        ),
      );
    }
    if (_loading || _loggingIn) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_userCode != null) ...[
              Text(tr('On any browser, open:'),
                  style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 8),
              Text(_verifyUrl ?? '',
                  style: const TextStyle(
                      color: Colors.green,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Text(tr('and enter the code:')),
              SelectableText(
                _userCode!,
                style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 4),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  if ((_userCode ?? '').isNotEmpty) {
                    Clipboard.setData(ClipboardData(text: _userCode!));
                  }
                  if ((_verifyUrl ?? '').isNotEmpty) {
                    launchUrl(Uri.parse(_verifyUrl!),
                        mode: LaunchMode.externalApplication);
                  }
                },
                icon: const Icon(Icons.open_in_browser_outlined),
                label: Text(tr('Copy code and open link')),
              ),
              const SizedBox(height: 8),
              Text(
                tr('If Google warns the app isn’t verified: tap Advanced → Go to gungan.fm (unsafe). It’s our own server — Google just hasn’t reviewed it.'),
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => setState(() {
                  _cancelPoll = true;
                  _loggingIn = false;
                  _userCode = null;
                  _netDown = false;
                }),
                child: Text(tr('Cancel')),
              ),
              if (_netDown)
                Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    tr('Phone cannot reach the server right now — check '
                    'Tailscale is connected, then just wait here.'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.orangeAccent, fontSize: 13),
                  ),
                ),
            ] else ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_loggingIn ? tr('Starting login…') : tr('Loading…')),
            ],
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadLists,
                child: Text(tr('Retry')),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _pasteCookie(),
                child: Text(tr('Use a browser login instead')),
              ),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_connected) ...[
                Text(
                  tr('Log in with your YouTube (Google) account to see '
                  'private playlists and Liked Songs.'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _login,
                  icon: const Icon(Icons.login_outlined),
                  label: Text(tr('Log in with Google')),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => _pasteCookie(),
                  child: Text(tr('Or paste a browser login instead')),
                ),
                const SizedBox(height: 8),
                const Divider(),
                const SizedBox(height: 8),
              ] else ...[
                Text(
                  tr('Your YouTube Music library shelves are empty — '
                  'import from a public channel instead.'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],
              Text(
                tr('Public channel import (no login needed):'),
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _chanCtrl,
                decoration: InputDecoration(
                  labelText: tr('@handle, channel name, or UC id'),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _lookupChannel(),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _chanLoading ? null : _lookupChannel,
                icon: _chanLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search_outlined),
                label: Text(_chanLoading
                    ? tr('Reading playlists…')
                    : tr('Find playlists')),
              ),
              if (_chanLoading) ...[
                const SizedBox(height: 8),
                Text(
                  tr('Fetching track counts — one moment…'),
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
              if (_chanName != null) ...[
                const SizedBox(height: 8),
                Text("${tr('Channel')}: $_chanName",
                    style: const TextStyle(color: Colors.white70)),
              ],
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _entries.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return FutureBuilder<Map<String, dynamic>>(
            future: widget.api.ytmAuthStatus(),
            builder: (_, snap) => ListTile(
              dense: true,
              leading: const Icon(Icons.account_circle_outlined,
                  color: Colors.white54),
              title: Text(tr('YouTube account'),
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
              trailing: TextButton(
                onPressed: () async {
                  await widget.api.ytmAuthLogout();
                  if (mounted) {
                    setState(() {
                      _entries = [];
                      _ticked.clear();
                      _error = null;
                      _connected = false;
                      _chanName = null;
                      _mineTried = false;
                    });
                  }
                },
                child: Text(tr('Log out')),
              ),
            ),
          );
        }
        final e = _entries[i - 1];
        if (widget.pickCover) {
          return ListTile(
            tileColor: Colors.transparent,
            hoverColor: Colors.white10,
            focusColor: Colors.transparent,
            leading: CoverThumb(
              title: e.name,
              thumbUrl: (e.cover ?? '').isNotEmpty ? e.cover : null,
              size: 40,
            ),
            title: Text(e.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(e.total > 0
                ? '${e.total} ${tr('tracks')} — ${tr('tap to use its cover')}'
                : tr('tap to use its cover')),
            trailing: const Icon(Icons.image_outlined),
            onTap: () => Navigator.pop(
                context, (e.cover ?? '').toString()),
          );
        }
        final on = _ticked.contains(e.id);
        return CheckboxListTile(
          value: on,
          title: Text(e.name,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(e.total > 0
              ? '${e.total} ${tr('tracks')}'
              : (e.sub?.isNotEmpty == true ? e.sub! : tr('tracks unknown'))),
          onChanged: (v) => setState(() {
            if (v == true) {
              _ticked.add(e.id);
            } else {
              _ticked.remove(e.id);
            }
          }),
        );
      },
    );
  }
}
