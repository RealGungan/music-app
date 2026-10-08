import 'package:flutter/services.dart';

/// Instagram Stories share: sticker (artwork) + attribution link via the
/// platform Stories API (`com.instagram.share.ADD_TO_STORY`), with a
/// generic share-sheet + clipboard fallback.
///
/// The Stories composer is fire-and-forget (no result code): a user cancel
/// inside Instagram is unobservable and counts as done. Only a `false` /
/// throw from the platform side (not installed, no artwork on disk) falls
/// back to the generic sheet, then clipboard.

/// `subject\nlink` caption used for the generic-sheet fallback.
String storyCaption(String subject, String link) {
  final s = subject.trim();
  final l = link.trim();
  if (s.isEmpty) return l;
  if (l.isEmpty) return s;
  return '$s\n$l';
}

/// True when the Stories attempt needs the generic fallback (fail path).
/// Cancel/fail both surface as `false`/`null` (or a throw, handled by the
/// caller) — never as an error toast: the clipboard fallback covers it.
bool storyFallbackNeeded(Object? sent) => sent != true;

/// Platform call: returns true when the Stories composer was launched.
Future<bool> shareStoryToInstagram({required String link}) async {
  try {
    const channel = MethodChannel('com.nasmusic.nasmusic/share');
    final sent = await channel.invokeMethod<bool>('shareStory', {
      'link': link,
    });
    return sent == true;
  } catch (_) {
    return false;
  }
}
