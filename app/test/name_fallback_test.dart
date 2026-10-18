import 'package:flutter_test/flutter_test.dart';
import 'package:nasmusic/queue_player.dart'
    show
        NameResolver,
        QueueItem,
        completionIsFinish,
        deadStreamError,
        nameFallbackOnce;

const deadVid = 'ufub3ysWcvo';

typedef Res = ({
  String url,
  String thumb,
  String? videoId,
  String? album,
  int? durationS,
  bool preview,
});

NameResolver? _resolver(
  Res res,
  void Function() hit, {
  bool throws = false,
}) {
  return (artist, title) async {
    hit();
    if (throws) throw Exception('resolvename down');
    return res;
  };
}

QueueItem _row({String? artist = 'Ozuna', String? title = 'Quiero Repetir'}) =>
    QueueItem(
      '${artist ?? ''} - ${title ?? ''}',
      'http://nas/staging/api/stream?vid=$deadVid',
      resolveName:
          (artist == null || title == null) ? null : (artist: artist, title: title),
      fromInternet: true,
    );

void main() {
  group('dead stream detection', () {
    test('a relay 502 counts', () => expect(deadStreamError('HTTP 502'), isTrue));
    test('a 404 corpse counts', () => expect(deadStreamError('code 404'), isTrue));
    test('401 is an auth problem, not a dead stream', () {
      // 401 must reach onAuthFailure, never burn the one identity swap.
      expect(deadStreamError('401 Unauthorized'), isFalse);
    });
    test('a codec complaint is not a dead stream', () {
      expect(deadStreamError('MediaCodecVideoRenderer error'), isFalse);
    });
  });

  group('dead-stream identity fallback', () {
    test('502 + resolveName -> resolve once, replay the fresh url', () async {
      // ufub3ysWcvo (Ozuna - Quiero Repetir) 502s; the server answers the
      // same song with a working Deezer preview url.
      var calls = 0;
      final fb = await nameFallbackOnce(
        error: 'PlatformException(502, Bad Gateway)',
        item: _row(),
        gen: 7,
        fallbackGen: -1,
        nameResolver: _resolver(
          (
            url: 'https://cdnt-preview.dzcdn.net/a.mp3',
            thumb: '',
            videoId: '',
            album: null,
            durationS: 30,
            preview: true,
          ),
          () => calls++,
        ),
      );
      expect(calls, 1);
      expect(fb.spent, isTrue);
      expect(fb.url, 'https://cdnt-preview.dzcdn.net/a.mp3');
      expect(fb.preview, isTrue, reason: '30s clip must be flagged');
      expect(fb.durationS, 30);
      // A preview swap finishes at 30s instead of healing the clip forever.
      expect(
        completionIsFinish(positionSec: 22, durationSec: 30, isPreview: fb.preview),
        isTrue,
      );
    });

    test('502 without resolveName -> skip, no resolve at all', () async {
      var calls = 0;
      final fb = await nameFallbackOnce(
        error: 'HTTP 502',
        item: _row(artist: null),
        gen: 3,
        fallbackGen: -1,
        nameResolver: _resolver(
          (
            url: 'https://x/fresh.mp3',
            thumb: '',
            videoId: 'v',
            album: null,
            durationS: null,
            preview: false,
          ),
          () => calls++,
        ),
      );
      expect(calls, 0);
      expect(fb.url, isNull);
      expect(fb.spent, isFalse);
    });

    test('no loop: the same attempt never resolves twice', () async {
      var calls = 0;
      var gen = 11;
      final rn = _resolver(
        (
          url: 'https://cdnt-preview.dzcdn.net/a.mp3',
          thumb: '',
          videoId: '',
          album: null,
          durationS: 30,
          preview: true,
        ),
        () => calls++,
      );
      // 502 -> swap (spent)
      final first = await nameFallbackOnce(
        error: '502',
        item: _row(),
        gen: gen,
        fallbackGen: -1,
        nameResolver: rn,
      );
      expect(first.url, isNotNull);
      // The swap ALSO dies -> same gen must not resolve again.
      final second = await nameFallbackOnce(
        error: '502',
        item: _row(),
        gen: gen,
        fallbackGen: gen,
        nameResolver: rn,
      );
      expect(second.url, isNull);
      expect(second.spent, isFalse);
      expect(calls, 1, reason: 'one resolve per play attempt, no loop');

      // A NEW attempt (next tap / next track) gets a fresh swap.
      gen++;
      final third = await nameFallbackOnce(
        error: '502',
        item: _row(),
        gen: gen,
        fallbackGen: gen - 1,
        nameResolver: rn,
      );
      expect(third.url, isNotNull);
      expect(calls, 2);
    });

    test('the same dead url is never handed back as the retry', () async {
      // The 14-day ry: row can still answer the dead video: replaying it
      // would be the same corpse twice.
      var calls = 0;
      final fb = await nameFallbackOnce(
        error: '502',
        item: _row(),
        gen: 4,
        fallbackGen: -1,
        nameResolver: _resolver(
          (
            url: 'http://nas/staging/api/stream?vid=$deadVid',
            thumb: '',
            videoId: deadVid,
            album: null,
            durationS: null,
            preview: false,
          ),
          () => calls++,
        ),
      );
      expect(calls, 1);
      expect(fb.url, isNull);
      expect(fb.spent, isTrue, reason: 'still spent: no second try this attempt');
    });

    test('a dead resolve spends the swap without a url', () async {
      var calls = 0;
      final fb = await nameFallbackOnce(
        error: '502',
        item: _row(),
        gen: 5,
        fallbackGen: -1,
        nameResolver: _resolver(
          (
            url: '',
            thumb: '',
            videoId: null,
            album: null,
            durationS: null,
            preview: false,
          ),
          () => calls++,
          throws: true,
        ),
      );
      expect(calls, 1);
      expect(fb.url, isNull);
      expect(fb.spent, isTrue);
    });

    test('a non-dead error never touches the resolver', () async {
      var calls = 0;
      final fb = await nameFallbackOnce(
        error: 'Connection reset by peer',
        item: _row(),
        gen: 2,
        fallbackGen: -1,
        nameResolver: _resolver(
          (
            url: 'https://x/fresh.mp3',
            thumb: '',
            videoId: 'v',
            album: null,
            durationS: null,
            preview: false,
          ),
          () => calls++,
        ),
      );
      expect(calls, 0);
      expect(fb.url, isNull);
    });
  });
}