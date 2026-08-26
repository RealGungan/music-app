import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'bottom_player.dart';
import 'build_id.dart';
import 'player.dart' show MiniPlayerBar;
import 'queue_player.dart';
import 'screens/downloads_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_tab.dart';
import 'screens/playlist_detail.dart';
import 'screens/queue_panel.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
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

  // mobile: 0 home · 1 search · 2 library · 3 staging(full page)
  int _root = 0;
  bool _stagingOpen = false;
  bool _queueOpen = false;
  final List<PlaylistInfo> _overlay = [];
  Key _sidebarKey = UniqueKey();

  bool _checking = false;
  String? _connError;
  Timer? _retryTimer;

  final ValueNotifier<Set<String>> liked = ValueNotifier({});
  StreamSubscription? _volSub;

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

  String _normalize(String raw) {
    var s = raw.trim();
    if (!s.startsWith('http')) s = 'http://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  void _applyServer(String u) {
    setState(() {
      _serverUrl = u;
      _api = ApiClient(baseUrl: _normalize(u));
      _overlay.clear();
      _stagingOpen = false;
      _sidebarKey = UniqueKey();
    });
    widget.onServerChanged(u);
    _checkConn();
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
    if (focus?.context?.widget is EditableText) return false;
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
      setState(() => _root = _root == 1 ? 0 : 1);
      return true;
    }
    return false;
  }

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
        _connError = "Can't reach server at $_normalize(_serverUrl)";
        _checking = false;
      });
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 10), () {
        if (mounted && _connError != null) _checkConn(silent: true);
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

  void _toggleLiked(String baseName) {
    final has = liked.value.contains(baseName);
    if (has) {
      _api.removeFromPlaylist('Liked', baseName: baseName).catchError((_) {});
      liked.value = {...liked.value}..remove(baseName);
    } else {
      _api.addToPlaylist(baseName: baseName, playlist: 'Liked').then((_) {
        liked.value = {...liked.value, baseName};
        _sidebarKey = UniqueKey();
        if (mounted) setState(() {});
      }).catchError((e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Like failed: $e')));
        }
      });
    }
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

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => SettingsScreen(
              api: _api,
              serverUrl: _normalize(_serverUrl),
              onServerChanged: _applyServer)),
    ).then((_) {
      if (mounted) setState(() => _sidebarKey = UniqueKey());
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
                const Icon(Icons.wifi_off, size: 16, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(_connError!,
                        style: const TextStyle(fontSize: 12))),
                const Text('TAP TO RETRY',
                    style:
                        TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        )
      ];

  // ============================== BUILD ==============================
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    final body = Stack(children: [
      // tabs / library / staging / detail live here per platform
      if (wide) _desktopContent() else _mobileTabs(),
      if (_overlay.isNotEmpty && !wide)
        Material(
          color: Spots.base,
          child: PlaylistDetailScreen(
            key: ValueKey(_overlay.last.name),
            api: _api,
            playlist: _overlay.last,
            onPop: () => setState(() => _overlay.removeLast()),
          ),
        ),
      if (_stagingOpen)
        Material(
          color: Spots.base,
          child: DownloadsScreen(
              api: _api, onBack: () => setState(() => _stagingOpen = false)),
        ),
    ]);

    final nav = wide
        ? const SizedBox.shrink()
        : NavigationBar(
            selectedIndex: (_overlay.isNotEmpty || _stagingOpen) ? -1 : (_root > 2 ? 2 : _root),
            onDestinationSelected: (i) => setState(() {
              _root = i;
              _overlay.clear();
              _stagingOpen = false;
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
            ],
          );

    return Scaffold(
      backgroundColor: Spots.base,
      body: SafeArea(
        bottom: false,
        child: wide
            ? Column(children: [
                if (_checking)
        const LinearProgressIndicator(minHeight: 2),
      if (_connError != null) ..._connBanner(),
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
                        _stagingOpen = false;
                      }),
                      onOpenPlaylist: (p) =>
                          setState(() => _overlay..remove(p)..add(p)),
                      onPlayPlaylist: (p, {required bool shuffled}) =>
                          _playPlaylist(p, shuffled: shuffled),
                      refreshKey: _sidebarKey,
                      onLibraryChanged: () =>
                          setState(() => _sidebarKey = UniqueKey()),
                      buildId: kBuildId,
                    ),
                    Expanded(child: body),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 150),
                      child: _queueOpen
                          ? _queuePanel()
                          : const SizedBox(width: 0),
                    ),
                  ]),
                ),
                BottomPlayerBar(
                  onToggleQueue: () =>
                      setState(() => _queueOpen = !_queueOpen),
                  liked: liked,
                  onToggleLike: _toggleLiked,
                  api: _api,
                ),
              ])
            : Column(children: [
                if (_checking)
        const LinearProgressIndicator(minHeight: 2),
      if (_connError != null) ..._connBanner(),
                Expanded(child: body),
                const MiniPlayerBar(),
              ]),
            ),          // SafeArea
      bottomNavigationBar: wide
          ? null
          : nav,
    );
  }

  // ------------------------- mobile tab pages -------------------------
  Widget _mobileTabs() {
    switch (_root) {
      case 0:
        return HomeScreen(
            api: _api, onOpenPlaylist: _openPlaylistMobile, onOpenSettings: _openSettings);
      case 1:
        return SearchScreen(
          api: _api,
          onStageStarted: (msg) => ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg))),
        );
      case 2:
        return LibraryTab(
          api: _api,
          onOpenPlaylist: _openPlaylistMobile,
          onGotoStaging: () => setState(() => _stagingOpen = true),
        );
      default:
        return DownloadsScreen(api: _api);
    }
  }

  void _openPlaylistMobile(PlaylistInfo p) {
    setState(() {
      _overlay
        ..remove(p)
        ..add(p);
    });
  }

  // ------------------------- desktop region -------------------------
  Widget _desktopContent() {
    return Stack(children: [
      IndexedStack(index: _overlay.isEmpty ? _root : -1, children: [
        HomeScreen(
          api: _api,
          onOpenPlaylist: (p) => setState(() => _overlay..remove(p)..add(p)),
          onOpenSettings: _openSettings,
        ),
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

  Widget _queuePanel() {
    return SizedBox(width: 300, child: QueuePanel(onClose: () => setState(() => _queueOpen = false)));
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
      _applyServer(controller.text.trim());
    }
  }
}
