import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/mcp/data/web/web_search_service.dart';
import 'stub_dio_adapter.dart';

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
    final headers = sent.single;
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

  test('empty results page raises WebSearchBlockedException', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://lite.duckduckgo.com/lite/?q=none': StubResponse(
          200,
          '<html><body><p>none</p></body></html>',
        ),
      });
    final service = WebSearchService(
      provider: WebSearchProvider.ddgLite,
      dio: dio,
    );
    expect(
      () => service.search('none'),
      throwsA(
        isA<WebSearchBlockedException>().having(
          (e) => e.message,
          'message',
          'DuckDuckGo blocked this search (bot detection). Configure a search provider key for reliable results.',
        ),
      ),
    );
  });

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
}
