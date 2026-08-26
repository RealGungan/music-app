import 'dart:async';

import 'package:flutter/foundation.dart';
import "package:flutter/material.dart" hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'bottom_player.dart';
import 'player.dart' show MiniPlayerBar;
import 'queue_player.dart';
import 'screens/downloads_screen.dart';
import 'screens/home_screen.dart';
import 'screens/playlist_detail.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';

// desktop content region lives in _content(); overlays push playlist pages
import 'build_id.dart';
import 'sidebar.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  QueuePlayer.instance; // wire completion -> next()
  final prefs = await SharedPreferences.getInstance();
  runApp(MusicApp(
    initialServer:
        prefs.getString('server_url') ?? 'http://192.168.1.135:6680',
    onServerChanged: (url) => prefs.setString('server_url', url),
  ));
}

class MusicApp extends StatelessWidget {
  const MusicApp({
    super.key,
    required this.initialServer,
    required this.onServerChanged,
  });

  final String initialServer;
  final ValueChanged<String> onServerChanged;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music',
      debugShowCheckedModeBanner: false,
      theme: Spots.dark(),
      darkTheme: Spots.dark(),
      home: MusicShell(
        initialServer: initialServer,
        onServerChanged: onServerChanged,
      ),
    );
  }
}

/// Spotify-desktop layout:
/// ┌───────────┬─────────────────────────┬──────────┐
/// │  sidebar  │       content           │ (queue)  │
/// ├───────────┴─────────────────────────┴──────────┤
/// │                bottom player bar               │
/// └────────────────────────────────────────────────┘
class MusicShell extends StatefulWidget {
  const MusicShell({
    super.key,
    required this.initialServer,
    required this.onServerChanged,
  });

  final String initialServer;
  final ValueChanged<String> onServerChanged;

  @override
  State<MusicShell> createState() => _MusicShellState();
}

class _MusicShellState extends State<MusicShell> {
  late ApiClient _api;
  late String _serverUrl;
  int _root = 0; // 0 Home · 1 Search · 2 Staging
  bool _queueOpen = false;
  final List<PlaylistInfo> _overlay = [];
  Key _sidebarKey = UniqueKey();
  final ValueNotifier<Set<String>> liked = ValueNotifier({});
  StreamSubscription? _volSub;
  // set during connection checks; drives the red dot + banner
  // ignore: unused_field
  bool _checking = false;
  String? _connError;

  static const _genreByPlaylist = {
    'jazz': 'jazz',
    'heavy': 'heavy metal',
    'osts': 'soundtrack',
  };

