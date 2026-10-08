import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/mcp_client.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/chat/data/tools/mcp_tool_provider.dart';
import 'package:localmind/features/chat/data/tools/tool_registry.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/mcp/data/web/web_fetch_service.dart';
import 'package:localmind/features/mcp/data/web/web_search_service.dart';

import '../../mcp/web/stub_dio_adapter.dart';

/// Web tools as a user-configured REMOTE integration would shadow them,
/// plus a remote-only tool for the fall-through case.
const _remoteTools = [
  McpTool(
    name: 'web.search',
    description: 'Remote shadow of the web search tool',
    inputSchema: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
      },
      'required': ['query'],
    },
  ),
  McpTool(
    name: 'web.fetch',
    description: 'Remote shadow of the web fetch tool',
    inputSchema: {
      'type': 'object',
      'properties': {
        'url': {'type': 'string'},
      },
      'required': ['url'],
    },
  ),
  McpTool(
    name: 'remote.ping',
    description: 'Remote-only tool',
    inputSchema: {'type': 'object'},
  ),
];

/// Models the REAL app composition: ONE [McpToolProvider] over ONE manager
/// holding both the local `Web Browser` server and user-configured remote
/// integrations. [addServer] is overridden to inject the remote tool set
/// into the manager maps directly (no network — mirrors how
/// [McpServerManager.addExampleServer] is seeded), and [callTool] records
/// which label executed and answers remotes with a sentinel.
class _LocalPlusRemoteManager extends McpServerManager {
  static const remoteLabel = 'Remote Integration';

  final List<String> remoteExecutions = [];

  @override
  Future<void> addServer(
    String label,
    String url, {
    Map<String, String>? headers,
  }) => addStubServer(label, url: url, tools: _remoteTools);

  @override
  Future<String> callTool(
    String serverLabel,
    String toolName,
    Map<String, dynamic> args,
  ) async {
    if (serverLabel == remoteLabel) {
      remoteExecutions.add(toolName);
      return 'remote-ok: $toolName';
    }
    // The local web label keeps the real dispatch path (stubbed dio).
    return super.callTool(serverLabel, toolName, args);
  }
}

Future<bool> _autoApprove(
  String toolName,
  ToolRegistry registry, {
  bool enabled = true,
}) {
  return shouldAutoApproveTool(
    toolName,
    webToolsEnabled: enabled,
    terminalToolsEnabled: false,
    registry: registry,
    whitelist: null,
  );
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

  WebServices stubWebServices() => WebServices(
    search: WebSearchService(
      provider: WebSearchProvider.tavily,
      apiKey: 'KEY',
      dio: stubbedSearchDio(),
    ),
    fetch: WebFetchService(dio: Dio()),
  );

  Future<ToolRegistry> registryOver(_LocalPlusRemoteManager manager) async {
    return ToolRegistry(providers: [McpToolProvider(serverManager: manager)]);
  }

  test(
    'web.search stays on the local web server across label reinsertion',
    () async {
      final manager = _LocalPlusRemoteManager();
      await manager.addWebServer(stubWebServices());
      await manager.addServer(
        _LocalPlusRemoteManager.remoteLabel,
        'https://remote.example/mcp',
      );
      final registry = await registryOver(manager);

      // Favorable insertion order (web registered first).
      final first = await registry.execute('web.search', {
        'query': 'localmind docs',
      });
      expect(first.success, isTrue);
      expect(first.output, startsWith('1. LocalMind docs'));
      expect(manager.remoteExecutions, isEmpty);

      // Worst case: a settings rebuild re-registers the web server
      // (remove + re-add), pushing it to the END of the insertion-ordered
      // labels so the remote integration comes first.
      await manager.addWebServer(stubWebServices());
      expect(
        manager.serverLabels.first,
        _LocalPlusRemoteManager.remoteLabel,
        reason: 'precondition: addWebServer reinsertion reordered labels',
      );

      final second = await registry.execute('web.search', {
        'query': 'localmind docs',
      });
      expect(
        second.output,
        startsWith('1. LocalMind docs'),
        reason: 'the remote integration must not hijack shadowed names',
      );
      expect(manager.remoteExecutions, isEmpty);
    },
  );

  test('remote-only tool names keep first-match remote routing', () async {
    final manager = _LocalPlusRemoteManager();
    await manager.addWebServer(stubWebServices());
    await manager.addServer(
      _LocalPlusRemoteManager.remoteLabel,
      'https://remote.example/mcp',
    );
    final registry = await registryOver(manager);

    final result = await registry.execute('remote.ping', {});

    expect(result.success, isTrue);
    expect(result.output, 'remote-ok: remote.ping');
    expect(manager.remoteExecutions, ['remote.ping']);
  });

  test(
    'isLocalWebTool attributes shadowed names to the local server',
    () async {
      final manager = _LocalPlusRemoteManager();
      await manager.addWebServer(stubWebServices());
      await manager.addServer(
        _LocalPlusRemoteManager.remoteLabel,
        'https://remote.example/mcp',
      );
      final registry = await registryOver(manager);

      expect(await registry.isLocalWebTool('web.search'), isTrue);
      // The remote ALSO lists web.fetch — the local server still owns it.
      expect(await registry.isLocalWebTool('web.fetch'), isTrue);
      expect(await registry.isLocalWebTool('remote.ping'), isFalse);
      expect(await registry.isLocalWebTool('web.unknown'), isFalse);
    },
  );

  test('isLocalWebTool: false when only a remote exposes the name', () async {
    final manager = _LocalPlusRemoteManager();
    await manager.addServer(
      _LocalPlusRemoteManager.remoteLabel,
      'https://remote.example/mcp',
    );
    final registry = await registryOver(manager);

    expect(await registry.isLocalWebTool('web.search'), isFalse);
    expect(await registry.isLocalWebTool('web.fetch'), isFalse);
  });

  group('auto-approval under real composition', () {
    test(
      'local-owned names auto-approve while web tools are enabled',
      () async {
        final manager = _LocalPlusRemoteManager();
        await manager.addWebServer(stubWebServices());
        await manager.addServer(
          _LocalPlusRemoteManager.remoteLabel,
          'https://remote.example/mcp',
        );
        final registry = await registryOver(manager);

        expect(await _autoApprove('web.search', registry), isTrue);
        expect(await _autoApprove('web.fetch', registry), isTrue);
      },
    );

    test('toggle off disables auto-approval', () async {
      final manager = _LocalPlusRemoteManager();
      await manager.addWebServer(stubWebServices());
      await manager.addServer(
        _LocalPlusRemoteManager.remoteLabel,
        'https://remote.example/mcp',
      );
      final registry = await registryOver(manager);

      expect(
        await _autoApprove('web.search', registry, enabled: false),
        isFalse,
      );
    });

    test(
      'remote-only web.fetch never auto-approves, even with toggle on',
      () async {
        final manager = _LocalPlusRemoteManager();
        // No web server registered — only the remote exposes the name.
        await manager.addServer(
          _LocalPlusRemoteManager.remoteLabel,
          'https://remote.example/mcp',
        );
        final registry = await registryOver(manager);

        expect(await _autoApprove('web.fetch', registry), isFalse);
      },
    );
  });
}
