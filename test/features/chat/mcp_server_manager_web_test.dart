import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/mcp_client.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/mcp/data/web/keyless_mcp_ring.dart';
import 'package:localmind/features/mcp/data/web/web_fetch_service.dart';
import 'package:localmind/features/mcp/data/web/web_search_service.dart';

import '../mcp/web/mcp_fixtures.dart';
import '../mcp/web/stub_dio_adapter.dart';

void main() {
  String longBody(int chars) =>
      '<html><body><p>${'B' * chars}</p></body></html>';

  Dio stubbedSearchDio() => Dio()
    ..httpClientAdapter = StubAdapter({
      'https://api.tavily.com/search': StubResponse(
        200,
        jsonEncode({
          'results': [
            {
              'title': 'LocalMind docs',
              'url': 'https://docs.localmind.dev/',
              'content': 'Setup guide',
            },
            {
              'title': 'Second hit',
              'url': 'https://example.org/x',
              'content': 'Other page',
            },
          ],
        }),
      ),
    });

  Dio stubbedFetchDio() => Dio()
    ..httpClientAdapter = StubAdapter({
      'https://example.com/page': StubResponse(
        200,
        '<html><head><title>Page</title></head>'
        '<body><p>Hello web</p></body></html>',
      ),
      'https://example.com/long': StubResponse(200, longBody(9000)),
    });

  Future<McpServerManager> managerWithServices() async {
    final searchDio = stubbedSearchDio();
    final fetchDio = stubbedFetchDio();
    final manager = McpServerManager();
    await manager.addWebServer(
      WebServices(
        search: WebSearchService(
          provider: WebSearchProvider.tavily,
          apiKey: 'KEY',
          dio: searchDio,
        ),
        fetch: WebFetchService(dio: fetchDio),
      ),
    );
    return manager;
  }

  test('addWebServer registers the local web server', () async {
    final manager = await managerWithServices();

    expect(manager.hasWebServer(), isTrue);
    expect(manager.hasServer(webMcpServerLabel), isTrue);
    expect(manager.getServerUrl(webMcpServerLabel), webMcpServerUrl);
    expect(
      manager.getCapabilities(webMcpServerLabel),
      const McpCapabilities(tools: true),
    );
    final tools = manager.getTools(webMcpServerLabel);
    expect(tools.map((t) => t.name), containsAll(['web.search', 'web.fetch']));
    expect(tools, hasLength(2));
  });

  test('addWebServer coexists with the example server', () async {
    final manager = McpServerManager();
    await manager.addExampleServer();
    await manager.addWebServer(
      WebServices(
        search: WebSearchService(
          provider: WebSearchProvider.tavily,
          dio: stubbedSearchDio(),
        ),
        fetch: WebFetchService(dio: stubbedFetchDio()),
      ),
    );

    expect(manager.hasExampleServer(), isTrue);
    expect(manager.hasWebServer(), isTrue);
    expect(manager.serverCount, 2);
  });

  test('callTool web.search returns a numbered, grep-able list', () async {
    final manager = await managerWithServices();

    final output = await manager.callTool(webMcpServerLabel, 'web.search', {
      'query': 'localmind docs',
    });

    expect(output, startsWith('1. LocalMind docs'));
    expect(output, contains('https://docs.localmind.dev/'));
    expect(output, contains('2. Second hit'));
    expect(output, contains('https://example.org/x'));
  });

  test('callTool web.fetch returns service output verbatim', () async {
    final fetchDio = stubbedFetchDio();
    final manager = McpServerManager();
    await manager.addWebServer(
      WebServices(
        search: WebSearchService(provider: WebSearchProvider.tavily),
        fetch: WebFetchService(dio: fetchDio),
      ),
    );
    final direct = WebFetchService(dio: fetchDio);

    final page = await manager.callTool(webMcpServerLabel, 'web.fetch', {
      'url': 'https://example.com/page',
    });
    expect(page, await direct.fetch('https://example.com/page'));
    expect(page, contains('# Page'));
    expect(page, contains('Hello web'));

    final long = await manager.callTool(webMcpServerLabel, 'web.fetch', {
      'url': 'https://example.com/long',
    });
    expect(long, contains('[truncated after 6000 characters]'));
  });

  test('callTool web.fetch clamps max_chars to 1-8000', () async {
    final fetchDio = stubbedFetchDio();
    final manager = McpServerManager();
    await manager.addWebServer(
      WebServices(
        search: WebSearchService(provider: WebSearchProvider.tavily),
        fetch: WebFetchService(dio: fetchDio),
      ),
    );
    final direct = WebFetchService(dio: fetchDio);

    final clamped = await manager.callTool(webMcpServerLabel, 'web.fetch', {
      'url': 'https://example.com/long',
      'max_chars': 99999,
    });
    expect(
      clamped,
      await direct.fetch('https://example.com/long', maxChars: 8000),
    );

    final tiny = await manager.callTool(webMcpServerLabel, 'web.fetch', {
      'url': 'https://example.com/long',
      'max_chars': 0,
    });
    expect(tiny, await direct.fetch('https://example.com/long', maxChars: 1));
  });

  test('callTool unknown web tool throws McpException', () async {
    final manager = await managerWithServices();

    expect(
      () => manager.callTool(webMcpServerLabel, 'web.nope', {}),
      throwsA(isA<McpException>()),
    );
  });

  test('web.search surfaces keyless ring results end-to-end', () async {
    final ringDio = Dio()
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
      );
    final manager = McpServerManager();
    await manager.addWebServer(
      WebServices(
        search: WebSearchService(
          provider: WebSearchProvider.auto,
          ring: KeylessMcpRing(dio: ringDio),
        ),
        fetch: WebFetchService(),
      ),
    );

    final output = await manager.callTool(webMcpServerLabel, 'web.search', {
      'query': 'ring results',
    });
    expect(output, startsWith('1. Alpha'));
    expect(output, contains('https://a.example/one'));
    expect(output, contains('first snippet line 1 first snippet line 2'));
    expect(output, contains('https://a.example/two'));
  });

  test('unstructured ring rows render without an empty url line', () async {
    final ringDio = Dio()
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
    final manager = McpServerManager();
    await manager.addWebServer(
      WebServices(
        search: WebSearchService(
          provider: WebSearchProvider.auto,
          ring: KeylessMcpRing(dio: ringDio),
        ),
        fetch: WebFetchService(),
      ),
    );

    final output = await manager.callTool(webMcpServerLabel, 'web.search', {
      'query': 'unstructured',
    });
    expect(output, '1. Results\n   _unstructured body_');
  });

  test('removeServer and clear clean the web registry', () async {
    final manager = await managerWithServices();
    await manager.removeServer(webMcpServerLabel);

    expect(manager.hasWebServer(), isFalse);
    expect(manager.serverLabels, isNot(contains(webMcpServerLabel)));

    await manager.addExampleServer();
    await manager.addWebServer(
      WebServices(
        search: WebSearchService(
          provider: WebSearchProvider.tavily,
          dio: stubbedSearchDio(),
        ),
        fetch: WebFetchService(dio: stubbedFetchDio()),
      ),
    );
    await manager.clear();

    expect(manager.hasWebServer(), isFalse);
    expect(manager.hasExampleServer(), isFalse);
    expect(manager.serverCount, 0);
  });
}
