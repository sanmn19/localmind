import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers/app_providers.dart';
import '../data/tools/tool_registry.dart';
import '../data/tools/builtin_tool_provider.dart';
import '../data/tools/mcp_tool_provider.dart';
import '../data/tools/tool_definition.dart';
import '../data/mcp_server_manager.dart';
import '../data/tool_budget.dart';
import '../../mcp/data/web/keyless_mcp_ring.dart';
import '../../mcp/data/web/web_fetch_service.dart';
import '../../mcp/data/web/web_search_service.dart';

/// Per-turn web-tool budgets, owning state in the notifier's tool path.
/// One instance per app session: consecutive tool rounds of a reply SHARE
/// a budget via the chain token (variantGroupId), and nothing needs
/// disposing — the plain instance dies with this provider.
final webToolBudgetProvider = Provider<WebToolBudget>((ref) {
  return WebToolBudget();
});

final mcpServerManagerProvider = Provider<McpServerManager>((ref) {
  final packageInfo = ref.watch(packageInfoProvider);
  return McpServerManager(appVersion: packageInfo.value?.version ?? '1.0.0');
});

final builtInToolProviderProvider = Provider<BuiltInToolProvider>((ref) {
  final settings = ref.watch(settingsProvider);
  return BuiltInToolProvider(
    calendarToolsEnabled: settings.calendarToolsEnabled,
    locationToolsEnabled: settings.locationToolsEnabled,
  );
});

final toolRegistryProvider = Provider<ToolRegistry>((ref) {
  final mcpServerManager = ref.watch(mcpServerManagerProvider);
  return ToolRegistry(
    providers: [
      ref.watch(builtInToolProviderProvider),
      McpToolProvider(serverManager: mcpServerManager),
    ],
  );
});

final availableToolsProvider = FutureProvider<List<ToolDefinition>>((
  ref,
) async {
  final registry = ref.watch(toolRegistryProvider);
  return registry.listTools();
});

Future<bool> shouldAutoApproveTool(
  String toolName,
  bool webToolsEnabled,
  ToolRegistry registry,
) async => webToolsEnabled && await registry.isLocalWebTool(toolName);

WebSearchProvider webSearchProviderFromName(String name) {
  switch (name) {
    case 'tavily':
      return WebSearchProvider.tavily;
    case 'brave':
      return WebSearchProvider.brave;
    case 'serper':
      return WebSearchProvider.serper;
    case 'searxng':
      return WebSearchProvider.searxng;
    case 'ring':
      return WebSearchProvider.keylessRing;
    case 'auto':
      return WebSearchProvider.auto;
    default:
      return WebSearchProvider.ddgLite;
  }
}

/// Keeps the in-process web MCP server in step with the web tools setting.
///
/// A [Provider] only runs while it is being watched, so a UI surface that
/// should keep the web server in sync MUST watch this provider:
/// `ref.watch(webServerRegistrationProvider);` (used by the MCP tools
/// screen). Rebuilds on any web-tools setting change and (de)registers the
/// `web.search` / `web.fetch` server accordingly. It produces no state —
/// watch it for its side effect.
final webServerRegistrationProvider = Provider<void>((ref) {
  final settings = ref.watch(settingsProvider);
  final manager = ref.watch(mcpServerManagerProvider);
  if (settings.webToolsEnabled) {
    // One ring per registration: search and fetch share session/cursor state
    // so an exa fetch rescue reuses the session a prior search established.
    final ring = KeylessMcpRing();
    manager.addWebServer(
      WebServices(
        search: WebSearchService(
          provider: webSearchProviderFromName(settings.webSearchProvider),
          apiKey: settings.webSearchApiKey,
          searxUrl: settings.webSearxUrl,
          ring: ring,
        ),
        fetch: WebFetchService(fallbackRing: ring),
      ),
    );
  } else if (manager.hasWebServer()) {
    manager.removeServer(webMcpServerLabel);
  }
  ref.onDispose(() {
    if (manager.hasWebServer()) {
      // Not awaited — teardown best-effort.
      manager.removeServer(webMcpServerLabel);
    }
  });
});
