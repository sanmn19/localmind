import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/mcp/data/web/web_search_service.dart';
import 'mcp_fixtures.dart';
import 'stub_dio_adapter.dart';

/// Test helper: results page accepted by the lite parser (one link+snippet).
const liteOkBody =
    '<html><body><table>'
    '<tr><td class="result-link"><a class="result-link" '
    'href="https://example.com/ok">Ok</a></td></tr>'
    '<tr><td class="result-snippet">ok snippet</td></tr>'
    '</table></body></html>';

/// Tail every fully-blocked keyless search must surface to the model/user.
const blockHintTail =
    'configure a search provider key in Settings → Tools → Web Browser for '
    'reliable results';

String liteAnomalyBody() => File(
  'test/features/mcp/web/fixtures/ddg_lite_anomaly.html',
).readAsStringSync();

String ddgHtmlBody() => File(
  'test/features/mcp/web/fixtures/ddg_html_results.html',
).readAsStringSync();

String? headerOf(Map<String, dynamic> headers, String name) {
  final value = headers[name];
  if (value is List) return value.isEmpty ? null : value.first as String?;
  return value as String?;
}

const searxBase = 'http://192.0.2.10:8888';

String searxFixture() => File(
  'test/features/mcp/web/fixtures/searx_results.json',
).readAsStringSync();

