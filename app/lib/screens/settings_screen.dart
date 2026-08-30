import 'package:flutter/material.dart';

/// Push the settings page from any tab's app bar.
void openSettings(BuildContext context,
    {required String baseUrl,
    required Future<String?> Function() onServer}) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => SettingsScreen(baseUrl: baseUrl, onServer: onServer),
    ),
  );
}

/// Settings page. Hosts the "Server address" (change server) setting that
/// previously lived as a standalone affordance on the Discover app bar.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen(
      {super.key, required this.baseUrl, required this.onServer});
  final String baseUrl;
  final Future<String?> Function() onServer;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late String _baseUrl = widget.baseUrl;

  Future<void> _changeServer() async {
    final newUrl = await widget.onServer();
    if (newUrl != null && mounted) {
      setState(() => _baseUrl = newUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Connection',
                style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.1,
                    color: Colors.white38)),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server address'),
            subtitle: Text(_baseUrl,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: _changeServer,
          ),
        ],
      ),
    );
  }
}