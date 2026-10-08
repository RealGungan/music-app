import 'package:flutter/services.dart';

/// Instagram Stories share: sticker (artwork) + attribution link via the
/// platform Stories API (`com.instagram.share.ADD_TO_STORY`), then a direct
/// IG content share (ACTION_SEND pinned to the IG package), then a
/// generic share-sheet + clipboard fallback.
///
/// The Stories composer is fire-and-forget (no result code): a user cancel
/// inside Instagram is unobservable and counts as done. Only a `false` /
/// throw from the platform side (not installed, no artwork on disk) falls
/// back to the generic sheet, then clipboard.

/// Share-tier order for the Instagram target: Stories composer first, then
/// a direct IG feed/message share (ACTION_SEND pinned to the IG package so
/// Instagram itself opens), then the generic system sheet, then clipboard.
/// Clipboard lives in the caller (`_shipShare`/Clipboard fallback).
const instagramShareTierOrder = [
  'shareStory',
  'shareDirectInstagram',
  'shareText',
];

/// True when BOTH IG-native tiers failed and the generic sheet is still
/// needed (last resort before clipboard).
bool instagramGenericNeeded({required bool storyOk, required bool directOk}) =>
    !storyOk && !directOk;

/// `subject\nlink` caption used for the generic-sheet fallback.
String storyCaption(String subject, String link) {
  final s = subject.trim();
  final l = link.trim();
  if (s.isEmpty) return l;
  if (l.isEmpty) return s;
  return '$s\n$l';
}

/// True when the Stories attempt needs the generic fallback (fail path).
/// Cancel/fail both surface as `false`/`null`/`fail:...` (or a throw,
/// handled by the caller) — never as an error toast: the clipboard fallback
/// covers it.
bool storyFallbackNeeded(Object? sent) => !shareTierOk(sent);

/// Detail for one IG tier attempt: `ok` when the composer opened, else a
/// native diagnostic (exception text + resolveActivity result + art file
/// exists/size + authority) for User errors. The native side returns the
/// string 'ok' on success, else 'fail: ...'.
class ShareTierResult {
  final bool ok;
  final String detail;
  const ShareTierResult(this.ok, this.detail);
}

/// True when a native tier reply means success ('ok' or legacy bool true).
bool shareTierOk(Object? sent) => sent == true || sent == 'ok' || sent == 'OK';

/// Platform call with detail: returns ok + native diagnostic string.
Future<ShareTierResult> shareStoryDetailed({required String link}) async {
  try {
    const channel = MethodChannel('com.nasmusic.nasmusic/share');
    final sent = await channel.invokeMethod<Object>('shareStory', {
      'link': link,
    });
    final ok = shareTierOk(sent);
    return ShareTierResult(ok, ok ? 'ok' : 'story ${sent ?? 'null'}');
  } catch (e) {
    return ShareTierResult(false, 'story exception: $e');
  }
}

/// Platform call (middle tier): returns true when Instagram itself was
/// opened with the artwork + caption via ACTION_SEND pinned to the IG
/// package. False = IG missing / no art on disk / launch failed → caller
/// falls back to the generic sheet, then clipboard.
Future<bool> shareDirectToInstagram({required String text}) async =>
    (await shareDirectDetailed(text: text)).ok;

/// Platform call (middle tier) with detail.
Future<ShareTierResult> shareDirectDetailed({required String text}) async {
  try {
    const channel = MethodChannel('com.nasmusic.nasmusic/share');
    final sent = await channel.invokeMethod<Object>('shareDirectInstagram', {
      'text': text,
    });
    final ok = shareTierOk(sent);
    return ShareTierResult(ok, ok ? 'ok' : 'direct ${sent ?? 'null'}');
  } catch (e) {
    return ShareTierResult(false, 'direct exception: $e');
  }
}

/// True when a native IG detail means "Instagram can't handle a share"
/// (neither full nor Lite launched). Launch-first: the native side tries
/// startActivity per package and reports the caught exception, so a missing
/// IG surfaces as launch-failed + ActivityNotFoundException (the legacy
/// no-resolve string is kept for older builds). The chooser row is only
/// ever labeled by this, never hard-blocked — the tiers are always attempted.
bool instagramNoResolve(String detail) =>
    detail.contains('no-resolve') ||
    (detail.contains('launch-failed') &&
        detail.contains('ActivityNotFoundException'));

/// Share-time gate: true when Instagram can handle a share on this device.
/// Fail-open (true) on desktop / errors so the row never vanishes spuriously.
Future<bool> instagramAvailable() async {
  try {
    const channel = MethodChannel('com.nasmusic.nasmusic/share');
    final ok = await channel.invokeMethod<bool>('canShareToInstagram');
    return ok ?? true;
  } catch (_) {
    return true;
  }
}

/// Platform call: returns true when the Stories composer was launched.
Future<bool> shareStoryToInstagram({required String link}) async =>
    (await shareStoryDetailed(link: link)).ok;
