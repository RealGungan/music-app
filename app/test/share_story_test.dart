import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/share_story.dart';

void main() {
  test('caption carries subject + link', () {
    expect(
      storyCaption('Artist - Title', 'https://open.spotify.com/track/x'),
      'Artist - Title\nhttps://open.spotify.com/track/x',
    );
  });

  test('caption tolerates either half missing', () {
    expect(storyCaption('', 'https://x'), 'https://x');
    expect(storyCaption('Artist - Title', ''), 'Artist - Title');
    expect(storyCaption('', ''), '');
  });

  test('fail path (false/null) falls back, success does not', () {
    expect(storyFallbackNeeded(true), false);
    expect(storyFallbackNeeded(false), true);
    expect(storyFallbackNeeded(null), true); // cancel / no-result == fallback
  });

  test('IG tier order: story -> direct IG -> fallback -> copylink -> sheet', () {
    expect(instagramShareTierOrder, [
      'shareStory',
      'shareDirectInstagram',
      'shareInstagramFallback',
      'copyLinkOpenInstagram',
      'shareText',
    ]);
  });

  test('fallback runs when both IG tiers fail; sheet only after all three', () {
    expect(instagramFallbackNeeded(storyOk: true, directOk: false), false);
    expect(instagramFallbackNeeded(storyOk: false, directOk: true), false);
    expect(instagramFallbackNeeded(storyOk: false, directOk: false), true);
    expect(
      instagramGenericAfterFallbackNeeded(
          storyOk: false, directOk: false, fallbackOk: false),
      true,
    );
    expect(
      instagramGenericAfterFallbackNeeded(
          storyOk: false, directOk: false, fallbackOk: true),
      false,
    );
    expect(
      instagramGenericAfterFallbackNeeded(
          storyOk: true, directOk: false, fallbackOk: false),
      false,
    );
  });

  test('copylink tier runs when all art tiers fail; sheet only after all four',
      () {
    expect(
      instagramCopyLinkNeeded(storyOk: true, directOk: false, fallbackOk: false),
      false,
    );
    expect(
      instagramCopyLinkNeeded(storyOk: false, directOk: false, fallbackOk: true),
      false,
    );
    expect(
      instagramCopyLinkNeeded(
          storyOk: false, directOk: false, fallbackOk: false),
      true,
    );
    expect(
      instagramGenericAfterCopyNeeded(
          storyOk: false, directOk: false, fallbackOk: false, copyOk: false),
      true,
    );
    expect(
      instagramGenericAfterCopyNeeded(
          storyOk: false, directOk: false, fallbackOk: false, copyOk: true),
      false,
    );
    expect(
      instagramGenericAfterCopyNeeded(
          storyOk: false, directOk: false, fallbackOk: true, copyOk: false),
      false,
    );
  });

  test('fallback no-package detail means not installed', () {
    expect(
      instagramNoResolve(
        'fail: launch-failed artExists=true artSize=42 authority=com.nasmusic.nasmusic.art err=no IG package found',
      ),
      true,
    );
  });

  test('generic sheet only when both IG tiers fail', () {
    expect(instagramGenericNeeded(storyOk: true, directOk: false), false);
    expect(instagramGenericNeeded(storyOk: false, directOk: true), false);
    expect(instagramGenericNeeded(storyOk: true, directOk: true), false);
    expect(instagramGenericNeeded(storyOk: false, directOk: false), true);
  });

  test('no-resolve detail gates the IG row (log-proven both pkgs)', () {
    expect(
      instagramNoResolve(
        'fail: no-resolve artExists=true artSize=148000 resolve=false authority=com.nasmusic.nasmusic.art',
      ),
      true,
    );
    expect(
      instagramNoResolve(
        'fail: no-resolve artExists=true artSize=148000 resolve={com.instagram.android: false, com.instagram.lite: false} authority=com.nasmusic.nasmusic.art',
      ),
      true,
    );
    expect(instagramNoResolve('ok'), false);
    expect(
      instagramNoResolve(
        'fail: no-art artExists=false artSize=-1 readable=false authority=com.nasmusic.nasmusic.art',
      ),
      false,
    );
  });

  test('launch-first: ActivityNotFound in both tiers means not installed', () {
    const story =
        'fail: launch-failed artExists=true artSize=148000 authority=com.nasmusic.nasmusic.art err=com.instagram.android: android.content.ActivityNotFoundException';
    const direct =
        'fail: launch-failed artExists=true artSize=148000 authority=com.nasmusic.nasmusic.art err=com.instagram.android: android.content.ActivityNotFoundException | com.instagram.lite: android.content.ActivityNotFoundException';
    expect(instagramNoResolve(story), true);
    expect(instagramNoResolve(direct), true);
  });

  test('launch-first: other launch errors are NOT not-installed', () {
    expect(
      instagramNoResolve(
        'fail: launch-failed artExists=true artSize=42 authority=com.nasmusic.nasmusic.art err=com.instagram.android: java.lang.SecurityException: permission denial',
      ),
      false,
    );
    expect(instagramNoResolve('ok'), false);
  });

  test('tap-timeout fallback links are pure search URLs (no resolve)', () {    final fb = shareFallbackLinks(artist: 'Artist', title: 'Title');
    expect(
      fb.ytLink,
      'https://music.youtube.com/search?q=${Uri.encodeQueryComponent('Artist Title')}',
    );
    expect(
      fb.spLink,
      'https://open.spotify.com/search/${Uri.encodeQueryComponent('Artist Title')}',
    );
  });

  test('tier reply: ok/true succeed, fail-strings/throws fall through', () {
    expect(shareTierOk(true), true);
    expect(shareTierOk('ok'), true);
    expect(shareTierOk('OK'), true);
    expect(shareTierOk(false), false);
    expect(shareTierOk(null), false);
    expect(
      shareTierOk(
        'fail: no-art artExists=false artSize=-1 readable=false authority=com.nasmusic.nasmusic.art',
      ),
      false,
    );
    expect(
      shareTierOk(
        'fail: no-resolve artExists=true artSize=42 '
        'resolve=false authority=com.nasmusic.nasmusic.art',
      ),
      false,
    );
  });

  test('gallery-save tier writes shared Pictures/ (IG-picker visible)', () {
    // Must match MainActivity.kt RELATIVE_PATH — app-private files are
    // invisible to the IG picker.
    expect(instagramGalleryRelativePath, 'Pictures/NASMusic');
    expect(instagramGalleryRelativePath.startsWith('Pictures/'), true);
  });

  test('Stories/direct tiers stay first (gallery is fallback only)', () {
    expect(instagramShareTierOrder[0], 'shareStory');
    expect(instagramShareTierOrder[1], 'shareDirectInstagram');
    expect(instagramShareTierOrder.indexOf('shareInstagramFallback'),
        greaterThan(1));
  });

  test('shareTrace never throws (dead-tap logging is total)', () {
    shareTrace('tap test');
    shareTrace('attempt shareStory');
    shareTrace('result shareStory ok=false detail=fail: test');
  });

  test('tiers fail with exception detail when channel throws', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const ch = MethodChannel('com.nasmusic.nasmusic/share');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (_) async {
      throw PlatformException(code: 'dead-channel');
    });
    try {
      // Fail-open probe: row stays, tap still attempts the tiers.
      expect(await instagramAvailable(), true);
      final story = await shareStoryDetailed(link: 'https://x');
      expect(story.ok, false);
      expect(story.detail, contains('exception'));
      final direct = await shareDirectDetailed(text: 'cap');
      expect(direct.ok, false);
      expect(direct.detail, contains('exception'));
      final fb = await shareInstagramFallbackDetailed(caption: 'cap');
      expect(fb.ok, false);
      expect(fb.detail, contains('exception'));
      final cp = await shareCopyLinkOpenInstagramDetailed(
          link: 'https://x', caption: 'cap');
      expect(cp.ok, false);
      expect(cp.detail, contains('exception'));
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
    }
  });
}
