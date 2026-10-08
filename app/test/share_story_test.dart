import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/share_story.dart';

void main() {
  test('caption carries subject + link', () {
    expect(storyCaption('Artist - Title', 'https://open.spotify.com/track/x'),
        'Artist - Title\nhttps://open.spotify.com/track/x');
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

  test('IG tier order: story -> direct IG -> generic sheet', () {
    expect(instagramShareTierOrder,
        ['shareStory', 'shareDirectInstagram', 'shareText']);
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
            'fail: no-resolve artExists=true artSize=148000 resolve=false authority=com.nasmusic.nasmusic.art'),
        true);
    expect(
        instagramNoResolve(
            'fail: no-resolve artExists=true artSize=148000 resolve={com.instagram.android: false, com.instagram.lite: false} authority=com.nasmusic.nasmusic.art'),
        true);
    expect(instagramNoResolve('ok'), false);
    expect(
        instagramNoResolve(
            'fail: no-art artExists=false artSize=-1 readable=false authority=com.nasmusic.nasmusic.art'),
        false);
  });

  test('tier reply: ok/true succeed, fail-strings/throws fall through', () {
    expect(shareTierOk(true), true);
    expect(shareTierOk('ok'), true);
    expect(shareTierOk('OK'), true);
    expect(shareTierOk(false), false);
    expect(shareTierOk(null), false);
    expect(
        shareTierOk(
            'fail: no-art artExists=false artSize=-1 readable=false authority=com.nasmusic.nasmusic.art'),
        false);
    expect(shareTierOk('fail: no-resolve artExists=true artSize=42 '
        'resolve=false authority=com.nasmusic.nasmusic.art'), false);
  });
}
