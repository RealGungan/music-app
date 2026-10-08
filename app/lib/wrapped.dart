import '../play_log.dart';

/// One ranked row.
class RankRow {
  final String name;
  final int streams;
  final int seconds;
  RankRow(this.name, this.streams, this.seconds);
}

/// Wrapped statistics over play events, Spotify methodology.
class WrappedStats {
  final int totalStreams;
  final int totalSeconds;
  final int distinctSongs;
  final int distinctArtists;
  final List<RankRow> topSongs;
  final List<RankRow> topArtists;
  final Map<String, String> artistMonth;

  /// Listened seconds behind each sprint winner (same key as [artistMonth]).
  final Map<String, int> artistMonthSecs;
  final String? biggestDay;
  final int biggestDaySeconds;

  WrappedStats({
    required this.totalStreams,
    required this.totalSeconds,
    required this.distinctSongs,
    required this.distinctArtists,
    required this.topSongs,
    required this.topArtists,
    required this.artistMonth,
    this.artistMonthSecs = const {},
    required this.biggestDay,
    required this.biggestDaySeconds,
  });

  static String primaryArtist(String base) {
    var a = base.contains(' - ') ? base.split(' - ').first : base;
    for (final sep in ['feat.', 'feat', 'ft.', 'ft', 'with', '&', ',']) {
      final i = a.toLowerCase().indexOf(sep);
      if (i > 0) {
        a = a.substring(0, i);
        break;
      }
    }
    return a.trim();
  }

  static String songTitle(String base) {
    if (!base.contains(' - ')) return base.trim();
    return base.split(' - ').sublist(1).join(' - ').trim();
  }

  static WrappedStats compute(List<PlayEvent> events, {int? year}) {
    final evs = year == null
        ? events
        : events.where((e) =>
            DateTime.fromMillisecondsSinceEpoch(e.atMs).year == year);
    final songStreams = <String, int>{};
    final songSecs = <String, int>{};
    final artStreams = <String, double>{};
    final artSecs = <String, int>{};
    final monthTop = <String, Map<String, int>>{};
    final monthSecs = <String, Map<String, int>>{};
    final daySecs = <String, int>{};
    var totalSecs = 0;
    var streams = 0;
    final artists = <String>{};
    for (final e in evs) {
      totalSecs += e.seconds;
      artists.add(primaryArtist(e.base));
      final d = DateTime.fromMillisecondsSinceEpoch(e.atMs);
      final dk =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      daySecs[dk] = (daySecs[dk] ?? 0) + e.seconds;
      if (e.seconds <= 30) continue;
      streams++;
      songStreams[e.base] = (songStreams[e.base] ?? 0) + 1;
      songSecs[e.base] = (songSecs[e.base] ?? 0) + e.seconds;
      final parts = e.base.split(' - ');
      final names = parts.isNotEmpty
          ? parts.first
              .split(RegExp(r'[,/&]'))
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList()
          : <String>[];
      for (var i = 0; i < names.length; i++) {
        final w = i == 0 ? 1.0 : 0.5;
        artStreams[names[i]] = (artStreams[names[i]] ?? 0) + w;
        artSecs[names[i]] = (artSecs[names[i]] ?? 0) + e.seconds;
      }
      final mk =
          '${d.year}-${d.month.toString().padLeft(2, '0')}';
      final m = monthTop.putIfAbsent(mk, () => {});
      final pa = primaryArtist(e.base);
      m[pa] = (m[pa] ?? 0) + 1;
      final ms = monthSecs.putIfAbsent(mk, () => {});
      ms[pa] = (ms[pa] ?? 0) + e.seconds;
    }
    List<RankRow> top(Map<String, int> counts, Map<String, int> secs) {
      final keys = counts.keys.toList()
        ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
      return keys
          .take(5)
          .map((k) => RankRow(k, counts[k]!, secs[k] ?? 0))
          .toList();
    }

    final songRows = top(songStreams, songSecs);
    final artKeys = artStreams.keys.toList()
      ..sort((a, b) => artStreams[b]!.compareTo(artStreams[a]!));
    final artRows = artKeys
        .take(5)
        .map(
            (k) => RankRow(k, artStreams[k]!.round(), artSecs[k] ?? 0))
        .toList();
    final months = monthTop.keys.toList()..sort();
    final sprint = <String, String>{};
    final sprintSecs = <String, int>{};
    for (final m in months) {
      final t = monthTop[m]!.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (t.isNotEmpty) {
        sprint[m] = t.first.key;
        sprintSecs[m] = monthSecs[m]?[t.first.key] ?? 0;
      }
    }
    String? bigDay;
    var bigSecs = 0;
    daySecs.forEach((d, s) {
      if (s > bigSecs) {
        bigSecs = s;
        bigDay = d;
      }
    });
    return WrappedStats(
      totalStreams: streams,
      totalSeconds: totalSecs,
      distinctSongs: songStreams.length,
      distinctArtists: artists.length,
      topSongs: songRows,
      topArtists: artRows,
      artistMonth: sprint,
      artistMonthSecs: sprintSecs,
      biggestDay: bigDay,
      biggestDaySeconds: bigSecs,
    );
  }
}