  @override
  void initState() {
    super.initState();
    _serverUrl = widget.initialServer;
    _api = ApiClient(baseUrl: _normalize(_serverUrl));
    final qp = QueuePlayer.instance;
    qp.resolveVideo = (vid) => _api.resolve(vid);
    qp.fetchSimilar = (source, {excludeTitles = const []}) async {
      final key = source.toLowerCase();
      final genre = _genreByPlaylist[key];
      final res = await _api.similar(genre ?? '$source songs',
          excludeTitles: excludeTitles);
      return [
        for (final d in res)
          QueueItem('${d.artist} - ${d.title}', 'yt:${d.videoId}',
              thumbUrl:
                  'https://i.ytimg.com/vi/${d.videoId}/hqdefault.jpg',
              videoId: d.videoId,
              genreHint: source)
      ];
    };
    _restoreVolume();
    _loadLiked();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkConn());
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _volSub?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<void> _restoreVolume() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getDouble('volume');
    if (v != null) await QueuePlayer.instance.setVolume(v);
    QueuePlayer.instance.volume.addListener(_saveVolume);

  }

  Future<void> _saveVolume() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('volume', QueuePlayer.instance.volume.value);
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final focus = FocusManager.instance.primaryFocus;
    final inField =
        focus?.context?.widget is EditableText;
    if (inField) return false;
    final qp = QueuePlayer.instance;
    if (e.logicalKey == LogicalKeyboardKey.space) {
      qp.playing ? qp.pause() : qp.resume();
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      qp.seek(qp.position.value + const Duration(seconds: 5));
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      qp.seek(qp.position.value - const Duration(seconds: 5));
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.slash) {
      setState(() => _root = 1);
      return true;
    }
    return false;
  }

  void _toggleLiked(String baseName) {
    final has = liked.value.contains(baseName);
    if (has) {
      _api
          .removeFromPlaylist('Liked', baseName: baseName)
          .catchError((_) {});
      liked.value = {...liked.value}..remove(baseName);
    } else {
      // server auto-downloads unknown tracks straight into Liked/
      _api.addToPlaylist(baseName: baseName, playlist: 'Liked').then((_) {
        liked.value = {...liked.value, baseName};
        _sidebarKey = UniqueKey(); // new file may appear in sidebar
        if (mounted) setState(() {});
      }).catchError((e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Like failed: $e')));
        }
      });
    }
  }

  Future<void> _loadLiked() async {
    try {
      final entries = await _api.playlistEntries('Liked');
      liked.value = {
        for (final e in entries)
          if (e.exists) e.baseName
      };
    } catch (_) {}
  }

  String _normalize(String raw) {
    var s = raw.trim();
    if (!s.startsWith('http')) s = 'http://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Future<void> _editServer() async {
    final controller = TextEditingController(text: _serverUrl);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Server address'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'http://host:6680'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        _serverUrl = controller.text.trim();
        _api = ApiClient(baseUrl: _normalize(_serverUrl));
        _overlay.clear();
        _sidebarKey = UniqueKey();
      });
      widget.onServerChanged(_serverUrl);
      _checkConn();
    }
  }

  Timer? _retryTimer;

  Future<void> _checkConn({bool silent = false}) async {
    if (!mounted) return;
    setState(() {
      _checking = true;
      if (!silent) _connError = null;
    });
    try {
      await _api.ping();
      if (!mounted) return;
      setState(() {
        _connError = null;
        _checking = false;
      });
      _retryTimer?.cancel();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connError =
            'Can\'t reach server at $_normalize(_serverUrl)';
        _checking = false;
      });
      _retryTimer?.cancel();
      // keep retrying quietly every 10s while offline
      _retryTimer = Timer(const Duration(seconds: 10), () {
        if (mounted && _connError != null) _checkConn(silent: true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    return wide ? _desktop() : _mobile();
  }

  // ------------------------------------------------------------- desktop
  Widget _desktop() {
    return Scaffold(
      backgroundColor: Spots.base,
      body: Column(children: [
        Expanded(
          child: Row(children: [
            SideBar(
              api: _api,
              serverUrl: _normalize(_serverUrl),
              onEditServer: _editServer,
              rootIndex: _root,
              onSelectRoot: (i) => setState(() {
                _root = i;
                _overlay.clear();
              }),
              onOpenPlaylist: (p) => setState(() => _overlay
                ..remove(p)
                ..add(p)),
              onPlayPlaylist: (p, {required bool shuffled}) =>
                  _playPlaylist(p, shuffled: shuffled),
              refreshKey: _sidebarKey,
              onLibraryChanged: () =>
                  setState(() => _sidebarKey = UniqueKey()),
              buildId: kBuildId,
            ),
            Expanded(child: _content()),
            AnimatedSize(
              duration: const Duration(milliseconds: 150),
              child: _queueOpen ? _queuePanel() : const SizedBox(width: 0),
            ),
          ]),
        ),
        BottomPlayerBar(
          onToggleQueue: () => setState(() => _queueOpen = !_queueOpen),
          liked: liked,
          onToggleLike: _toggleLiked,
          api: _api,
        ),
      ]),
    );
  }

  Widget _content() {
    final showRoot = _overlay.isEmpty;
    return Stack(children: [
      IndexedStack(index: showRoot ? _root : -1, children: [
        HomeScreen(api: _api, onOpenPlaylist: (p) => setState(() => _overlay
          ..remove(p)
          ..add(p))),
        SearchScreen(
          api: _api,
          onStageStarted: (msg) => ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg))),
        ),
        DownloadsScreen(api: _api),
      ]),
      if (_overlay.isNotEmpty)
        Material(
          color: Spots.base,
          child: PlaylistDetailScreen(
            key: ValueKey(_overlay.last.name),
            api: _api,
            playlist: _overlay.last,
            onPop: () => setState(() => _overlay.removeLast()),
          ),
        ),
    ]);
  }

  // -------------------------------------------------------------- mobile
  Widget _mobile() {
    return Scaffold(
      backgroundColor: Spots.base,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        toolbarHeight: 56,
        title: Text(_root == 0
            ? 'Home'
            : _root == 1
                ? 'Search'
                : 'Staging',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          Stack(clipBehavior: Clip.none, children: [
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined,
                  size: 22, color: Colors.white70),
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => SettingsScreen(
                          api: _api,
                          serverUrl: _normalize(_serverUrl),
                          onServerChanged: (u) {
                            setState(() {
                              _serverUrl = u;
                              _api =
                                  ApiClient(baseUrl: _normalize(u));
                              _overlay.clear();
                            });
                            widget.onServerChanged(u);
                            _sidebarKey = UniqueKey();
                            _checkConn();
                          }))),
            ),
            if (_connError != null)
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                      color: Colors.redAccent,
                      shape: BoxShape.circle),
                ),
              ),
          ]),
        ],
      ),
      body: Column(children: [
        if (_connError != null)
          Material(
            color: Colors.red.shade900,
            child: InkWell(
              onTap: _checkConn,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  const Icon(Icons.wifi_off,
                      size: 16, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(_connError!,
                          style:
                              const TextStyle(fontSize: 12))),
                  const Text('TAP TO RETRY',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          ),
        Expanded(
          child: IndexedStack(index: _root, children: [
            HomeScreen(api: _api, onOpenPlaylist: _openPlaylistMobile),
            SearchScreen(
              api: _api,
              onStageStarted: (msg) => ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(msg))),
            ),
            DownloadsScreen(api: _api),
          ]),
        ),
        const MiniPlayerBar(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _root,
        onDestinationSelected: (i) => setState(() => _root = i),
        backgroundColor: Colors.black,
        indicatorColor: Colors.transparent,
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_filled),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.search_outlined),
              selectedIcon: Icon(Icons.search),
              label: 'Search'),
          NavigationDestination(
              icon: Icon(Icons.download_outlined),
              selectedIcon: Icon(Icons.download_rounded),
              label: 'Staging'),
        ],
      ),
    );
  }

  void _openPlaylistMobile(PlaylistInfo p) {
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => PlaylistDetailScreen(api: _api, playlist: p)),
    ).then((_) => setState(() => _sidebarKey = UniqueKey()));
  }

  Future<void> _playPlaylist(PlaylistInfo p, {required bool shuffled}) async {
    try {
      final entries = await _api.playlistEntries(p.name);
      final q = [
        for (final e in entries)
          if (e.exists && e.url != null)
            QueueItem(e.baseName, _api.fileUrl(e.url!),
                thumbUrl: e.albumImage ?? _api.coverUrl(e.url!),
                genreHint: p.name,
                filePath: e.url)
      ];
      if (q.isNotEmpty) {
        await QueuePlayer.instance.playList(q, startShuffled: shuffled);
      }
    } catch (_) {}
  }
  // ---------------------------------------------------------- queue panel
  Widget _queuePanel() {
    return SizedBox(
        width: 300,
        child: QueuePanel(
            onClose: () => setState(() => _queueOpen = false)));
  }
}

