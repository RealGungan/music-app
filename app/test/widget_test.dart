import 'package:flutter_test/flutter_test.dart';

import 'package:nasmusic/api_client.dart';

void main() {
  final api = ApiClient(baseUrl: 'http://localhost:6680');

  test('fileUrl percent-encodes path segments but keeps the base intact', () {
    expect(
      api.fileUrl('/staging/file/Liked/Daft Punk - Get Lucky.mp3'),
      'http://localhost:6680/staging/file/Liked/Daft%20Punk%20-%20Get%20Lucky.mp3',
    );
    expect(
      api.fileUrl("/staging/pl/Heavy/2Pac, Big Syke - All Eyez On Me (ft. Big Syke).mp3"),
      'http://localhost:6680/staging/pl/Heavy/2Pac%2C%20Big%20Syke%20-%20All%20Eyez%20On%20Me%20(ft.%20Big%20Syke).mp3',
    );
  });

  test('coverUrl normalises file and playlist paths', () {
    expect(
      api.coverUrl('/staging/file/Liked/song.mp3'),
      'http://localhost:6680/staging/api/cover?f=Liked%2Fsong.mp3',
    );
    expect(
      api.coverUrl('/staging/pl/Liked/song.mp3'),
      'http://localhost:6680/staging/api/cover?f=pl%3ALiked%2Fsong.mp3',
    );
  });
}
