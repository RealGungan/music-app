import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'keep_dialog.dart';
import 'queue_player.dart';
import 'screens/library_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/staging_screen.dart';
import 'theme.dart';
import 'widgets.dart';

const _kServerKey = 'server_base_url';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final base = prefs.getString(_kServerKey) ??
      (const String.fromEnvironment('NASMUSIC_SERVER').isNotEmpty
          ? const String.fromEnvironment('NASMUSIC_SERVER')
          : 'http://music.rg.nig:8004');
  runApp(NasMusicApp(baseUrl: base));
}

class NasMusicApp extends StatefulWidget {
  const NasMusicApp({super.key, required this.baseUrl});
  final String baseUrl;

  @override
  State<NasMusicApp> createState() => _NasMusicAppState();
}

class _NasMusicAppState extends State<NasMusicApp> {
  late String _baseUrl = widget.baseUrl;
  late ApiClient _api = ApiClient(baseUrl: _baseUrl);
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    QueuePlayer.instance.lastError.addListener(_onPlayError);
  }

  @override
  void dispose() {
    QueuePlayer.instance.lastError.removeListener(_onPlayError);
    super.dispose();
  }

  void _onPlayError() {
    final e = QueuePlayer.instance.lastError.value;
    final messenger = _messengerKey.currentState;
    if (e == null || messenger == null) return;
    messenger.showSnackBar(
        SnackBar(content: Text('Playback failed: $e'), duration: const Duration(seconds: 4)));
  }

  Future<String?> _changeServer() async {
    final controller = TextEditingController(text: _baseUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Server address'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'http://music.rg.nig:8004'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (result == null || result.isEmpty || result == _baseUrl) return null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kServerKey, result);
    setState(() {
      _baseUrl = result;
      _api = ApiClient(baseUrl: result);
    });
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return ServerContext(
      api: _api,
      child: MaterialApp(
        title: 'NASMusic',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: _messengerKey,
        theme: Spots.dark(),
        home: _HomeShell(
          api: _api,
          baseUrl: _baseUrl,
          onServer: _changeServer,
        ),
      ),
    );
  }
}

class _HomeShell extends StatefulWidget {
  const _HomeShell(
      {required this.api, required this.baseUrl, required this.onServer});
  final ApiClient api;
  final String baseUrl;
  final Future<String?> Function() onServer;

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(children: [
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              LibraryScreen(api: widget.api, onServer: widget.onServer),
              HomeTab(api: widget.api, onServer: widget.onServer),
              StagingScreen(api: widget.api, onServer: widget.onServer),
            ],
          ),
        ),
        const MiniPlayerBar(),
        NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music),
                label: 'Library'),
            NavigationDestination(
                icon: Icon(Icons.search), label: 'Discover'),
            NavigationDestination(
                icon: Icon(Icons.download_outlined),
                selectedIcon: Icon(Icons.download),
                label: 'Staging'),
          ],
        ),
      ]),
    );
  }
}

/// Search tab (separate Scaffold so the search field sits under its AppBar).
class HomeTab extends StatelessWidget {
  const HomeTab({super.key, required this.api, required this.onServer});
  final ApiClient api;
  final Future<String?> Function() onServer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => openSettings(context,
                baseUrl: api.baseUrl, onServer: onServer),
          ),
        ],
      ),
      body: SearchScreen(api: api),
    );
  }
}
