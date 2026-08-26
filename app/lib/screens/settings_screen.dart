import 'package:flutter/material.dart';

import '../api_client.dart';
import '../build_id.dart';
import '../queue_player.dart';
import '../theme.dart';

/// Spotify-style settings page: server, playback, about.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.api, required this.serverUrl, required this.onServerChanged});

  final ApiClient api;
  final String serverUrl;
  final ValueChanged<String> onServerChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool _checking;
  String? _error;
  Map<String, dynamic>? _info;
  bool? _discovery;

  @override
  void initState() {
    super.initState();
    _checking = true;
    _test();
  }

  Future<void> _test() async {
    if (mounted) setState(() => _checking = true);
    try {
      await widget.api.ping();
      if (!mounted) return;
      try {
        final j = await widget.api.info();
        _info = j;
        _discovery = await widget.api.discoveryAvailable();
      } catch (_) {}
      _error = null;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _checking = false);
  }

  Future<void> _editServer() async {
    final c = TextEditingController(text: widget.serverUrl);
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Server address'),
        content: TextField(
            controller: c,
            autofocus: true,
            decoration:
                const InputDecoration(hintText: 'http://192.168.1.x:6680')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    var s = url;
    if (!s.startsWith('http')) s = 'http://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    widget.onServerChanged(s);
    await Future.delayed(const Duration(milliseconds: 50));
    _test();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Spots.base,
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.only(bottom: 90), children: [
        const SizedBox(height: 6),
        _section('Server'),
        ListTile(
          leading: Icon(
              _checking
                  ? Icons.sync
                  : (_error == null ? Icons.check_circle : Icons.cancel),
              size: 22,
              color: _checking
                  ? Colors.white38
                  : (_error == null ? Spots.green : Colors.redAccent)),
          title: const Text('Server address'),
          subtitle: Text(widget.serverUrl,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: TextButton(onPressed: _editServer, child: const Text('Edit')),
          onTap: _editServer,
        ),
        ListTile(
          leading: Icon(
              _checking
                  ? Icons.sync
                  : (_error == null
                      ? Icons.wifi
                      : Icons.wifi_off),
              size: 22,
              color: _checking
                  ? Colors.white38
                  : (_error == null ? Spots.green : Colors.redAccent)),
          title: const Text('Test connection'),
          subtitle: Text(_checking
              ? 'Checking…'
              : (_error == null
                  ? 'Connected'
                  : _error!.replaceFirst('API 0: ', ''))),
          onTap: _test,
        ),
        if (_info != null) ...[
          ListTile(
              leading: const Icon(Icons.folder_outlined, size: 22),
              title: const Text('Library folder'),
              subtitle: Text(_info!['music_root'] ?? '',
                  style: const TextStyle(fontSize: 11.5))),
          ListTile(
              leading: const Icon(Icons.schedule_outlined, size: 22),
              title: const Text('Staging folder'),
              subtitle: Text(_info!['staging_dir'] ?? '',
                  style: const TextStyle(fontSize: 11.5))),
          ListTile(
              leading: const Icon(Icons.timer_outlined, size: 22),
              title: const Text('Staging expiry'),
              subtitle: Text('${_info!['expiry_days']} days',
                  style: const TextStyle(fontSize: 11.5))),
        ],
        ListTile(
          leading: Icon(
              Icons.travel_explore,
              size: 22,
              color: _discovery == null
                  ? Colors.white38
                  : (_discovery! ? Spots.green : Colors.redAccent)),
          title: const Text('Song discovery'),
          subtitle: Text(_discovery == null
              ? 'Checking…'
              : _discovery!
                  ? 'YouTube + YouTube Music active'
                  : 'Unavailable — yt-dlp missing on server. Rebuild the container.'),
        ),
        const SizedBox(height: 10),
        _section('Playback'),
        ValueListenableBuilder<double>(
          valueListenable: QueuePlayer.instance.volume,
          builder: (ctx, vol, _) => ListTile(
            leading:
                const Icon(Icons.volume_up_outlined, size: 22),
            title: const Text('Volume'),
            subtitle: Slider(
                max: 1,
                value: vol.clamp(0.0, 1.0),
                onChanged: (v) =>
                    QueuePlayer.instance.setVolume(v)),
            trailing: Text('${(vol * 100).round()}%',
                style: const TextStyle(fontSize: 12)),
          ),
        ),
        const SizedBox(height: 10),
        _section('About'),
        ListTile(
          leading: const Icon(Icons.info_outline, size: 22),
          title: const Text('Build'),
          trailing: Text(kBuildId,
              style: const TextStyle(fontSize: 12, color: Colors.white54)),
        ),
        ListTile(
          leading: const Icon(Icons.music_note_outlined, size: 22),
          title: const Text('Engine'),
          subtitle: const Text(
              'Discovery: YouTube + YouTube Music · verification: Deezer durations · storage: m3u + MP3',
              style: TextStyle(fontSize: 11.5)),
        ),
      ]),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                fontSize: 12,
                letterSpacing: .8,
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.primary)),
      );
}
