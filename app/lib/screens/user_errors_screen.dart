import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_client.dart';
import '../auth_store.dart';
import '../lang.dart';
import '../toast.dart';

/// Gear-dot poller (announcer pattern): true while ANY unseen error row
/// exists. Throttled; owner-only (others clear the dot).
class ErrorDot {
  ErrorDot._();
  static final ValueNotifier<bool> hasUnseen = ValueNotifier(false);
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> refresh(ApiClient api, {bool force = false}) async {
    if (!force &&
        DateTime.now().difference(_last) < const Duration(minutes: 1)) {
      return;
    }
    _last = DateTime.now();
    try {
      if (!(AuthStore.instance.isOwner)) {
        hasUnseen.value = false;
        return;
      }
      final j = await api.userErrors(limit: 1, unseen: true);
      final rows = (j['errors'] as List?) ?? [];
      hasUnseen.value = rows.isNotEmpty;
    } catch (_) {}
  }
}

/// Owner-only viewer for per-user server error rows (Diagnostics →
/// User errors). Screen 1: every user by name. Screen 2 (per user):
/// search box, section chips, copyable list.
class UserErrorsScreen extends StatefulWidget {
  const UserErrorsScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<UserErrorsScreen> createState() => _UserErrorsScreenState();
}

class _UserErrorsScreenState extends State<UserErrorsScreen> {
  List<String> _users = [];
  Map<String, int> _errorCounts = {};
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final j = await widget.api.userErrors(limit: 500);
      if (!mounted) return;
      setState(() {
        _users = ((j['users'] as List?) ?? []).map((e) => '$e').toList();
        _loading = false;
      });
      final countsJ = await widget.api.userErrors(limit: 500, unseen: true);
      if (mounted) {
        final rows = (countsJ['errors'] as List?) ?? [];
        final counts = <String, int>{};
        for (final r in rows) {
          final user = (r['username'] as String? ?? '');
          if (user.isNotEmpty) {
            counts[user] = (counts[user] ?? 0) + 1;
          }
        }
        setState(() => _errorCounts = counts);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _copyUserErrors(String user) async {
    final j = await widget.api.userErrors(
      user: user,
      limit: 500,
    );
    final rows = (j['errors'] as List?) ?? [];
    final userRows = rows.where((r) => (r['username'] as String? ?? '') == user).toList();
    final buf = StringBuffer();
    for (final r in userRows) {
      final ts = DateTime.fromMillisecondsSinceEpoch(
          ((r['seen_at'] as num?) ?? 0).toInt() * 1000);
      buf.writeln('[$ts] [${r['section']}] ${r['message']}');
    }
    if (context.mounted) {
      Clipboard.setData(ClipboardData(text: buf.toString()));
      toast(context, "${tr('Copied')} ${userRows.length} ${tr('rows')}");
    }
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error, textAlign: TextAlign.center),
            ),
            FilledButton(onPressed: _load, child: Text(tr('Retry'))),
          ],
        ),
      );
    }
    if (_users.isEmpty) {
      return Center(child: Text(tr('No errors logged.')));
    }
    return ListView.builder(
      itemCount: _users.length,
      itemBuilder: (_, i) {
        final user = _users[i];
        final count = _errorCounts[user] ?? 0;
        return ListTile(
          leading: const Icon(Icons.person_outline),
          title: Text(user),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (count > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
              IconButton(
                icon: const Icon(Icons.copy_outlined),
                tooltip: tr('Copy all errors'),
                onPressed: count == 0
                    ? null
                    : () => _copyUserErrors(user),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () => Navigator.of(context)
              .push(
                MaterialPageRoute(
                  builder: (_) =>
                      _UserErrorDetailScreen(api: widget.api, user: user),
                ),
              )
              // Detail marks rows seen on open: refresh counts on pop so
              // the badge clears without a second visit.
              .then((_) {
            ErrorDot.refresh(widget.api, force: true);
            _load();
          }),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('User errors'))),
      body: _buildBody(),
    );
  }
}

class _UserErrorDetailScreen extends StatefulWidget {
  const _UserErrorDetailScreen({super.key, required this.api, this.user});
  final ApiClient api;
  final String? user;

  @override
  State<_UserErrorDetailScreen> createState() => _UserErrorDetailState();
}

