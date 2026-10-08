import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Instagram Stories share: minimal background-image ADD_TO_STORY (single
/// asset URI + source_application + grant flags — NO sticker asset: it made
/// Instagram open-then-close), then a direct IG content share (ACTION_SEND
/// pinned to the IG package), then a generic share-sheet + clipboard fallback.
///
/// The Stories composer is fire-and-forget (no result code): a user cancel
/// inside Instagram is unobservable and counts as done. Only a `false` /
/// throw from the platform side (not installed, no artwork on disk) falls
/// back to the generic sheet, then clipboard.

/// Share-tier order for the Instagram target: Stories composer first, then
/// a direct IG feed/message share (ACTION_SEND pinned to the IG package so
/// Instagram itself opens), then save-cover-to-gallery + copy-caption +
/// launch-IG, then copy-link + open-Instagram (no artwork needed, always
/// works — even a Morphe build that rejects the art intents still opens),
/// then the generic system sheet, then clipboard.
/// Clipboard lives in the caller (`_shipShare`/Clipboard fallback).
const instagramShareTierOrder = [
  'shareStory',
  'shareDirectInstagram',
  'shareInstagramFallback',
  'copyLinkOpenInstagram',
  'shareText',
];

/// One logcat line per share-tier attempt/result. print (not just
/// debugPrint: debugPrint is throttled/invisible in release logcats, which
/// is exactly how the 1.0.268 IG tap died with zero output) so a dead tap
/// (no channel call, no intent, no error) leaves a visible trail of exactly
/// which tier died instead of silence.
void shareTrace(String msg) {
  debugPrint('[share] $msg');
  // ignore: avoid_print — release-visible by design (logcat INFO).
  print('[share] $msg');
}

/// Tap-path fallback links when the network resolve hangs: pure search URLs
/// (no resolve needed) so the tap still ships instead of dying silently.
({String ytLink, String spLink}) shareFallbackLinks({
  required String artist,
  required String title,
}) {
  final q = Uri.encodeQueryComponent('$artist $title'.trim());
  return (
    ytLink: 'https://music.youtube.com/search?q=$q',
    spLink: 'https://open.spotify.com/search/$q',
  );
}
/// True when BOTH IG-native tiers failed and the gallery fallback is still
/// needed (last resort before the generic sheet).
bool instagramFallbackNeeded({required bool storyOk, required bool directOk}) =>
    !storyOk && !directOk;

/// True when all IG art tiers failed and the copy-link tier is still
/// needed (last resort before the generic sheet — needs no artwork).
bool instagramCopyLinkNeeded({
  required bool storyOk,
  required bool directOk,
  required bool fallbackOk,
}) =>
    !storyOk && !directOk && !fallbackOk;

/// True when all four IG tiers failed and the generic sheet is still
/// needed (last resort before clipboard).
bool instagramGenericAfterCopyNeeded({
  required bool storyOk,
  required bool directOk,
  required bool fallbackOk,
  required bool copyOk,
}) =>
    !storyOk && !directOk && !fallbackOk && !copyOk;

/// True when all three IG tiers failed and the generic sheet is still
/// needed (last resort before clipboard).
bool instagramGenericAfterFallbackNeeded({
  required bool storyOk,
  required bool directOk,
  required bool fallbackOk,
}) =>
    !storyOk && !directOk && !fallbackOk;

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
  shareTrace('attempt shareStory');
  try {
    const channel = MethodChannel('com.nasmusic.nasmusic/share');
    final sent = await channel.invokeMethod<Object>('shareStory', {
      'link': link,
    });
    final ok = shareTierOk(sent);
    final r = ShareTierResult(ok, ok ? 'ok' : 'story ${sent ?? 'null'}');
    shareTrace('result shareStory ok=${r.ok} detail=${r.detail}');
    return r;
  } catch (e) {
    shareTrace('result shareStory ok=false exception: $e');
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
  shareTrace('attempt shareDirectInstagram');
  try {
    const channel = MethodChannel('com.nasmusic.nasmusic/share');
    final sent = await channel.invokeMethod<Object>('shareDirectInstagram', {
      'text': text,
    });
    final ok = shareTierOk(sent);
    final r = ShareTierResult(ok, ok ? 'ok' : 'direct ${sent ?? 'null'}');
    shareTrace('result shareDirectInstagram ok=${r.ok} detail=${r.detail}');
    return r;
  } catch (e) {
    shareTrace('result shareDirectInstagram ok=false exception: $e');
    return ShareTierResult(false, 'direct exception: $e');
  }
}

/// Platform call (final tier): saves the cover to the gallery, copies the
/// caption to the clipboard, and launches the Instagram app itself.
/// Always works (no fragile Stories/direct API) — the user pastes inside IG.
Future<ShareTierResult> shareInstagramFallbackDetailed({
  required String caption,
}) async {
  shareTrace('attempt shareInstagramFallback');
  try {
    const channel = MethodChannel('com.nasmusic.nasmusic/share');
    final sent = await channel.invokeMethod<Object>('shareInstagramFallback', {
      'text': caption,
    });
    final ok = shareTierOk(sent);
    final r = ShareTierResult(ok, ok ? 'ok' : 'fallback ${sent ?? 'null'}');
    shareTrace('result shareInstagramFallback ok=${r.ok} detail=${r.detail}');
    return r;
  } catch (e) {
    shareTrace('result shareInstagramFallback ok=false exception: $e');
    return ShareTierResult(false, 'fallback exception: $e');
  }
}

/// Platform call (always-works tier): copies the link to the clipboard and
/// opens Instagram itself (launch intent, VIEW fallback). Needs no artwork,
/// so it succeeds even when the Stories/direct/gallery tiers reject the
/// cover (Morphe builds) or there is no cover on disk.
Future<ShareTierResult> shareCopyLinkOpenInstagramDetailed({
  required String link,
  required String caption,
}) async {
  shareTrace('attempt copyLinkOpenInstagram');
  try {
    const channel = MethodChannel('com.nasmusic.nasmusic/share');
    final sent =
        await channel.invokeMethod<Object>('copyLinkOpenInstagram', {
      'link': link,
      'text': caption,
    });
    final ok = shareTierOk(sent);
    final r = ShareTierResult(ok, ok ? 'ok' : 'copylink ${sent ?? 'null'}');
    shareTrace('result copyLinkOpenInstagram ok=${r.ok} detail=${r.detail}');
    return r;
  } catch (e) {
    shareTrace('result copyLinkOpenInstagram ok=false exception: $e');
    return ShareTierResult(false, 'copylink exception: $e');
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
    detail.contains('no IG package found') ||
    (detail.contains('launch-failed') &&
        detail.contains('ActivityNotFoundException'));

/// Share-time gate: true when Instagram can handle a share on this device.
/// Fail-open (true) on desktop / errors so the row never vanishes spuriously.
Future<bool> instagramAvailable() async {
  shareTrace('attempt canShareToInstagram');
  try {
    const channel = MethodChannel('com.nasmusic.nasmusic/share');
    final ok = await channel.invokeMethod<bool>('canShareToInstagram');
    shareTrace('result canShareToInstagram ok=${ok ?? true}');
    return ok ?? true;
  } catch (e) {
    shareTrace('result canShareToInstagram ok=true(fail-open) exception: $e');
    return true;
  }
}

/// Platform call: returns true when the Stories composer was launched.
Future<bool> shareStoryToInstagram({required String link}) async =>
    (await shareStoryDetailed(link: link)).ok;
