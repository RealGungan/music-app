import 'dart:async';

import 'package:flutter/material.dart';

import 'lang.dart';
import 'theme.dart';

/// Short, bright notification shown at the TOP of the screen instead of a
/// dark bottom snackbar. Only one is visible at a time.
void toast(BuildContext context, String msg,
    {IconData icon = Icons.check_circle,
    Color? background,
    Color iconColor = Colors.black87}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return; // navigator context has no Overlay ancestor
  toastInOverlay(overlay, msg, icon: icon, background: background, iconColor: iconColor);
}

/// Same toast, but targets a specific Overlay — required whenever the only
/// context available is the ROOT NAVIGATOR's own context, which is an ANCESTOR
/// of the Overlay (the Overlay is built as navigator's child). [Overlay.of]
/// on that context returns null (and a release `null!` throws), silently
/// killing the caller — exactly the deep-link failure. Use
/// `_navigatorKey.currentState?.overlay` as [overlay].
void toastInOverlay(OverlayState overlay, String msg,
    {IconData icon = Icons.check_circle,
    Color? background,
    Color iconColor = Colors.black87}) {
  _ToastState._clear();
  final topInset =
      MediaQuery.of(overlay.context).padding.top + 10;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => Positioned(
      top: topInset,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: background ?? Spots.green,
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black54,
                    blurRadius: 18,
                    offset: Offset(0, 6)),
              ],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 10),
              Flexible(
                child: Text(msg,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.black87,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  _ToastState._show(entry);
}

class _ToastState {
  static OverlayEntry? _entry;
  static Timer? _timer;

  static void _show(OverlayEntry e) {
    _entry = e;
    _timer = Timer(const Duration(milliseconds: 1600), _clear);
  }

  static void _clear() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }
}

/// Shared delete-undo bar (the playlist-tab pattern, used everywhere):
/// green, fades in on show, auto-hides after [milliseconds], swipes away
/// horizontally. One instance at a time — a new call replaces the old bar.
void showUndoBar(BuildContext context, String message,
    FutureOr<void> Function() onUndo,
    {int milliseconds = 3000}) {
  _UndoBarState.hide();
  final sheet = showBottomSheet(
    context: context,
    builder: (_) => Dismissible(
      key: const ValueKey('undo-bar'),
      direction: DismissDirection.horizontal,
      confirmDismiss: (_) async {
        _UndoBarState.hide();
        return false;
      },
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 300),
        builder: (_, v, child) => Opacity(opacity: v, child: child),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Spots.green,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.black87, fontWeight: FontWeight.w600),
                ),
              ),
              GestureDetector(
                onTap: () {
                  _UndoBarState.hide();
                  onUndo();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  child: Text(
                    tr('UNDO'),
                    style: const TextStyle(
                        color: Colors.black87,
                        fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  _UndoBarState.sheet = sheet;
  _UndoBarState.timer =
      Timer(Duration(milliseconds: milliseconds), _UndoBarState.hide);
}

class _UndoBarState {
  static PersistentBottomSheetController? sheet;
  static Timer? timer;

  static void hide() {
    timer?.cancel();
    timer = null;
    try {
      sheet?.close();
    } catch (_) {}
    sheet = null;
  }
}