class _UserErrorDetailState extends State<_UserErrorDetailScreen> {
  static const List<String> _sections = ['login', 'download_failed', 'playback', 'timeout', 'import_missing', 'general'];
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String _error = '';
  String _section = '';
  final _search = TextEditingController();
  final _expanded = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final j = await widget.api.userErrors(
        user: widget.user ?? AuthStore.instance.username,
        section: _section.isEmpty ? null : _section,
        q: _search.text.trim().isEmpty ? null : _search.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _rows = ((j['errors'] as List?) ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _loading = false;
      });
      // Mark-on-open: rows just viewed count as seen (server scopes
      // non-owners to their own rows). Local flags flip so the grey
      // seen state shows without a second fetch.
      final ids = _rows
          .where(((r) => ((r['seen'] as num?) ?? 0).toInt() == 0))
          .map((r) => (r['id'] as num?)?.toInt())
          .whereType<int>()
          .toList();
      if (ids.isNotEmpty) {
        widget
            .api
            .markUserErrorsSeen(
              user: widget.user ?? AuthStore.instance.username,
              ids: ids,
            )
            .then((_) {
          if (mounted) {
            setState(() {
              for (final r in _rows) r['seen'] = 1;
            });
          }
        }).catchError((_) {});
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _copy(BuildContext context) {
    final buf = StringBuffer();
    for (final r in _rows) {
      final ts = DateTime.fromMillisecondsSinceEpoch(
          ((r['seen_at'] as num?) ?? 0).toInt() * 1000);
      buf.writeln('[$ts] [${r['section']}] ${r['message']}');
    }
    Clipboard.setData(ClipboardData(text: buf.toString()));
    toast(context, "${tr('Copied')} ${_rows.length} ${tr('rows')}");
  }

  Widget _buildErrorList() {
    return ListView.builder(
      itemCount: _rows.length,
      itemBuilder: (_, i) {
        final r = _rows[i];
        final ts = DateTime.fromMillisecondsSinceEpoch(
            ((r['seen_at'] as num?) ?? 0).toInt() * 1000);
        final sec = (r['section'] ?? '').toString();
        final msg = (r['message'] ?? '').toString();
        final seen = ((r['seen'] as num?) ?? 0).toInt() == 1;
        return ListTile(
          dense: true,
          leading: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              sec,
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ),
          title: Text(
            msg,
            maxLines: _expanded.contains(i) ? null : 3,
            overflow: _expanded.contains(i)
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
            style: seen
                ? const TextStyle(color: Colors.white38)
                : null,
          ),
          subtitle: Text(
            ts.toString(),
            style: const TextStyle(fontSize: 11, color: Colors.white38),
          ),
          trailing: seen
              ? Tooltip(
                  message: tr('Seen'),
                  child: const Icon(
                    Icons.check_circle_outline,
                    size: 18,
                    color: Colors.white38,
                  ),
                )
              : null,
          onTap: () {
            // Tap expands the full body in place (3-line ellipsis hides
            // exception tails); the full text is still copied as before.
            setState(() {
              if (!_expanded.remove(i)) _expanded.add(i);
            });
            Clipboard.setData(ClipboardData(text: '[$sec] $msg'));
          },
        );
      },
    );
  }

  Widget _buildExpandedChild() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error, textAlign: TextAlign.center),
            ),
            FilledButton(onPressed: _load, child: Text(tr('Retry'))),
          ],
        ),
      );
    }
    if (_rows.isEmpty) {
      return Center(child: Text(tr('No errors found.')));
    }
    return _buildErrorList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.user ?? AuthStore.instance.username ?? ''),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: tr('Copy'),
            onPressed: _rows.isEmpty ? null : () => _copy(context),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: tr('Search errors…'),
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                ChoiceChip(
                  label: Text(tr('All')),
                  selected: _section.isEmpty,
                  onSelected: (_) {
                    setState(() => _section = '');
                    _load();
                  },
                ),
                for (final s in _sections) ...[
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(tr(s)),
                    selected: _section == s,
                    onSelected: (_) {
                      setState(() => _section = s);
                      _load();
                    },
                  ),
                ],
              ],
            ),
          ),
          Expanded(child: _buildExpandedChild()),
        ],
      ),
    );
  }
}