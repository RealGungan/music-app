import 'dart:math';

import '../play_log.dart';

/// Deterministic demo listening year (seeded — every device sees the same
/// demo). Lets owner + friends verify the full Wrapped show without
/// waiting a year. Clearly labeled DEMO wherever shown.
List<PlayEvent> demoEvents({int year = 0}) {
  final y = year == 0 ? DateTime.now().year : year;
  final r = Random(20261203);
  const pool = [
    'Marea - El temblor',
    'Marea - Que se me va la vida',
    'Extremoduro - Puta',
    'Extremoduro - Agila',
    'Guns N\' Roses - Sweet Child O\' Mine',
    'Guns N\' Roses - November Rain',
    'Metallica - Enter Sandman',
    'Metallica - Nothing Else Matters',
    'AC/DC - Back In Black',
    'AC/DC - Thunderstruck',
    '2Pac - Can\'t C Me',
    '2Pac - California Love',
    'Eminem - Lose Yourself',
    'Eminem - Mockingbird',
    'Queen - Bohemian Rhapsody',
    'Queen - Don\'t Stop Me Now',
    'Nirvana - Smells Like Teen Spirit',
    'Arctic Monkeys - Do I Wanna Know?',
    'Tame Impala - The Less I Know The Better',
    'Rob Zombie - Dragula',
    'Rammstein - Du Hast',
    'Volbeat - Cheapside Sloggers',
    'Airbourne - Breakin\' Outta Hell',
    'The Offspring - The Kids Aren\'t Alright',
    'Slipknot - Vendetta',
  ];
  final weights = [
    9, 7, 8, 5, 6, 4, 6, 5, 5, 4, 7, 3, 5, 3, 4, 3, 4, 3, 2, 4, 3, 2,
    2, 2, 3,
  ];
  final bag = <int>[];
  for (var i = 0; i < pool.length; i++) {
    for (var k = 0; k < weights[i]; k++) {
      bag.add(i);
    }
  }
  final out = <PlayEvent>[];
  var day = DateTime(y, 1, 3);
  final end = DateTime(y, 11, 20);
  while (day.isBefore(end)) {
    // Skip some days (nobody listens daily).
    if (r.nextDouble() < 0.25) {
      day = day.add(const Duration(days: 1));
      continue;
    }
    final plays = 3 + r.nextInt(9);
    var t = day.add(Duration(hours: 8 + r.nextInt(12)));
    for (var k = 0; k < plays; k++) {
      final song = pool[bag[r.nextInt(bag.length)]];
      final secs = 40 + r.nextInt(260);
      out.add(PlayEvent(
          base: song, atMs: t.millisecondsSinceEpoch, seconds: secs));
      t = t.add(Duration(seconds: secs + 30 + r.nextInt(300)));
    }
    day = day.add(const Duration(days: 1));
  }
  return out;
}
