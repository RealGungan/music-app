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
import 'screens/library_tab.dart';
import 'screens/playlist_detail.dart';
import 'screens/queue_panel.dart';
import 'screens/search_screen.dart';

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
  // ------------------------------------------------------------- desktop
  Widget _desktop() {
    return Scaffold(
      backgroundColor: Spots.base,
      body: Column(children: [
        if (_connError != null) ..._connBanner(),
        Expanded(
          child: Row(children: [
            SideBar(
              api: _api,
              serverUrl: _normalize(_serverUrl),
              onEditServer: _editServer,
              rootIndex: _root > 2 ? 2 : _root,
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
    return Stack(children: [
      IndexedStack(index: _overlay.isEmpty ? _root : -1, children: [
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

  Widget _mobile() {
    return Scaffold(
      backgroundColor: Spots.base,
      body: Column(children: [
        if (_connError != null) ..._connBanner(),
        Expanded(
          child: Stack(children: [
            IndexedStack(
              index: _overlay.isEmpty ? _root : -1,
              children: [
                HomeScreen(api: _api, onOpenPlaylist: _openPlaylistMobile),
                SearchScreen(
                  api: _api,
                  onStageStarted: (msg) => ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(msg))),
                ),
                LibraryTab(
                  api: _api,
                  onOpenPlaylist: _openPlaylistMobile,
                  onGotoStaging: () => setState(() => _root = 3),
                ),
                DownloadsScreen(api: _api),
              ],
            ),
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
          ]),
        ),
        const MiniPlayerBar(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _root > 2 ? 0 : (_root == 3 ? 3 : _root),
        onDestinationSelected: (i) => setState(() {
          _root = i;
          _overlay.clear();
        }),
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
              icon: Icon(Icons.library_music_outlined),
              selectedIcon: Icon(Icons.library_music),
              label: 'Library'),
          NavigationDestination(
              icon: Icon(Icons.library_music_outlined),
              selectedIcon: Icon(Icons.library_music),
              label: 'Library'),
          NavigationDestination(
              icon: Icon(Icons.download_outlined),
              selectedIcon: Icon(Icons.download_rounded),
              label: 'Staging'),
        ],
      ),
    );
  }

  void _openPlaylistMobile(PlaylistInfo p) {
    setState(() {
      _overlay
        ..remove(p)
        ..add(p);
    });
  }

  List<Widget> _connBanner() => [
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
        )
      ];

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
