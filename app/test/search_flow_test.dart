import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:music_app/api_client.dart';
import 'package:music_app/screens/search_screen.dart';

/// ApiClient with canned responses — no network.
class FakeApi extends ApiClient {
  FakeApi() : super(baseUrl: 'http://test');
  int searchCalls = 0;
  String lastQuery = '';

  @override
  Future<SearchResultPage> search(String q) async {
    searchCalls++;
    lastQuery = q;
    if (q == 'fail') throw ApiException(500, 'boom');
    return SearchResultPage(local: [
      LocalResult(
          baseName: 'Metallica - Fuel',
          folder: 'Heavy',
          url: '/staging/file/Heavy/Metallica - Fuel.mp3'),
    ], discovery: [
      DiscoveryResult(
        videoId: 'abc123',
        artist: 'Metallica',
        title: 'Fuel',
        channel: 'Metallica - Topic',
        durationS: 275,
        score: 50,
        tier: 0,
        streamUri: 'staging:yt:abc123',
      ),
    ]);
  }
}

Future<void> _typeAndSubmit(WidgetTester tester, String q) async {
  await tester.enterText(find.byType(TextField), q);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('mobile-size search flow end to end', (tester) async {
    tester.view.physicalSize = const Size(412, 915); // phone
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    final api = FakeApi();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SafeArea(
          child: SearchScreen(api: api, onStageStarted: (_) {}),
        ),
      ),
    ));

    await _typeAndSubmit(tester, 'Metallica - Fuel');

    expect(api.searchCalls, 1, reason: 'submit should hit the API once');
    expect(find.textContaining('IN YOUR LIBRARY'), findsOneWidget);
    expect(find.textContaining('DISCOVER'), findsOneWidget);
    expect(find.text('Metallica - Fuel', skipOffstage: false),
        findsAtLeastNWidgets(2)); // local tile + discovery tile
  });

  testWidgets('failed search surfaces an error, stays usable',
      (tester) async {
    final api = FakeApi();
    String? stageMsg;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SearchScreen(
            api: api,
            onStageStarted: (m) => stageMsg = m),
      ),
    ));
    await _typeAndSubmit(tester, 'fail');
    expect(stageMsg, contains('Search failed'));
    // still functional afterwards:
    await _typeAndSubmit(tester, 'ok now');
    expect(find.textContaining('IN YOUR LIBRARY'), findsOneWidget);
  });
}
