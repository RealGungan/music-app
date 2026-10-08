import 'package:flutter/material.dart';

import '../now_playing.dart';
import '../theme.dart';
import '../lang.dart';

/// Full-screen editor for the now-playing control buttons.
///
/// The editor IS the real Now Playing screen rendered in edit mode
/// ([NowPlayingScreen.editMode]): same artwork, same slider, same transport
/// row and the same five control buttons — nothing fake. Every button is
/// inert (tapping does nothing). The five control buttons sit in a horizontal
/// row that you drag directly (press + move, no long-press) to rearrange;
/// orders are persisted to [UiStore.playerOrder] the moment you drop them.
class PlayerLayoutScreen extends StatelessWidget {
  const PlayerLayoutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Spots.base,
      child: Stack(
        children: [
          const NowPlayingScreen(editMode: true),
          // Floating chips float over the real screen (art is centered, so the
          // top strip is free). Title-position selector top-left; Reset
          // (top-right) restores the default button order.
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: ListenableBuilder(
                  listenable: UiStore.instance,
                  builder: (context, _) {
                    final cur = UiStore.instance.titleStyle;
                    final curProgress = UiStore.instance.progressStyle;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final o in kPlayerTitleOptions) ...[
                              _OptionChip(
                                option: o,
                                active: cur == o.id,
                                onTap: () =>
                                    UiStore.instance.setTitleStyle(o.id),
                              ),
                              if (o != kPlayerTitleOptions.last)
                                const SizedBox(width: 6),
                            ],
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final o in kPlayerProgressOptions) ...[
                              _OptionChip(
                                option: o,
                                active: curProgress == o.id,
                                onTap: () =>
                                    UiStore.instance.setProgressStyle(o.id),
                              ),
                              if (o != kPlayerProgressOptions.last)
                                const SizedBox(width: 6),
                            ],
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          tr(
                              'Drag buttons to reorder. Hold one, then drop it on a transport slot to move it there.'),
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white54),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          // Reset restores the default button order.
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Material(
                  color: Spots.elevated,
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => UiStore.instance.resetPlayerLayout(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.restart_alt, size: 18),
                          const SizedBox(width: 6),
                          Text(tr('Reset'), style: const TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small pill showing one [UiOption]; highlights when it is the active choice.
class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.option,
    required this.active,
    required this.onTap,
  });

  final UiOption option;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? Spots.green : Spots.elevated,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(option.icon, size: 18, color: Colors.white),
              const SizedBox(width: 6),
              Text(option.name, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}
