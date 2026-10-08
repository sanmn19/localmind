import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/mcp/data/web/keyless_mcp_ring.dart';
import 'package:localmind/features/mcp/data/web/web_search_service.dart';

import 'mcp_fixtures.dart';
import 'stub_dio_adapter.dart';

const exaMcpUrl = 'https://mcp.exa.ai/mcp';
const parallelMcpUrl = 'https://search.parallel.ai/mcp';

String parallelSearchResultJson({String text = 'nothing'}) =>
    jsonEnvelope(0, mcpTextResult(text));

Map<String, List<String>> valueHeaders(Map<String, dynamic> headers) => {
  for (final entry in headers.entries)
    entry.key.toLowerCase(): entry.value is List
        ? (entry.value as List).cast<String>()
        : <String>[entry.value.toString()],
};

String? headerOf(Map<String, List<String>> headers, String name) =>
    headers[name.toLowerCase()]?.firstOrNull;

void main() {
  test('exa handshake and SSE search response maps Title/URL pairs', () async {
    final captured = <RequestOptions>[];
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(
        {},
        sequences: {
          exaMcpUrl: [
            StubResponse(
              200,
              sseEnvelope(0, mcpInitializeResult()),
              headers: {
                'mcp-session-id': ['sess-exa-1'],
              },
            ),
            StubResponse(202, ''),
            StubResponse(200, sseEnvelope(1, mcpTextResult(mcpPairText))),
          ],
        },
        onRequest: captured.add,
      );
    final ring = KeylessMcpRing(dio: dio);
    final results = await ring.search('ring query', numResults: 5);

    expect(results, hasLength(2));
    expect(results[0].title, 'Alpha');
    expect(results[0].url, 'https://a.example/one');
    expect(results[0].snippet, 'first snippet line 1 first snippet line 2');
    expect(results[1].title, 'Beta');
    expect(results[1].url, 'https://a.example/two');
    expect(results[1].snippet, 'second snippet');

    // Handshake: initialize first, then the initialized notification.
    expect(captured[0].uri.toString(), exaMcpUrl);
    final initializeBody = captured[0].data as String;
    expect(initializeBody, contains('"method":"initialize"'));
    expect(initializeBody, contains('"protocolVersion":"2024-11-05"'));
    expect(initializeBody, contains('"localmind"'));
    expect(captured[1].uri.toString(), exaMcpUrl);
    expect(captured[1].data as String, contains('notifications/initialized'));

    // Search call carries the session + protocol version headers.
    expect(captured[2].uri.toString(), exaMcpUrl);
    expect(captured[2].data as String, contains('"web_search_exa"'));
    expect(
      (captured[2].data as String).contains('"query":"ring query"'),
      isTrue,
    );
    expect((captured[2].data as String).contains('"numResults":5'), isTrue);

    final initializeHeaders = valueHeaders(captured[0].headers);
    expect(headerOf(initializeHeaders, 'User-Agent'), webChromeUserAgent);
    expect(headerOf(initializeHeaders, 'Accept-Language'), 'en-US,en;q=0.9');
    expect(headerOf(initializeHeaders, 'Mcp-Session-Id'), isNull);

    final callHeaders = valueHeaders(captured[2].headers);
    expect(headerOf(callHeaders, 'Mcp-Session-Id'), 'sess-exa-1');
    expect(headerOf(callHeaders, 'MCP-Protocol-Version'), '2024-11-05');
    expect(headerOf(callHeaders, 'User-Agent'), webChromeUserAgent);
  });

  test(
    'parallel answers plain JSON and receives objective/search_queries',
    () async {
      final captured = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = StubAdapter(
          {},
          sequences: {
            parallelMcpUrl: [
              StubResponse(
                200,
                jsonEnvelope(0, mcpInitializeResult(name: 'parallel')),
                headers: {
                  'mcp-session-id': ['sess-parallel-1'],
                },
              ),
              StubResponse(202, ''),
              StubResponse(200, parallelSearchResultJson(text: mcpPairText)),
            ],
          },
          onRequest: captured.add,
        );
      final ring = KeylessMcpRing(dio: dio);
      final results = await ring.search('plain json', numResults: 5);

      expect(results.map((r) => r.title), ['Alpha', 'Beta']);
      expect(results.first.url, 'https://a.example/one');
      // exa (no route here) fails first; parallel traffic follows it:
      // init, notification, call.
      final requestBody = captured[3].data as String;
      expect(requestBody, contains('"web_search"'));
      expect(requestBody, contains('"objective":"plain json"'));
      expect(requestBody, contains('"search_queries":["plain json"]'));
      final callHeaders = valueHeaders(captured[3].headers);
      expect(headerOf(callHeaders, 'Mcp-Session-Id'), 'sess-parallel-1');
    },
  );

  test(
    'a 429 from exa advances the cursor: the next query hits parallel first',
    () async {
      final captured = <RequestOptions>[];
      final parallelResponses = [
        StubResponse(
          200,
          jsonEnvelope(0, mcpInitializeResult(name: 'parallel')),
          headers: {
            'mcp-session-id': ['sess-parallel-1'],
          },
        ),
        StubResponse(202, ''),
        StubResponse(200, parallelSearchResultJson(text: mcpPairText)),
        StubResponse(
          200,
          parallelSearchResultJson(
            text: 'Title: Gamma\nURL: https://g.example\ngamma snippet',
          ),
        ),
      ];
      final dio = Dio()
        ..httpClientAdapter = StubAdapter(
          {exaMcpUrl: StubResponse(429, 'rate limit exceeded')},
          sequences: {parallelMcpUrl: parallelResponses},
          onRequest: captured.add,
        );
      final ring = KeylessMcpRing(dio: dio);

      final first = await ring.search('throttled vendor');
      expect(first.map((r) => r.title), ['Alpha', 'Beta']);

      final requestsAfterFirstSearch = captured.length;
      // First search: exa initialize 429, then parallel w/ fresh session.
      expect(captured[0].uri.toString(), exaMcpUrl);
      expect(
        captured
            .sublist(1, requestsAfterFirstSearch)
            .map((o) => o.uri.toString()),
        everyElement(parallelMcpUrl),
      );

      final second = await ring.search('rotated vendor', numResults: 2);
      expect(second.map((r) => r.title), ['Gamma']);
      expect(second.single.url, 'https://g.example');
      // Second search starts at parallel: a plain tools/call without a
      // re-initialize (session was reused).
      final secondSearchUris = captured
          .sublist(requestsAfterFirstSearch)
          .map((o) => o.uri.toString())
          .toList();
      expect(secondSearchUris.first, parallelMcpUrl);
      expect(secondSearchUris.length, 1);
      final reuseBody = captured.last.data as String;
      expect(reuseBody, contains('"objective":"rotated vendor"'));
    },
  );

  test(
    'a 404 on a call with session re-initializes once and retries',
    () async {
      final captured = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = StubAdapter(
          {},
          sequences: {
            exaMcpUrl: [
              StubResponse(
                200,
                sseEnvelope(0, mcpInitializeResult()),
                headers: {
                  'mcp-session-id': ['sess-exa-1'],
                },
              ),
              StubResponse(202, ''),
              StubResponse(404, ''),
              StubResponse(
                200,
                sseEnvelope(0, mcpInitializeResult()),
                headers: {
                  'mcp-session-id': ['sess-exa-2'],
                },
              ),
              StubResponse(202, ''),
              StubResponse(200, sseEnvelope(2, mcpTextResult(mcpPairText))),
            ],
          },
          onRequest: captured.add,
        );
      final ring = KeylessMcpRing(dio: dio);
      final results = await ring.search('expired session');

      expect(results.map((r) => r.title), ['Alpha', 'Beta']);
      // initialize, notif, call(404), re-initialize, notif, call(200).
      expect(captured.map((o) => o.uri.toString()), everyElement(exaMcpUrl));
      final retryHeaders = valueHeaders(captured[5].headers);
      expect(headerOf(retryHeaders, 'Mcp-Session-Id'), 'sess-exa-2');
    },
  );

  test('text without Title/URL pairs falls back to one unlinked row', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(
        {},
        sequences: {
          exaMcpUrl: [
            StubResponse(
              200,
              sseEnvelope(0, mcpInitializeResult()),
              headers: {
                'mcp-session-id': ['sess-exa-1'],
              },
            ),
            StubResponse(202, ''),
            StubResponse(
              200,
              sseEnvelope(1, mcpTextResult('_unstructured body_')),
            ),
          ],
        },
      );
    final ring = KeylessMcpRing(dio: dio);
    final results = await ring.search('gibberish query');

    expect(results, hasLength(1));
    expect(results.single.title, 'Results');
    expect(results.single.url, '');
    expect(results.single.snippet, '_unstructured body_');
  });

  test('all vendors failing throws the throttled block message', () async {
    final dio = Dio()..httpClientAdapter = StubAdapter({});
    final ring = KeylessMcpRing(dio: dio);
    await expectLater(
      () => ring.search('nothing works'),
      throwsA(
        isA<WebSearchBlockedException>().having(
          (e) => e.message,
          'message',
          'All web-search vendors are throttled right now — try again '
              'shortly or configure a provider key',
        ),
      ),
    );
  });

  test('search then fetchViaExa reuse the cached session', () async {
    final captured = <RequestOptions>[];
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(
        {},
        sequences: {
          exaMcpUrl: [
            StubResponse(
              200,
              sseEnvelope(0, mcpInitializeResult()),
              headers: {
                'mcp-session-id': ['sess-exa-1'],
              },
            ),
            StubResponse(202, ''),
            StubResponse(200, sseEnvelope(1, mcpTextResult(mcpPairText))),
            StubResponse(
              200,
              sseEnvelope(2, mcpTextResult('fetched page body')),
            ),
          ],
        },
        onRequest: captured.add,
      );
    final ring = KeylessMcpRing(dio: dio);
    await ring.search('first query');
    final fetched = await ring.fetchViaExa(['https://example.com/page']);

    expect(fetched, 'fetched page body');
    expect(captured, hasLength(4));
    final fetchBody = captured[3].data as String;
    expect(fetchBody, contains('"web_fetch_exa"'));
    expect(fetchBody, contains('"urls":["https://example.com/page"]'));
    expect(fetchBody, contains('"maxCharacters":8000'));
    final fetchHeaders = valueHeaders(captured[3].headers);
    expect(headerOf(fetchHeaders, 'Mcp-Session-Id'), 'sess-exa-1');
  });

  test(
    'throttle wording inside successful result text must not rotate the ring',
    () async {
      final captured = <RequestOptions>[];
      final throttleSnippet =
          'Title: Alpha\nURL: https://a.example/one\nprovider page notes '
          'a rate limit exceeded message for busy accounts\n'
          'Title: Beta\nURL: https://a.example/two\nsecond snippet';
      final dio = Dio()
        ..httpClientAdapter = StubAdapter(
          {},
          sequences: {
            exaMcpUrl: [
              StubResponse(
                200,
                sseEnvelope(0, mcpInitializeResult()),
                headers: {
                  'mcp-session-id': ['sess-exa-1'],
                },
              ),
              StubResponse(202, ''),
              StubResponse(200, sseEnvelope(1, mcpTextResult(throttleSnippet))),
              StubResponse(
                200,
                sseEnvelope(
                  2,
                  mcpTextResult(
                    'Title: Gamma\nURL: https://g.example\ngamma snippet',
                  ),
                ),
              ),
            ],
          },
          onRequest: captured.add,
        );
      final ring = KeylessMcpRing(dio: dio);

      // The exa SUCCESS text merely mentions rate limits — that is page
      // content, not the vendor throttling us.
      final first = await ring.search('ddg rate limits', numResults: 2);
      expect(first.map((r) => r.title), ['Alpha', 'Beta']);
      expect(first.first.snippet, contains('rate limit exceeded'));

      expect(captured, hasLength(3), reason: 'init + notification + call');
      expect(captured.last.uri.toString(), exaMcpUrl);

      // The cursor must NOT have rotated: the next search starts at exa
      // again, reusing the cached session (a plain tools/call).
      final second = await ring.search('follow-up query', numResults: 2);
      expect(second.map((r) => r.title), ['Gamma']);
      final secondSearch = captured.sublist(3);
      expect(secondSearch, hasLength(1));
      expect(secondSearch.single.uri.toString(), exaMcpUrl);
      expect(secondSearch.single.data as String, contains('"web_search_exa"'));
      expect(
        headerOf(valueHeaders(secondSearch.single.headers), 'Mcp-Session-Id'),
        'sess-exa-1',
      );
    },
  );

  test('an isError result with throttle phrasing still rotates', () async {
    final captured = <RequestOptions>[];
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(
        {},
        sequences: {
          exaMcpUrl: [
            StubResponse(
              200,
              jsonEnvelope(0, mcpInitializeResult()),
              headers: {
                'mcp-session-id': ['sess-exa-1'],
              },
            ),
            StubResponse(202, ''),
            // The MCP envelope carries isError:true — the FAILURE branch —
            // with throttle phrasing inside: that IS throttling.
            StubResponse(
              200,
              jsonEncode({
                'jsonrpc': '2.0',
                'id': 1,
                'result': {
                  'isError': true,
                  'content': [
                    {'type': 'text', 'text': 'rate limit exceeded'},
                  ],
                },
              }),
            ),
          ],
          parallelMcpUrl: [
            StubResponse(
              200,
              jsonEnvelope(0, mcpInitializeResult(name: 'parallel')),
              headers: {
                'mcp-session-id': ['sess-parallel-1'],
              },
            ),
            StubResponse(202, ''),
            StubResponse(200, parallelSearchResultJson(text: mcpPairText)),
          ],
        },
        onRequest: captured.add,
      );
    final ring = KeylessMcpRing(dio: dio);

    final first = await ring.search('throttle envelope');
    expect(first.map((r) => r.title), ['Alpha', 'Beta']);
    expect(
      captured.map((o) => o.uri.toString()).any((u) => u == exaMcpUrl),
      isTrue,
      reason: 'exa must have received the tools/call that failed',
    );

    // The next search must START at parallel: the failure-branch throttle
    // rotated the cursor.
    final requestsAfterFirstSearch = captured.length;
    final second = await ring.search('rotated again');
    expect(second.map((r) => r.title), ['Alpha', 'Beta']);
    final secondSearchUris = captured
        .sublist(requestsAfterFirstSearch)
        .map((o) => o.uri.toString())
        .toList();
    expect(secondSearchUris.first, parallelMcpUrl);
  });

  test(
    'isError without throttle phrasing falls through without rotating',
    () async {
      final captured = <RequestOptions>[];
      final parallelResponses = [
        StubResponse(
          200,
          jsonEnvelope(0, mcpInitializeResult(name: 'parallel')),
          headers: {
            'mcp-session-id': ['sess-parallel-1'],
          },
        ),
        StubResponse(202, ''),
        StubResponse(200, parallelSearchResultJson(text: mcpPairText)),
      ];
      final dio = Dio()
        ..httpClientAdapter = StubAdapter(
          {},
          sequences: {
            exaMcpUrl: [
              StubResponse(
                200,
                jsonEnvelope(0, mcpInitializeResult()),
                headers: {
                  'mcp-session-id': ['sess-exa-1'],
                },
              ),
              StubResponse(202, ''),
              StubResponse(
                200,
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': 1,
                  'result': {
                    'isError': true,
                    'content': [
                      {'type': 'text', 'text': 'query rejected: bad arguments'},
                    ],
                  },
                }),
              ),
            ],
            parallelMcpUrl: parallelResponses,
          },
          onRequest: captured.add,
        );
      final ring = KeylessMcpRing(dio: dio);

      final first = await ring.search('bad args turn');
      expect(first.map((r) => r.title), ['Alpha', 'Beta']);

      // A vendor failure is our error, not throttling: keep the cursor so the
      // NEXT search starts at exa again.
      final second = await ring.search('next query');
      expect(second.map((r) => r.title), ['Alpha', 'Beta']);
      final secondCall = captured
          .where(
            (o) =>
                o.uri.toString() == exaMcpUrl &&
                (o.data as String).contains('"tools/call"'),
          )
          .toList();
      expect(
        secondCall,
        hasLength(2),
        reason:
            'exa retried first on the next search — an isError result without '
            'throttle phrasing must not rotate the ring',
      );
    },
  );

  test(
    'a 403 bot-block body is a vendor failure, not a ring rotation',
    () async {
      final captured = <RequestOptions>[];
      final parallelResponses = [
        StubResponse(
          200,
          jsonEnvelope(0, mcpInitializeResult(name: 'parallel')),
          headers: {
            'mcp-session-id': ['sess-parallel-1'],
          },
        ),
        StubResponse(202, ''),
        StubResponse(200, parallelSearchResultJson(text: mcpPairText)),
      ];
      final dio = Dio()
        ..httpClientAdapter = StubAdapter(
          {exaMcpUrl: StubResponse(403, 'Access Denied — request blocked')},
          sequences: {parallelMcpUrl: parallelResponses},
          onRequest: captured.add,
        );
      final ring = KeylessMcpRing(dio: dio);

      final first = await ring.search('blocked vendor');
      expect(first.map((r) => r.title), ['Alpha', 'Beta']);

      // No rotation: the next search re-tries exa first (it fell through on a
      // plain vendor failure, not a throttle).
      await ring.search('next round');
      final exaTraffic = captured
          .where((o) => o.uri.toString() == exaMcpUrl)
          .toList();
      expect(exaTraffic, hasLength(2), reason: 'second search started at exa');
    },
  );
}
