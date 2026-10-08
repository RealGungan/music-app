import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/lyrics_sheet.dart';

void main() {
  test('block follows the anchor side', () {
    expect(lyricBlock(3, 5, 5), (3, 5, false));
    expect(lyricBlock(5, 3, 5), (3, 5, false));
    expect(lyricBlock(4, 4, 5), (4, 4, false));
  });

  test('block clamps to max keeping the anchor', () {
    expect(lyricBlock(2, 9, 5), (2, 6, true));
    expect(lyricBlock(9, 2, 5), (5, 9, true));
  });

  test('fit shrinks long wrapped blocks, keeps short ones full', () {
    expect(lyricFitSize(560.0, 640.0, ['short', 'lines']), 28.0);
    final long = lyricFitSize(300.0, 300.0,
        List.filled(3, 'Knock-knock-knockin on heavens door ooh yeah'));
    expect(long, lessThan(28.0));
    expect(long, greaterThanOrEqualTo(14.0));
  });

  test('card fit predicts overflow', () {
    const w = 400.0;
    const h = 860.0;
    expect(lyricFitsCard(w, h, ['short', 'lines']), true);
    expect(
        lyricFitsCard(
            w, h, List.filled(9, 'Knock-knock-knockin on heavens door ooh yeah')),
        false);
    expect(lyricFitsCard(w, h, []), true);
  });

  test('card fit counts system font scale', () {
    const w = 400.0;
    const h = 860.0;
    // Short enough to fit the default card at 1.0 even in the wide test
    // font (on-device Roboto has room to spare either way).
    final lines = List.filled(3, 'Why does it feel like night?');
    expect(lyricFitsCard(w, h, lines), true);
    expect(lyricFitsCard(w, h, lines, textScale: 2.0), false);
    expect(
        lyricFitSize(560.0, 640.0, ['short'], textScale: 2.0), 28.0);
  });

  test('papercut verse: five lines fit a standard phone card', () {
    // Short lines without ?/' (those glyphs fall back to a wider font
    // in tests); on-device Roboto fits the full verse the same way
    // (same 5-line intent).
    const lines = [
      'Feel like night today',
      'Something is not right',
      'Why so uptight today',
      'Feels like night today',
      'Night is on my side',
    ];
    expect(lyricFitsCard(412.0, 915.0, lines), true);
  });

  // Hybrid Theory ground truth: grey concrete dominates by share, with a
  // small vivid red soldier accent. Percentage wins: background is grey,
  // and the red accent still shows as the second gradient stop.
  test('sampler: grey cover with red accent goes grey, red second', () {
    final grey = [45.0, 0.05, 0.55]; // concrete: low saturation
    final red = [5.0, 0.45, 0.30]; // soldier
    final rows = [
      ...List.filled(56, grey),
      ...List.filled(8, red),
    ];
    final (a, b, card) = sampleCardColors(rows);
    // top share is neutral grey: channels close together
    expect((a.red - a.green).abs(), lessThan(25));
    expect((a.red - a.blue).abs(), lessThan(25));
    // second share is the red accent
    expect(b.red, greaterThan(b.blue + 20));
    // card is a dark neutral, not red
    expect(card.red, lessThan(60));
    expect((card.red - card.blue).abs(), lessThan(20));
  });

  test('sampler: top-3 shares paint the three slots', () {
    final red = [5.0, 0.5, 0.4];
    final blue = [220.0, 0.5, 0.4];
    final green = [130.0, 0.5, 0.4];
    final rows = [
      ...List.filled(32, red),
      ...List.filled(20, blue),
      ...List.filled(12, green),
    ];
    final (a, b, card) = sampleCardColors(rows);
    expect(a.red, greaterThan(a.blue + 40));
    expect(b.blue, greaterThan(b.red + 40));
    expect(card.green, greaterThan(card.red));
  });

  test('sampler: all-grey art stays grey, never a noise hue', () {
    final rows = List.filled(64, [50.0, 0.04, 0.55]);
    final (a, b, card) = sampleCardColors(rows);
    // neutral grey gradient: channels close together, mid lightness
    expect((a.red - a.blue).abs(), lessThan(25));
    expect(a.red, greaterThan(60));
    expect(a.red, lessThan(170));
    // card is a dark neutral
    expect(card.red, lessThan(60));
    expect((card.red - card.green).abs(), lessThan(15));
  });
  test('sampler: dark pixels never force a black card', () {
    final rows = [
      ...List.filled(48, [0.0, 0.0, 0.04]),
      ...List.filled(16, [5.0, 0.5, 0.35]),
    ];
    final (a, b, card) = sampleCardColors(rows);
    // the gradient still carries the accent hue
    expect(a.red, greaterThan(a.blue + 40));
    // card is a DARK SHADE OF THE ACCENT (third share falls back to the
    // first), not black: red-dominant and visibly lit
    expect(card.red, greaterThan(card.blue + 10));
    expect(card.red, greaterThan(30));
  });

  // Fairies Wear Boots (2026-09-28): the picker refused lines the card
  // visibly had room for. The gate and the renderer now share the exact
  // box (lyricCardBox) and real font measurement, so this locks their
  // agreement directly: gate allows ⟺ the fitted render fits, on small
  // and big screens, in any test font.
  test('fit: gate allows exactly what the renderer draws', () {
    const verse = [
      "Goin' home late last night",
      'Suddenly, I got a fright',
      'Yeah, I looked through a window and surprised what I saw',
    ];
    const verse4 = [...verse, 'Fairies wear boots and you gotta believe me'];
    const fiveShort = ['one', 'two', 'three', 'four', 'five'];
    final wall = List.filled(
        12, 'Knock-knock-knockin on heavens door ooh yeah');
    for (final s in [(360.0, 720.0), (400.0, 800.0), (412.0, 915.0)]) {
      final (bw, bh) = lyricCardBox(s.$1, s.$2);
      for (final c in [verse, verse4, fiveShort, wall]) {
        final gate = lyricFitsCard(s.$1, s.$2, c);
        final size = lyricFitSize(bw, bh, c);
        if (gate) {
          var used = 0.0;
          for (final l in c) {
            used += lyricLineHeight(l, size, bw) + 12;
          }
          expect(used, lessThanOrEqualTo(bh + 0.5),
              reason: '$c must render inside ${s.$1}x${s.$2}');
        } else {
          // Refused ⟹ even the 14sp floor overflows: the fitter bottoms out.
          expect(size, 14.0, reason: 'refused $c on ${s.$1}x${s.$2}');
        }
      }
    }
    // Boundaries: short lines fit even small; a wall never does.
    expect(lyricFitsCard(360.0, 720.0, ['one', 'two', 'three']), true);
    expect(lyricFitsCard(360.0, 720.0, wall), false);
  });
}