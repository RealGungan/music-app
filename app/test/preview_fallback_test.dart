import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nasmusic/api_client.dart' show ApiClient, ResolvedName;
import 'package:nasmusic/now_playing.dart' show previewLabelChip;
import 'package:nasmusic/queue_player.dart'
    show
        QueueItem,
        completionIsFinish,
        previewLabel,
        previewSecs;

class _Fake extends http.BaseClient {
  _Fake(this._respond);
  final http.Response Function(Uri url, String method) _respond;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest req) async {
    final r = _respond(req.url, req.method);
    return http.StreamedResponse(
      Stream.value(r.bodyBytes),
      r.statusCode,
      request: req,
      headers: r.headers,
    );
  }
}

void main() {
  group('preview flag survives the resolveByName url rebase', () {
    test('deezer preview stays flagged after the relay rebuild', () async {
      // The rebase rebuilds ResolvedName from the parsed row; losing the
      // flags here is what made a 30s clip look like a full song.
      final api = ApiClient(
        baseUrl: 'http://music.rg.nig:8004',
        client: _Fake((u, m) => http.Response(
              jsonEncode(const {
                'url': 'https://cdnt-preview.dzcdn.net/x.mp3?hdnea=t',
                'video_id': '',
                'thumb': '',
                'artist': 'Pantera',
                'title': 'Hollow',
                'duration_s': 30,
                'preview': true,
                'preview_sec': 30,
              }),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );
      final r = await api.resolveByName(artist: 'Pantera', title: 'Hollow');
      expect(r.preview, isTrue);
      expect(r.previewSec, 30);
      expect(r.url, contains('dzcdn.net'));
    });

    test('a real relay resolve is not flagged', () async {
      final api = ApiClient(
        baseUrl: 'http://music.rg.nig:8004',
        client: _Fake((u, m) => http.Response(
              jsonEncode(const {
                'url': 'http://100.89.94.101:8004/staging/api/stream?vid=abc',
                'video_id': 'abc',
                'thumb': '',
              }),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );
      final r = await api.resolveByName(artist: 'Pantera', title: 'Hollow');
      expect(r.preview, isFalse);
      expect(r.previewSec, isNull);
      expect(r.url, contains('/staging/api/stream'));
    });
  });
  group('preview flag propagation (server -> item)', () {
    test('resolvename json with preview flags', () {
      final r = ResolvedName.fromJson(const {
        'url': 'https://cdnt-preview.dzcdn.net/x.mp3?hdnea=t',
        'video_id': '',
        'thumb': 'cover.jpg',
        'artist': 'Pantera',
        'title': 'Hollow',
        'duration_s': 30,
        'preview': true,
        'preview_sec': 30,
      });
      expect(r.preview, isTrue);
      expect(r.previewSec, 30);
      expect(r.durationS, 30);
    });

    test('a normal resolve is NOT flagged', () {
      final r = ResolvedName.fromJson(const {
        'url': 'http://nas/staging/api/stream?vid=abc',
        'video_id': 'abc',
        'thumb': '',
      });
      expect(r.preview, isFalse);
      expect(r.previewSec, isNull);
    });

    test('preview item seeds a 30s readout', () {
      // Chunked relays never emit onDurationChanged: without the seed the
      // bar sits at -:-- for the whole clip.
      final it = QueueItem('Pantera - Hollow', 'https://dzcdn/x.mp3',
          preview: true);
      expect(it.preview, isTrue);
      expect(it.durationMs, 30000);
    });

    test('a measured duration wins over the 30s seed', () {
      final it = QueueItem('x', 'u', preview: true, durationMs: 12345);
      expect(it.durationMs, 12345);
    });

    test('non-preview item is untouched', () {
      expect(QueueItem('x', 'u').durationMs, isNull);
      expect(QueueItem('x', 'u').preview, isFalse);
    });

    test('preview survives the url rebase copy', () {
      final it = QueueItem('x', 'u', preview: true)
          .withUrl('https://dzcdn/fresh.mp3');
      expect(it.preview, isTrue);
      expect(it.durationMs, 30000);
    });

    test('label names the length', () {
      expect(previewLabel('Preview'), 'Preview · 30');
      expect(previewSecs, 30);
    });

    test('label chip renders', () {
      expect(previewLabelChip(), isNotNull);
    });
  });

  group('auto-advance rule on completion', () {
    test('a full song plays out -> advance', () {
      expect(
        completionIsFinish(
            positionSec: 218, durationSec: 221, isPreview: false),
        isTrue,
      );
    });

    test('a song that died early is a dropout, not an advance', () {
      expect(
        completionIsFinish(
            positionSec: 12, durationSec: 221, isPreview: false),
        isFalse,
      );
    });

    test('unknown duration advances (unchanged behavior)', () {
      expect(
        completionIsFinish(
            positionSec: 3, durationSec: 0, isPreview: false),
        isTrue,
      );
    });

    test('a preview always advances when the clip runs out', () {
      // 30s clip + relay that reported a stale total: healing it would
      // replay the clip forever instead of moving on.
      expect(
        completionIsFinish(
            positionSec: 22, durationSec: 30, isPreview: true),
        isTrue,
      );
      expect(
        completionIsFinish(
            positionSec: 29, durationSec: 30, isPreview: true),
        isTrue,
      );
    });
  });
}