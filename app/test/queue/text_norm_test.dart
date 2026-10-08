import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/queue/text_norm.dart';

void main() {
  group('norm', () {
    test('lowercases and strips diacritics', () {
      expect(norm('Café Résumé'), 'cafe resume');
      expect(norm('Ñoño'), 'nono');
      expect(norm('Über Cool'), 'uber cool');
    });

    test('collapses non-alphanumeric to spaces', () {
      expect(norm('a-b_c  d'), 'abc d');
      expect(norm('hello!world?'), 'helloworld');
    });
  });

  group('normCore', () {
    test('strips parenthesized tags', () {
      expect(normCore('Song (2017 Remaster)'), 'song');
      expect(normCore('Title [feat. Artist]'), 'title');
      expect(normCore('Track {Live}'), 'track');
    });

    test('strips tags with diacritics', () {
      expect(normCore('Canción (Remasterizada)'), 'cancion');
    });

    test('empty string', () {
      expect(normCore(''), '');
    });
  });

  group('normArtist', () {
    test('strips feat./ft./with/& and everything after', () {
      expect(normArtist('Metallica'), 'metallica');
      expect(normArtist('Metallica feat. Jason Newsted'), 'metallica');
      expect(normArtist('Metallica ft. Jason Newsted'), 'metallica');
      expect(normArtist('Metallica featuring Jason Newsted'), 'metallica');
      expect(normArtist('Metallica & Symphony'), 'metallica');
      expect(normArtist('Metallica with Symphony'), 'metallica');
    });

    test('preserves artist name when no joiners', () {
      expect(normArtist('Guns N\' Roses'), 'guns n roses');
    });

    test('case insensitive feat matching', () {
      expect(normArtist('Artist FEAT. Someone'), 'artist');
      expect(normArtist('Artist Feat Someone'), 'artist');
    });
  });

  group('titleSimilarity', () {
    test('exact match after normalization', () {
      expect(titleSimilarity('In Da Club', 'In da club'), 1.0);
    });

    test('tag variants match', () {
      final score = titleSimilarity(
        'The Unforgiven II',
        'The Unforgiven II (Live)',
      );
      expect(score, greaterThanOrEqualTo(0.85));
    });

    test('word subset containment', () {
      final score = titleSimilarity(
        'In Da Club',
        'In da club (feat. 50 Cent)',
      );
      expect(score, greaterThanOrEqualTo(0.85));
    });

    test('different songs have low similarity', () {
      final score = titleSimilarity('Stairway to Heaven', 'Bohemian Rhapsody');
      expect(score, lessThan(0.3));
    });
  });

  group('artistSimilarity', () {
    test('identical artist after normalization', () {
      expect(artistSimilarity('Metallica', 'METALLICA'), 1.0);
      expect(artistSimilarity('Guns N Roses', 'Guns N\' Roses'), 1.0);
    });

    test('containment gives 0.75', () {
      final score = artistSimilarity('Metallica', 'Metallica Symphonica');
      expect(score, greaterThanOrEqualTo(0.75));
    });

    test('different artists', () {
      final score = artistSimilarity('Metallica', 'Radiohead');
      expect(score, lessThan(0.3));
    });
  });

  group('songSimilarity', () {
    test('same song high score', () {
      final score = songSimilarity(
        artistA: 'Metallica', titleA: 'Enter Sandman',
        artistB: 'Metallica', titleB: 'Enter Sandman',
      );
      expect(score, greaterThan(0.9));
    });

    test('same title different artist moderate', () {
      final score = songSimilarity(
        artistA: 'Metallica', titleA: 'Enter Sandman',
        artistB: 'Apocalyptica', titleB: 'Enter Sandman',
      );
      expect(score, greaterThan(0.4));
    });

    test('completely different songs near zero', () {
      final score = songSimilarity(
        artistA: 'Metallica', titleA: 'Enter Sandman',
        artistB: 'Radiohead', titleB: 'Creep',
      );
      expect(score, lessThan(0.15));
    });
  });

  group('tokenJaccard', () {
    test('identical token sets', () {
      expect(tokenJaccard('hello world', 'hello world'), 1.0);
    });

    test('disjoint sets', () {
      expect(tokenJaccard('hello world', 'foo bar'), 0.0);
    });

    test('partial overlap', () {
      final score = tokenJaccard('hello world foo', 'hello world bar');
      expect(score, closeTo(2 / 4, 0.01));
    });

    test('empty strings', () {
      expect(tokenJaccard('', ''), 1.0);
      expect(tokenJaccard('hello', ''), 0.0);
    });
  });

  group('normTokens', () {
    test('splits and normalizes', () {
      final tokens = normTokens('Hello World  Café');
      expect(tokens, contains('hello'));
      expect(tokens, contains('world'));
      expect(tokens, contains('cafe'));
    });

    test('empty string', () {
      expect(normTokens(''), isEmpty);
    });
  });

  group('accent fold coverage', () {
    test('all Latin-1 accented chars fold', () {
      expect(norm('áéíóú'), 'aeiou');
      expect(norm('àèìòù'), 'aeiou');
      expect(norm('äëïöü'), 'aeiou');
      expect(norm('ñ'), 'n');
      expect(norm('ß'), 'ss');
    });
  });
  group('server exclude norms', () {
    test('excludeNorm matches scorer.py norm() shape (no spaces, title-only)',
        () {
      // What the server compares against: norm("Si te vas") == "sitevas".
      expect(excludeNorm('Extremoduro - Si te vas'), 'sitevas');
      expect(
          excludeNorm('Marea - Que se me va la vida'), 'quesemevalavida');
      expect(excludeNorm('bare title'), 'baretitle');
    });
  });
}
