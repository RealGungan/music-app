import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'player.dart';
import 'screens/downloads_screen.dart';
import 'screens/library_screen.dart';
import 'screens/search_screen.dart';
import 'queue_player.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  QueuePlayer.instance; // wire completion -> next()
  final prefs = await SharedPreferences.getInstance();
  runApp(MusicApp(
    initialServer:
        prefs.getString('server_url') ?? 'http://192.168.1.50:6680',
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
      home: HomeShell(
        initialServer: initialServer,
        onServerChanged: onServerChanged,
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.initialServer,
    required this.onServerChanged,
  });

  final String initialServer;
  final ValueChanged<String> onServerChanged;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late String _serverUrl;
  ApiClient? _api;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _serverUrl = widget.initialServer;
    _api = ApiClient(baseUrl: _normalize(_serverUrl));
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
          decoration: const InputDecoration(
              hintText: 'http://192.168.1.50:6680'),
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
      });
      widget.onServerChanged(_serverUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = _api!;
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _editServer,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.dns, size: 18),
            const SizedBox(width: 6),
            Text(_normalize(_serverUrl), style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 4),
            const Icon(Icons.edit, size: 14),
          ]),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.settings_input_component),
              tooltip: 'Change server', onPressed: _editServer),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              SearchScreen(
                api: api,
                onStageStarted: (msg) => ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(msg))),
              ),
              LibraryScreen(api: api),
              DownloadsScreen(api: api),
            ],
          ),
        ),
        const MiniPlayerBar(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.travel_explore_outlined),
              selectedIcon: Icon(Icons.travel_explore),
              label: 'Discover'),
          NavigationDestination(
              icon: Icon(Icons.library_music_outlined),
              selectedIcon: Icon(Icons.library_music),
              label: 'Library'),
          NavigationDestination(
              icon: Icon(Icons.download_outlined),
              selectedIcon: Icon(Icons.download),
              label: 'Staging'),
        ],
      ),
    );
  }
}
