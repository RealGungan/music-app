import 'package:flutter/material.dart';

import '../theme.dart';
import '../lang.dart';
import 'player_layout_screen.dart';

/// Look & feel: theme preset + nav-bar style + full-player style. Persisted
/// via ThemeStore / UiStore (SharedPreferences), applied instantly.
class UiConfigScreen extends StatelessWidget {
  const UiConfigScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Look & feel'))),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _SectionTitle('Theme'),
          const _SectionHint(
            'Colors are applied everywhere (nav, player, library).',
          ),
          ...AppThemes.all.map((t) => _ThemeTile(theme: t)),
          const Divider(height: 24),
          const _SectionTitle('Bottom bar'),
          const _SectionHint(
            'How the tab bar at the bottom of the home screen looks.',
          ),
          ..._optionTiles(
            kNavStyleOptions,
            current: () => UiStore.instance.navStyle,
            onPick: UiStore.instance.setNavStyle,
          ),
          const Divider(height: 24),
          const _SectionTitle('Full player'),
          const _SectionHint("Rearrange the player's control buttons below."),
          ListTile(
            leading: const Icon(Icons.tune, color: Colors.white54),
            title: Text(tr('Arrange buttons')),
            subtitle: const Text(
              'Drag the control buttons into your preferred order',
              style: TextStyle(fontSize: 12, color: Colors.white38),
            ),
            trailing: const Icon(Icons.open_in_new, color: Colors.white38),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlayerLayoutScreen()),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _optionTiles(
    List<UiOption> options, {
    required String Function() current,
    required Future<void> Function(String) onPick,
  }) {
    return [
      for (final o in options)
        ListenableBuilder(
          listenable: UiStore.instance,
          builder: (context, _) => _OptionTile(
            icon: o.icon,
            title: o.name,
            selected: current() == o.id,
            onTap: () => onPick(o.id),
          ),
        ),
    ];
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          letterSpacing: 1.1,
          color: Colors.white38,
        ),
      ),
    );
  }
}

class _SectionHint extends StatelessWidget {
  const _SectionHint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, color: Colors.white38),
      ),
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({required this.theme});
  final AppTheme theme;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeStore.instance,
      builder: (context, _) {
        final active = ThemeStore.instance.current.id == theme.id;
        return ListTile(
          leading: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: theme.elevated,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: active ? theme.accent : Colors.white24,
                width: active ? 2 : 1,
              ),
            ),
            child: Center(
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: theme.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          title: Text(theme.name),
          trailing: active
              ? Icon(Icons.check_circle, color: theme.accent)
              : null,
          onTap: () => ThemeStore.instance.set(theme.id),
        );
      },
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: selected ? Spots.green : Colors.white54),
      title: Text(tr(title)),
      subtitle: Text(
        selected ? tr('Current') : tr('Select to apply'),
        style: const TextStyle(fontSize: 12, color: Colors.white38),
      ),
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: selected ? Spots.green : Colors.white38,
      ),
      onTap: onTap,
    );
  }
}