void main() {
  group('searxng provider', () {
    test('parses searxng json results and ignores malformed rows', () async {
      final dio = Dio()
        ..httpClientAdapter = StubAdapter({
          '$searxBase/search?q=homelab&format=json&language=en&safesearch=1':
              StubResponse(200, searxFixture()),
        });
      final service = WebSearchService(
        provider: WebSearchProvider.searxng,
        dio: dio,
        searxUrl: searxBase,
      );
      final results = await service.search('homelab');
      expect(results, hasLength(2));
      expect(results.first.title, 'Rig docs');
      expect(results.first.url, 'https://rig.local/docs');
      expect(results.first.snippet, 'self-hosted search tier');
      expect(results[1].title, 'Null snippet');
      expect(results[1].url, 'https://rig.local/2');
      expect(results[1].snippet, '');
    });

    test('takes only the first maxResults rows (clamped 1..8)', () async {
      final dio = Dio()
        ..httpClientAdapter = StubAdapter({
          '$searxBase/search?q=many&format=json&language=en&safesearch=1':
              StubResponse(
                200,
                jsonEncode({
                  'results': List.generate(
                    10,
                    (i) => {
                      'title': 'T$i',
                      'url': 'https://t$i',
                      'content': 'c$i',
                    },
                  ),
                }),
              ),
        });
      final few = WebSearchService(
        provider: WebSearchProvider.searxng,
        dio: dio,
        searxUrl: searxBase,
      );
      expect(await few.search('many', maxResults: 2), hasLength(2));
      final plenty = WebSearchService(
        provider: WebSearchProvider.searxng,
        dio: dio,
        searxUrl: searxBase,
      );
      expect(await plenty.search('many', maxResults: 99), hasLength(8));
    });

    test('request hits $searxBase with the json format query params', () async {
      final requested = <Uri>[];
      final dio = Dio()
        ..httpClientAdapter = StubAdapter({
          '$searxBase/search?q=sorted&format=json&language=en&safesearch=1':
              StubResponse(200, searxFixture()),
        }, onRequest: (options) => requested.add(options.uri));
      final service = WebSearchService(
        provider: WebSearchProvider.searxng,
        dio: dio,
        searxUrl: searxBase,
      );
      await service.search('sorted');
      expect(
        requested.single.toString(),
        '$searxBase/search?q=sorted&format=json&language=en&safesearch=1',
      );
    });

    test('empty results raise the searx unreachable message', () async {
      final dio = Dio()
        ..httpClientAdapter = StubAdapter({
          '$searxBase/search?q=empty&format=json&language=en&safesearch=1':
              StubResponse(200, jsonEncode({'results': []})),
        });
      final service = WebSearchService(
        provider: WebSearchProvider.searxng,
        dio: dio,
        searxUrl: searxBase,
      );
      await expectLater(
        () => service.search('empty'),
        throwsA(
          isA<WebSearchBlockedException>().having(
            (e) => e.message,
            'message',
            contains('SearXNG at the configured URL is unreachable'),
          ),
        ),
      );
    });

    test('non-200 raises the searx unreachable message', () async {
      final dio = Dio()
        ..httpClientAdapter = StubAdapter({
          '$searxBase/search?q=down&format=json&language=en&safesearch=1':
              StubResponse(403, '{"error": "format not allowed"}'),
        });
      final service = WebSearchService(
        provider: WebSearchProvider.searxng,
        dio: dio,
        searxUrl: searxBase,
      );
      await expectLater(
        () => service.search('down'),
        throwsA(isA<WebSearchBlockedException>()),
      );
    });

    test('auto puts searx first when a searx url is configured', () async {
      final requested = <String>[];
      final dio = Dio()
        ..httpClientAdapter = StubAdapter({
          '$searxBase/search?q=first&format=json&language=en&safesearch=1':
              StubResponse(200, searxFixture()),
        }, onRequest: (options) => requested.add(options.uri.toString()));
      final service = WebSearchService(
        provider: WebSearchProvider.auto,
        dio: dio,
        searxUrl: searxBase,
      );
      final results = await service.search('first');
      expect(results.first.title, 'Rig docs');
      expect(requested.single, startsWith(searxBase));
      expect(requested, everyElement(isNot(contains('mcp.exa.ai'))));
    });

    test(
      'auto with searx down rescues via the ring, searx first in order',
      () async {
        final requested = <String>[];
        final dio = Dio()
          ..httpClientAdapter = StubAdapter(
            {
              '$searxBase/search?q=downchain&format=json&language=en&safesearch=1':
                  StubResponse(500, '{}'),
            },
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
            onRequest: (options) => requested.add(options.uri.toString()),
          );
        final service = WebSearchService(
          provider: WebSearchProvider.auto,
          dio: dio,
          searxUrl: searxBase,
        );
        final results = await service.search('downchain');
        expect(results.map((r) => r.title), ['Alpha', 'Beta']);
        expect(
          requested.first,
          '$searxBase/search?q=downchain&format=json&language=en&safesearch=1',
        );
        expect(requested.elementAt(1), exaMcpUrl);
      },
    );

    test(
      'auto without a searx url keeps ring-first with no searx traffic',
      () async {
        final requested = <String>[];
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
            onRequest: (options) => requested.add(options.uri.toString()),
          );
        final service = WebSearchService(
          provider: WebSearchProvider.auto,
          dio: dio,
        );
        await service.search('plain-auto');
        expect(requested.first, exaMcpUrl);
        expect(requested.where((u) => u.contains('/search?q=')), isEmpty);
      },
    );

    test(
      'explicit ddg joins searx first when a searx url is configured',
      () async {
        final requested = <String>[];
        final dio = Dio()
          ..httpClientAdapter = StubAdapter({
            '$searxBase/search?q=ddglinks&format=json&language=en&safesearch=1':
                StubResponse(200, searxFixture()),
          }, onRequest: (options) => requested.add(options.uri.toString()));
        final service = WebSearchService(
          provider: WebSearchProvider.ddgLite,
          dio: dio,
          searxUrl: searxBase,
        );
        final results = await service.search('ddglinks');
        expect(results.first.title, 'Rig docs');
        expect(requested.single, startsWith(searxBase));
      },
    );

    test(
      'explicit searxng folds its failure through ring and ddg when all fail',
      () async {
        final requested = <String>[];
        final dio = Dio()
          ..httpClientAdapter = StubAdapter(
            {
              '$searxBase/search?q=doomed&format=json&language=en&safesearch=1':
                  StubResponse(500, '{}'),
              'https://lite.duckduckgo.com/lite/?q=doomed': StubResponse(
                200,
                liteAnomalyBody(),
              ),
              'https://html.duckduckgo.com/html/?q=doomed': StubResponse(
                200,
                liteAnomalyBody(),
              ),
            },
            sequences: {
              exaMcpUrl: [StubResponse(429, 'rate limit')],
              parallelMcpUrl: [StubResponse(429, 'rate limit')],
            },
            onRequest: (options) => requested.add(options.uri.toString()),
          );
        final service = WebSearchService(
          provider: WebSearchProvider.searxng,
          dio: dio,
          searxUrl: searxBase,
        );
        await expectLater(
          () => service.search('doomed'),
          throwsA(
            isA<WebSearchBlockedException>().having(
              (e) => e.message,
              'message',
              contains('configure a search provider key'),
            ),
          ),
        );
        expect(requested, [
          '$searxBase/search?q=doomed&format=json&language=en&safesearch=1',
          exaMcpUrl,
          parallelMcpUrl,
          'https://lite.duckduckgo.com/lite/?q=doomed',
          'https://html.duckduckgo.com/html/?q=doomed',
        ]);
      },
    );

    test('explicit searxng without a url defers to the ring chain', () async {
      final requested = <String>[];
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
          onRequest: (options) => requested.add(options.uri.toString()),
        );
      final service = WebSearchService(
        provider: WebSearchProvider.searxng,
        dio: dio,
        searxUrl: null,
      );
      final results = await service.search('no-url');
      expect(results.map((r) => r.title), ['Alpha', 'Beta']);
      expect(requested.first, exaMcpUrl);
    });

    test(
      'serves repeat searxng queries from cache (no second adapter hit)',
      () async {
        var fetches = 0;
        var now = DateTime(2026, 1, 1);
        final dio = Dio()
          ..httpClientAdapter = StubAdapter({
            '$searxBase/search?q=cached&format=json&language=en&safesearch=1':
                StubResponse(200, searxFixture()),
          }, onRequest: (_) => fetches++);
        final service = WebSearchService(
          provider: WebSearchProvider.searxng,
          dio: dio,
          searxUrl: searxBase,
          clock: () => now,
          jitterFor: () => Duration.zero,
        );
        await service.search('cached');
        await service.search('cached');
        expect(fetches, 1);
        now = now.add(const Duration(minutes: 11));
        await service.search('cached');
        expect(fetches, 2);
      },
    );
  });

  test('parses DDG Lite results', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://lite.duckduckgo.com/lite/?q=test': StubResponse(
          200,
          File(
            'test/features/mcp/web/fixtures/ddg_lite_results.html',
          ).readAsStringSync(),
        ),
      });
    final service = WebSearchService(
      provider: WebSearchProvider.ddgLite,
      dio: dio,
    );
    final results = await service.search('test');
    expect(results, hasLength(2));
    expect(results.first.title, 'Example A');
    expect(results.first.url, 'https://example.com/a');
    expect(results[1].snippet, 'Snippet B text here');
  });

  test('anomaly page raises WebSearchBlockedException', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://lite.duckduckgo.com/lite/?q=blocked': StubResponse(
          200,
          File(
            'test/features/mcp/web/fixtures/ddg_lite_anomaly.html',
          ).readAsStringSync(),
        ),
      });
    final service = WebSearchService(
      provider: WebSearchProvider.ddgLite,
      dio: dio,
    );
    expect(
      () => service.search('blocked'),
      throwsA(isA<WebSearchBlockedException>()),
    );
  });

  test('tavily adapter posts the key and maps results', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://api.tavily.com/search': StubResponse(
          200,
          jsonEncode({
            'results': [
              {'title': 'T', 'url': 'https://t', 'content': 'c'},
            ],
          }),
        ),
      });
    final service = WebSearchService(
      provider: WebSearchProvider.tavily,
      apiKey: 'KEY',
      dio: dio,
    );
    final results = await service.search('q');
    expect(results.single.title, 'T');
    expect(results.single.url, 'https://t');
    expect(results.single.snippet, 'c');
  });

  test('sends browser headers to DDG Lite', () async {
    final sent = <Map<String, dynamic>>[];
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://lite.duckduckgo.com/lite/?q=hdr': StubResponse(
          200,
          '<html></html>',
        ),
      }, onRequest: (options) => sent.add(options.headers));
    final service = WebSearchService(
      provider: WebSearchProvider.ddgLite,
      dio: dio,
    );
    await expectLater(
      () => service.search('hdr'),
      throwsA(isA<WebSearchBlockedException>()),
    );
    // The empty lite page falls back to the html endpoint, so two requests
    // carry the same browser headers; assert the first request only.
    final headers = sent.first;
    expect(headerOf(headers, 'User-Agent'), webChromeUserAgent);
    expect(headerOf(headers, 'Accept-Language'), 'en-US,en;q=0.9');
    expect(headerOf(headers, 'Accept'), 'text/html');
  });

  test('tavily posts api_key in the json body', () async {
    final sent = <RequestOptions>[];
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://api.tavily.com/search': StubResponse(
          200,
          jsonEncode({'results': []}),
        ),
      }, onRequest: sent.add);
    final service = WebSearchService(
      provider: WebSearchProvider.tavily,
      apiKey: 'KEY',
      dio: dio,
    );
    await service.search('q1');
    final body = sent.single.data;
    expect(body, isA<String>());
    expect(body as String, contains('"api_key":"KEY"'));
    expect(body, contains('"query":"q1"'));
  });

  test(
    'pairs each link with next snippet, tolerating missing snippets',
    () async {
      const html = '''
    <table>
      <tr><td class="result-link"><a class="result-link" href="https://x/1">One</a></td></tr>
      <tr><td class="result-snippet">s1</td></tr>
      <tr><td class="result-link"><a class="result-link" href="https://x/2">Two</a></td></tr>
      <tr><td class="result-link"><a class="result-link" href="https://x/3">Three</a></td></tr>
      <tr><td class="result-snippet">s3</td></tr>
    </table>''';
      final dio = Dio()
        ..httpClientAdapter = StubAdapter({
          'https://lite.duckduckgo.com/lite/?q=variant': StubResponse(
            200,
            html,
          ),
        });
      final service = WebSearchService(
        provider: WebSearchProvider.ddgLite,
        dio: dio,
      );
      final results = await service.search('variant');
      expect(results, hasLength(3));
      expect(results[0].snippet, 's1');
      expect(results[1].snippet, '');
      expect(results[2].snippet, 's3');
      expect(results[2].title, 'Three');
    },
  );

  test(
    'ends the chain with the throttled hint when ddg fallback and ring fail',
    () async {
      final requested = <String>[];
      final dio = Dio()
        ..httpClientAdapter = StubAdapter({
          'https://lite.duckduckgo.com/lite/?q=none': StubResponse(
            200,
            '<html><body><p>none</p></body></html>',
          ),
        }, onRequest: (options) => requested.add(options.uri.toString()));
      final service = WebSearchService(
        provider: WebSearchProvider.ddgLite,
        dio: dio,
      );
      await expectLater(
        () => service.search('none'),
        throwsA(
          isA<WebSearchBlockedException>().having(
            (e) => e.message,
            'message',
            'All web-search vendors are throttled right now — try again '
                'shortly or configure a provider key',
          ),
        ),
      );
      expect(requested.sublist(0, 2), [
        'https://lite.duckduckgo.com/lite/?q=none',
        'https://html.duckduckgo.com/html/?q=none',
      ]);
    },
  );

  test('brave adapter sends subscription token and maps results', () async {
    final sent = <Map<String, dynamic>>[];
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://api.search.brave.com/res/v1/web/search?q=x&count=6':
            StubResponse(
              200,
              jsonEncode({
                'web': {
                  'results': [
                    {'title': 'B', 'url': 'https://b', 'description': 'd'},
                  ],
                },
              }),
            ),
      }, onRequest: (options) => sent.add(options.headers));
    final service = WebSearchService(
      provider: WebSearchProvider.brave,
      apiKey: 'SK',
      dio: dio,
    );
    final results = await service.search('x');
    expect(results.single.title, 'B');
    expect(results.single.url, 'https://b');
    expect(results.single.snippet, 'd');
    expect(headerOf(sent.single, 'X-Subscription-Token'), 'SK');
  });

  test('serper adapter posts and maps organic results', () async {
    final sent = <RequestOptions>[];
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://google.serper.dev/search': StubResponse(
          200,
          jsonEncode({
            'organic': [
              {'title': 'S', 'link': 'https://s', 'snippet': 'sn'},
            ],
          }),
        ),
      }, onRequest: sent.add);
    final service = WebSearchService(
      provider: WebSearchProvider.serper,
      apiKey: 'SK',
      dio: dio,
    );
    final results = await service.search('q1');
    expect(results.single.title, 'S');
    expect(results.single.url, 'https://s');
    expect(results.single.snippet, 'sn');
    final headers = sent.single.headers;
    expect(headerOf(headers, 'X-API-KEY'), 'SK');
    expect(sent.single.data as String, contains('"q":"q1"'));
    expect(sent.single.data, contains('"num"'));
  });

  test('keyed provider without a key defers to the keyless ring', () async {
    final requested = <String>[];
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(
        {},
        onRequest: (options) => requested.add(options.uri.toString()),
      );
    final service = WebSearchService(
      provider: WebSearchProvider.tavily,
      dio: dio,
    );
    await expectLater(
      () => service.search('q'),
      throwsA(
        isA<WebSearchBlockedException>().having(
          (e) => e.message,
          'message',
          'All web-search vendors are throttled right now — try again '
              'shortly or configure a provider key',
        ),
      ),
    );
    expect(requested.where((u) => u.contains('tavily')), isEmpty);
  });

  test('keyed provider failure rescues via the ring', () async {
    final requested = <String>[];
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(
        {'https://api.tavily.com/search': StubResponse(500, '{}')},
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
        onRequest: (options) => requested.add(options.uri.toString()),
      );
    final service = WebSearchService(
      provider: WebSearchProvider.tavily,
      apiKey: 'KEY',
      dio: dio,
    );
    final results = await service.search('q');
    expect(results.map((r) => r.title), ['Alpha', 'Beta']);
    expect(requested.first, 'https://api.tavily.com/search');
  });

  test('clamps results to maxResults and caps at eight', () async {
    final resultsJson = jsonEncode({
      'results': List.generate(
        10,
        (i) => {'title': 'T$i', 'url': 'https://t$i', 'content': 'c$i'},
      ),
    });
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://api.tavily.com/search': StubResponse(200, resultsJson),
      });
    final service = WebSearchService(
      provider: WebSearchProvider.tavily,
      apiKey: 'KEY',
      dio: dio,
    );
    expect((await service.search('q', maxResults: 2)), hasLength(2));
    expect((await service.search('q', maxResults: 99)), hasLength(8));
  });

  testWidgets('paces consecutive ddg requests at the minimum interval', (
    tester,
  ) async {
    final requestsAt = <DateTime>[];
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://lite.duckduckgo.com/lite/?q=pacedone': StubResponse(
          200,
          liteOkBody,
        ),
        'https://lite.duckduckgo.com/lite/?q=pacedtwo': StubResponse(
          200,
          liteOkBody,
        ),
      }, onRequest: (options) => requestsAt.add(tester.binding.clock.now()));
    final service = WebSearchService(
      provider: WebSearchProvider.ddgLite,
      dio: dio,
      clock: () => tester.binding.clock.now(),
      jitterFor: () => Duration.zero,
    );
    final first = service.search('pacedone');
    final second = service.search('pacedtwo');
    await tester.pump(const Duration(seconds: 4));
    await Future.wait([first, second]);
    expect(requestsAt, hasLength(2));
    final gap = requestsAt[1].difference(requestsAt[0]);
    expect(gap >= const Duration(seconds: 2), isTrue, reason: 'gap was $gap');
  });

  testWidgets('paces consecutive keyed-provider requests too', (tester) async {
    final requestsAt = <DateTime>[];
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://api.tavily.com/search': StubResponse(
          200,
          jsonEncode({
            'results': [
              {'title': 'T', 'url': 'https://t', 'content': 'c'},
            ],
          }),
        ),
      }, onRequest: (options) => requestsAt.add(tester.binding.clock.now()));
    final service = WebSearchService(
      provider: WebSearchProvider.tavily,
      apiKey: 'KEY',
      dio: dio,
      clock: () => tester.binding.clock.now(),
      jitterFor: () => Duration.zero,
    );
    final first = service.search('tv one');
    final second = service.search('tv two');
    await tester.pump(const Duration(seconds: 4));
    await Future.wait([first, second]);
    expect(requestsAt, hasLength(2));
    final gap = requestsAt[1].difference(requestsAt[0]);
    expect(gap >= const Duration(seconds: 2), isTrue, reason: 'gap was $gap');
  });

  test('serves identical queries from cache until the TTL expires', () async {
    var now = DateTime(2026, 1, 1);
    var fetches = 0;
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://api.tavily.com/search': StubResponse(
          200,
          jsonEncode({
            'results': [
              {'title': 'T', 'url': 'https://t', 'content': 'c'},
            ],
          }),
        ),
      }, onRequest: (_) => fetches++);
    final service = WebSearchService(
      provider: WebSearchProvider.tavily,
      apiKey: 'KEY',
      dio: dio,
      clock: () => now,
      jitterFor: () => Duration.zero,
    );
    await service.search('ttl');
    await service.search('ttl');
    expect(fetches, 1);
    now = now.add(const Duration(minutes: 11));
    await service.search('ttl');
    expect(fetches, 2);
  });

  test('caches per maxResults bucket', () async {
    var now = DateTime(2026, 1, 1);
    var fetches = 0;
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://api.tavily.com/search': StubResponse(
          200,
          jsonEncode({
            'results': [
              {'title': 'T', 'url': 'https://t', 'content': 'c'},
            ],
          }),
        ),
      }, onRequest: (_) => fetches++);
    final service = WebSearchService(
      provider: WebSearchProvider.tavily,
      apiKey: 'KEY',
      dio: dio,
      clock: () => now,
      jitterFor: () => Duration.zero,
    );
    await service.search('bucket', maxResults: 4);
    expect(fetches, 1);
    await service.search('bucket', maxResults: 4);
    expect(fetches, 1, reason: 'same query + same bucket must hit the cache');
    now = now.add(const Duration(seconds: 3));
    await service.search('bucket', maxResults: 8);
    expect(fetches, 2, reason: 'different bucket is a different cache key');
  });

  testWidgets('evicts the least recently used cache entry past 32', (
    tester,
  ) async {
    var fetches = 0;
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://api.tavily.com/search': StubResponse(
          200,
          jsonEncode({
            'results': [
              {'title': 'T', 'url': 'https://t', 'content': 'c'},
            ],
          }),
        ),
      }, onRequest: (_) => fetches++);
    final service = WebSearchService(
      provider: WebSearchProvider.tavily,
      apiKey: 'KEY',
      dio: dio,
      clock: () => tester.binding.clock.now(),
      jitterFor: () => Duration.zero,
    );
    for (var i = 0; i < 33; i++) {
      final pending = service.search('lru $i');
      await tester.pump(const Duration(seconds: 3));
      await pending;
    }
    expect(fetches, 33);
    final stillCached = service.search('lru 32');
    await tester.pump(const Duration(seconds: 3));
    await stillCached;
    expect(fetches, 33, reason: 'most recent entry must stay cached');
    final evicted = service.search('lru 0');
    await tester.pump(const Duration(seconds: 3));
    await evicted;
    expect(fetches, 34, reason: 'first entry must have been evicted');
  });

  test('falls back to the html endpoint when lite is blocked', () async {
    final requested = <String>[];
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://lite.duckduckgo.com/lite/?q=fallback': StubResponse(
          200,
          liteAnomalyBody(),
        ),
        'https://html.duckduckgo.com/html/?q=fallback': StubResponse(
          200,
          ddgHtmlBody(),
        ),
      }, onRequest: (options) => requested.add(options.uri.toString()));
    final service = WebSearchService(
      provider: WebSearchProvider.ddgLite,
      dio: dio,
      clock: () => DateTime(2026, 1, 1),
      jitterFor: () => Duration.zero,
    );
    final results = await service.search('fallback');
    expect(results, hasLength(2));
    expect(results.first.title, 'HTML Result A');
    expect(results.first.url, 'https://example.com/a');
    expect(results.first.snippet, 'Snippet X text here');
    expect(results[1].url, 'https://example.com/b');
    expect(requested, [
      'https://lite.duckduckgo.com/lite/?q=fallback',
      'https://html.duckduckgo.com/html/?q=fallback',
    ]);
  });

  test(
    'both ddg endpoints blocked and ring dead: throttled hint wins',
    () async {
      final requested = <String>[];
      final dio = Dio()
        ..httpClientAdapter = StubAdapter({
          'https://lite.duckduckgo.com/lite/?q=double': StubResponse(
            200,
            liteAnomalyBody(),
          ),
          'https://html.duckduckgo.com/html/?q=double': StubResponse(
            200,
            liteAnomalyBody(),
          ),
        }, onRequest: (options) => requested.add(options.uri.toString()));
      final service = WebSearchService(
        provider: WebSearchProvider.ddgLite,
        dio: dio,
      );
      await expectLater(
        () => service.search('double'),
        throwsA(
          isA<WebSearchBlockedException>().having(
            (e) => e.message,
            'message',
            'All web-search vendors are throttled right now — try again '
                'shortly or configure a provider key',
          ),
        ),
      );
      expect(requested.sublist(0, 2), [
        'https://lite.duckduckgo.com/lite/?q=double',
        'https://html.duckduckgo.com/html/?q=double',
      ]);
    },
  );

  test(
    'ddg cooldown suppresses only the ddg leg; the ring stays reachable',
    () async {
      var now = DateTime(2026, 1, 1);
      var ddgRequests = 0;
      final routes = {
        'https://lite.duckduckgo.com/lite/?q=cool': StubResponse(
          200,
          liteAnomalyBody(),
        ),
        'https://html.duckduckgo.com/html/?q=cool': StubResponse(
          200,
          liteAnomalyBody(),
        ),
      };
      final dio = Dio()
        ..httpClientAdapter = StubAdapter(
          routes,
          onRequest: (options) {
            if (options.uri.host.endsWith('duckduckgo.com')) ddgRequests++;
          },
        );
      final service = WebSearchService(
        provider: WebSearchProvider.ddgLite,
        dio: dio,
        clock: () => now,
        jitterFor: () => Duration.zero,
      );
      await expectLater(
        () => service.search('cool'),
        throwsA(isA<WebSearchBlockedException>()),
      );
      expect(ddgRequests, 2);

      await expectLater(
        () => service.search('cool'),
        throwsA(isA<WebSearchBlockedException>()),
      );
      expect(
        ddgRequests,
        2,
        reason: 'cooldown must short-circuit the ddg leg before any traffic',
      );

      now = now.add(const Duration(seconds: 61));
      routes['https://html.duckduckgo.com/html/?q=cool'] = StubResponse(
        200,
        ddgHtmlBody(),
      );
      final recovered = await service.search('cool');
      expect(recovered, hasLength(2));
      expect(recovered.first.title, 'HTML Result A');
      expect(
        ddgRequests,
        4,
        reason: 'after the cooldown the ddg chain runs again',
      );
    },
  );

  test('auto provider runs the keyless ring first and skips ddg', () async {
    final requested = <String>[];
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
        onRequest: (options) => requested.add(options.uri.toString()),
      );
    final service = WebSearchService(
      provider: WebSearchProvider.auto,
      dio: dio,
    );
    final results = await service.search('auto ring');
    expect(results.map((r) => r.title), ['Alpha', 'Beta']);
    expect(requested, everyElement(contains('mcp.exa.ai')));
  });

  test(
    'auto falls through to the ddg chain when the ring is blocked',
    () async {
      final requested = <String>[];
      final dio = Dio()
        ..httpClientAdapter = StubAdapter(
          {
            'https://lite.duckduckgo.com/lite/?q=ringdown': StubResponse(
              200,
              liteOkBody,
            ),
          },
          sequences: {
            exaMcpUrl: [StubResponse(429, 'rate limit')],
            parallelMcpUrl: [StubResponse(429, 'rate limit')],
          },
          onRequest: (options) => requested.add(options.uri.toString()),
        );
      final service = WebSearchService(
        provider: WebSearchProvider.auto,
        dio: dio,
        clock: () => DateTime(2026, 1, 1),
        jitterFor: () => Duration.zero,
      );
      final results = await service.search('ringdown');
      expect(results.single.title, 'Ok');
      expect(requested, [
        exaMcpUrl,
        parallelMcpUrl,
        'https://lite.duckduckgo.com/lite/?q=ringdown',
      ]);
    },
  );

  test(
    "'ddg' chain is rescued by the ring when both endpoints block",
    () async {
      final requested = <String>[];
      final dio = Dio()
        ..httpClientAdapter = StubAdapter(
          {
            'https://lite.duckduckgo.com/lite/?q=annoyed': StubResponse(
              200,
              liteAnomalyBody(),
            ),
            'https://html.duckduckgo.com/html/?q=annoyed': StubResponse(
              200,
              liteAnomalyBody(),
            ),
          },
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
          onRequest: (options) => requested.add(options.uri.toString()),
        );
      final service = WebSearchService(
        provider: WebSearchProvider.ddgLite,
        dio: dio,
        clock: () => DateTime(2026, 1, 1),
        jitterFor: () => Duration.zero,
      );
      final results = await service.search('annoyed');
      expect(results.map((r) => r.title), ['Alpha', 'Beta']);
      expect(requested.sublist(0, 2), [
        'https://lite.duckduckgo.com/lite/?q=annoyed',
        'https://html.duckduckgo.com/html/?q=annoyed',
      ]);
    },
  );
}
