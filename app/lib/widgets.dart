import 'package:flutter/material.dart';

import 'theme.dart';

/// Deterministic gradient cover with an icon, Spotify-card style.
class CoverArt extends StatelessWidget {
  const CoverArt(
      {super.key,
      this.size = 56,
      this.rounded = 8,
      required this.seed,
      this.icon = Icons.music_note,
      this.networkUrl});

  final double size;
  final double rounded;
  final String seed;
  final IconData icon;
  final String? networkUrl;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      decoration: BoxDecoration(
        gradient: Spots.coverGradient(seed),
        borderRadius: BorderRadius.circular(rounded),
      ),
      child: Icon(icon, size: size * .42, color: Colors.white70),
    );
    if (networkUrl == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(rounded),
      child: Image.network(networkUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback,
          loadingBuilder: (ctx, child, progress) =>
              progress == null ? child : Center(child: SizedBox(width: size * .3, height: size * .3, child: CircularProgressIndicator(strokeWidth: 2)))),
    );
  }
}

/// Spotify-style bottom action menu.
Future<T?> showTrackMenu<T>(
    BuildContext context, String title, List<TrackAction> actions) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    backgroundColor: Spots.elevated,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(ctx)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
        for (final a in actions)
          ListTile(
            leading: Icon(a.icon, color: a.destructive ? Colors.redAccent : null),
            title: Text(a.label),
            onTap: () => Navigator.pop(ctx, a.value),
          ),
        const SizedBox(height: 8),
      ]),
    ),
  );
}

class TrackAction<T> {
  final String label;
  final IconData icon;
  final T value;
  final bool destructive;
  TrackAction(this.label, this.icon, this.value, {this.destructive = false});
}
