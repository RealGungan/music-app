import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nasmusic/api_client.dart';

void main() {
  test('cancel/abort errors are noise on any path', () {
    expect(isNetNoise('/api/search', TimeoutException('cancelled')), true);
    expect(
        isNetNoise('/api/radio', http.ClientException('aborted', Uri())),
        true);
    expect(
        isNetNoise(
            '/api/resolvename', const SocketException('Connection closed')),
        true);
    expect(
        isNetNoise(
            '/api/resolvename', const SocketException('Connection reset')),
        true);
  });

  test('suggest timeouts are noise (UI ignores them already)', () {
    expect(
        isNetNoise('/staging/api/suggest', TimeoutException('after 8s')),
        true);
    expect(
        isNetNoise('/staging/api/suggest',
            const SocketException('Failed host lookup')),
        true);
  });

  test('real timeouts on other paths still log', () {
    expect(
        isNetNoise('/staging/api/search', TimeoutException('after 30s')),
        false);
    expect(
        isNetNoise('/staging/api/radio',
            const SocketException('Connection timed out')),
        false);
  });

  test('DNS failure detected, plain timeouts are not', () {
    expect(
        isDnsFailure(const SocketException(
            'Failed host lookup: naboo.taildfeb4f.ts.net')),
        true);
    expect(
        isDnsFailure(
            const SocketException('Network is unreachable, errno = 101')),
        true);
    expect(isDnsFailure(TimeoutException('after 30s')), false);
    expect(
        isDnsFailure(const SocketException('Connection timed out')), false);
  });
}
