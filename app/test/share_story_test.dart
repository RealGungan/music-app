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
}