/// Spotify-style queue: circle multi-select, right-click menu,
/// drag-to-reorder, repeat + shuffle toggles.
class QueuePanel extends StatefulWidget {
  const QueuePanel({super.key, this.onClose});
  final VoidCallback? onClose;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  final Set<int> _selected = {};
  final qp = QueuePlayer.instance;

  void _toggleSel(int i) => setState(() {
        _selected.contains(i) ? _selected.remove(i) : _selected.add(i);
      });

  void _jump(int i) {
    if (_selected.isNotEmpty) setState(() => _selected.clear());
    qp.jumpTo(i);
  }

  

  Widget _circleContent(QueueItem it, bool current, bool sel, int i) {
    if (current) {
      return const Icon(Icons.graphic_eq, size: 15, color: Spots.green);
    }
    if (sel) {
      return const Icon(Icons.check, size: 15, color: Spots.green);
    }
    final num = Text('${i + 1}',
        style: const TextStyle(fontSize: 10.5, color: Colors.white38));
    if (it.thumbUrl != null) {
      return ClipOval(
        child: Image.network(it.thumbUrl!,
            width: 26,
            height: 26,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => num),
      );
    }
    return num;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([qp, qp.status]),
      builder: (ctx, _) {
        return Container(
          color: Colors.black,
          margin: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
          child: Column(children: [
            Row(children: [
              const Text('Queue',
                  style:
                      TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const Spacer(),
              Tooltip(
                message: 'Repeat',
                child: InkWell(
                  onTap: qp.cycleRepeat,
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: ValueListenableBuilder<RepeatMode>(
                      valueListenable: qp.repeat,
                      builder: (ctx, rep, _) => Icon(
                          switch (rep) {
                            RepeatMode.one => Icons.repeat_one,
                            RepeatMode.all => Icons.repeat,
                            _ => Icons.repeat_outlined,
                          },
                          size: 17,
                          color: rep == RepeatMode.off
                              ? Colors.white54
                              : Spots.green),
                    ),
                  ),
                ),
              ),
              Tooltip(
                message: 'Shuffle queue',
                child: InkWell(
                  onTap: qp.toggleShuffle,
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: ValueListenableBuilder<bool>(
                      valueListenable: qp.shuffleEnabled,
                      builder: (ctx, shuf, _) => Icon(Icons.shuffle,
                          size: 17,
                          color: shuf ? Spots.green : Colors.white54),
                    ),
                  ),
                ),
              ),
              InkWell(
                onTap: widget.onClose,
                child: const Padding(
                    padding: EdgeInsets.all(4),
                    child:
                        Icon(Icons.close, size: 18, color: Colors.white54)),
              ),
            ]),
            const SizedBox(height: 8),
            AnimatedSize(
              duration: const Duration(milliseconds: 120),
              child: _selected.isEmpty
                  ? const SizedBox.shrink()
                  : Row(children: [
                      Text('${_selected.length} selected',
                          style: const TextStyle(
                              fontSize: 11.5, color: Colors.white54)),
                      const Spacer(),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            textStyle: const TextStyle(fontSize: 12)),
                        onPressed: () => setState(() {
                          qp.playNext(Set.of(_selected));
                          _selected.clear();
                        }),
                        icon: const Icon(Icons.low_priority, size: 15),
                        label: const Text('Play next'),
                      ),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                            textStyle: const TextStyle(fontSize: 12)),
                        onPressed: () => setState(() {
                          qp.removeAt(Set.of(_selected));
                          _selected.clear();
                        }),
                        icon: const Icon(Icons.playlist_remove, size: 15),
                        label: const Text('Remove'),
                      ),
                    ]),
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: qp.revision,
                builder: (ctx, _) {
                  final cur2 = qp.queueIndex.value;
                  if (qp.items.isEmpty) {
                    return const Center(
                        child: Text('Nothing in queue',
                            style: TextStyle(color: Colors.white38)));
                  }
                  return ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    proxyDecorator: (child, idx, anim) => Material(
                        color: Spots.elevated,
                        elevation: 6,
                        borderRadius: BorderRadius.circular(8),
                        child: child),
                    onReorder: (oldI, newI) {
                      if (newI > oldI) newI -= 1;
                      qp.reorder(oldI, newI);
                    },
                    itemCount: qp.items.length,
                    itemBuilder: (ctx, i) {
                      final it = qp.items[i];
                      final current = i == cur2 && qp.hasTrack;
                      final sel = _selected.contains(i);
                      return ReorderableDragStartListener(
                      key: ValueKey('${i}_${it.title}_${it.url}'),
                      index: i,
                      child: GestureDetector(
                        onSecondaryTapUp: (d) =>
                            _menu(context, d.globalPosition, i),
                        child: Container(
                          decoration: BoxDecoration(
                            color: current
                                ? Spots.green.withOpacity(.08)
                                : sel
                                    ? Colors.white.withOpacity(.06)
                                    : null,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: current
                                    ? Spots.green.withOpacity(.35)
                                    : Colors.transparent),
                          ),
                          child: ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            leading: GestureDetector(
                              onTap: () => _toggleSel(i),
                              child: Container(
                                width: 30,
                                height: 30,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: sel
                                          ? Spots.green
                                          : Colors.white24,
                                      width: 1.5),
                                  color: sel
                                      ? Spots.green.withOpacity(.2)
                                      : Colors.transparent,
                                ),
                                child: _circleContent(it, current, sel, i),
                              ),
                            ),
                            title: Text(it.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: current
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: current
                                        ? Spots.green
                                        : sel
                                            ? Colors.white
                                            : Colors.white70)),
                            onTap: () => _jump(i),
                          ),
                        ),
                      ),
                    );
                  },
                );
              }),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 4, left: 4),
              child: Text('Auto-adds more when the queue runs out',
                  style: TextStyle(fontSize: 10.5, color: Colors.white38)),
            ),
          ]),
        );
      },
    );
  }

  /// Right-click: acts on the clicked row when nothing (or only it) is
  /// selected; otherwise on the whole selection.
  Future<void> _menu(BuildContext ctx, Offset pos, int rowIdx) async {
    final targets =
        _selected.isEmpty || _selected.length == 1 && _selected.contains(rowIdx)
            ? <int>{rowIdx}
            : Set.of(_selected);
    final isSingle = targets.length == 1 && targets.first == rowIdx;
    if (!isSingle) setState(() {}); // show menu over selection
    final action = await showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      color: Spots.elevated,
      items: const [
        PopupMenuItem(
            value: 'play',
            child: ListTile(
                dense: true,
                leading: Icon(Icons.play_arrow, size: 18),
                title: Text('Play'))),
        PopupMenuItem(
            value: 'next',
            child: ListTile(
                dense: true,
                leading: Icon(Icons.low_priority, size: 18),
                title: Text('Play next'))),
        PopupMenuItem(
            value: 'remove',
            child: ListTile(
                dense: true,
                leading: Icon(Icons.playlist_remove, size: 18),
                title: Text('Remove from queue'))),
      ],
    );
    if (!mounted || action == null) return;
    setState(() {
      switch (action) {
        case 'play':
          _selected.clear();
          qp.jumpTo(rowIdx);
        case 'next':
          qp.playNext(targets);
        case 'remove':
          qp.removeAt(targets);
      }
      _selected.clear(); // always drop selection after an action
    });
  }
}
