import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/mcp/data/web/web_search_service.dart';
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

void main() {
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
    'empty lite page falls back to html, then raises the block hint',
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
            endsWith(blockHintTail),
          ),
        ),
      );
      expect(requested, hasLength(2));
      expect(requested[1], 'https://html.duckduckgo.com/html/?q=none');
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

  test('missing api key throws with provider hint', () async {
    final dio = Dio()..httpClientAdapter = StubAdapter({});
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
          'No API key configured for Tavily — configure one in Settings',
        ),
      ),
    );
  });

  test('non-200 response throws Search failed', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://api.tavily.com/search': StubResponse(500, '{}'),
      });
    final service = WebSearchService(
      provider: WebSearchProvider.tavily,
      apiKey: 'KEY',
      dio: dio,
    );
    await expectLater(
      () => service.search('q'),
      throwsA(
        isA<WebSearchBlockedException>().having(
          (e) => e.message,
          'message',
          'Search failed: 500',
        ),
      ),
    );
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

  test('raises the block hint when lite and html are both blocked', () async {
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
          endsWith(blockHintTail),
        ),
      ),
    );
    expect(requested, [
      'https://lite.duckduckgo.com/lite/?q=double',
      'https://html.duckduckgo.com/html/?q=double',
    ]);
  });

  test(
    'throws immediately during cooldown without network, then recovers',
    () async {
      var now = DateTime(2026, 1, 1);
      var fetches = 0;
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
        ..httpClientAdapter = StubAdapter(routes, onRequest: (_) => fetches++);
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
      expect(fetches, 2);

      await expectLater(
        () => service.search('cool'),
        throwsA(
          isA<WebSearchBlockedException>().having(
            (e) => e.message,
            'message',
            startsWith(
              'search backoff active, try again shortly or configure a key',
            ),
          ),
        ),
      );
      expect(fetches, 2, reason: 'cooldown must short-circuit before network');

      now = now.add(const Duration(seconds: 61));
      routes['https://html.duckduckgo.com/html/?q=cool'] = StubResponse(
        200,
        ddgHtmlBody(),
      );
      final recovered = await service.search('cool');
      expect(recovered, hasLength(2));
      expect(fetches, 4);

      now = now.add(const Duration(seconds: 5));
      routes['https://lite.duckduckgo.com/lite/?q=cool2'] = StubResponse(
        200,
        liteAnomalyBody(),
      );
      routes['https://html.duckduckgo.com/html/?q=cool2'] = StubResponse(
        200,
        liteAnomalyBody(),
      );
      await expectLater(
        () => service.search('cool2'),
        throwsA(isA<WebSearchBlockedException>()),
      );
      expect(fetches, 6);
      await expectLater(
        () => service.search('cool2'),
        throwsA(
          isA<WebSearchBlockedException>().having(
            (e) => e.message,
            'message',
            contains('suppressed searches: 1'),
          ),
        ),
      );
      expect(fetches, 6, reason: 'counter reset on success: fresh cooldown');
    },
  );
}
