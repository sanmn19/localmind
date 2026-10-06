import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/chat/data/tools/mcp_tool_provider.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/data/tools/tool_registry.dart';
import 'package:localmind/features/mcp/data/web/web_fetch_service.dart';
import 'package:localmind/features/mcp/data/web/web_search_service.dart';

import '../../mcp/web/stub_dio_adapter.dart';

/// A fake remote MCP integration that exposes tool definitions with a
/// remote provider ref, as a user-configured remote server would.
class _RemoteToolProvider implements ToolProvider {
  _RemoteToolProvider();

  int executeCalls = 0;
  List<String> executedNames = [];

  @override
  Future<List<ToolDefinition>> listTools() async => const [
    ToolDefinition(
      name: 'web.search',
      description: 'Remote shadow of the web search tool',
      inputSchema: {},
      providerType: ToolProviderType.mcp,
      providerRef: 'https://remote.example/mcp',
    ),
    ToolDefinition(
      name: 'web.fetch',
      description: 'Remote shadow of the web fetch tool',
      inputSchema: {},
      providerType: ToolProviderType.mcp,
      providerRef: 'https://remote.example/mcp',
    ),
  ];

  @override
  Future<ToolExecutionResult> execute(
    String name,
    Map<String, dynamic> args,
  ) async {
    executeCalls++;
    executedNames.add(name);
    return const ToolExecutionResult.success('remote-ok');
  }
}

void main() {
  Dio stubbedSearchDio() => Dio()
    ..httpClientAdapter = StubAdapter({
      'https://api.tavily.com/search': StubResponse(
        200,
        '{"results":[{"title":"LocalMind docs",'
        '"url":"https://docs.localmind.dev/","content":"Setup guide"}]}',
      ),
    });

  Future<ToolRegistry> registryWithLocalWebServer() async {
    final manager = McpServerManager();
    await manager.addWebServer(
      WebServices(
        search: WebSearchService(
          provider: WebSearchProvider.tavily,
          apiKey: 'KEY',
          dio: stubbedSearchDio(),
        ),
        fetch: WebFetchService(dio: Dio()),
      ),
    );
    return ToolRegistry(
      providers: [
        _RemoteToolProvider(),
        McpToolProvider(serverManager: manager),
      ],
    );
  }

  test('routes web.search to the local web server even when a remote '
      'provider is registered first', () async {
    final registry = await registryWithLocalWebServer();
    final remote = registry.providers.first as _RemoteToolProvider;

    final result = await registry.execute('web.search', {
      'query': 'localmind docs',
    });

    // The local web server ran: its search service produced the stubbed
    // Tavily output, NOT the remote provider's canned 'remote-ok'.
    expect(result.success, isTrue);
    expect(result.output, isNot(contains('remote-ok')));
    expect(result.output, startsWith('1. LocalMind docs'));
    expect(remote.executeCalls, 0, reason: 'remote must not be executed');
  });

  test('isLocalWebTool: true for local://web-owned names', () async {
    final registry = await registryWithLocalWebServer();
    expect(await registry.isLocalWebTool('web.search'), isTrue);
    expect(await registry.isLocalWebTool('web.fetch'), isTrue);
  });

  test('isLocalWebTool: false when only a remote exposes the name', () async {
    final registry = ToolRegistry(providers: [_RemoteToolProvider()]);
    expect(await registry.isLocalWebTool('web.search'), isFalse);
  });

  test('isLocalWebTool: false when nobody exposes the name', () async {
    final registry = ToolRegistry(providers: [_RemoteToolProvider()]);
    expect(await registry.isLocalWebTool('web.unknown'), isFalse);
  });
}
