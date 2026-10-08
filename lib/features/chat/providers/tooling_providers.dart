import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers/app_providers.dart';
import '../data/tools/tool_registry.dart';
import '../data/tools/builtin_tool_provider.dart';
import '../data/tools/mcp_tool_provider.dart';
import '../data/tools/tool_definition.dart';
import '../data/mcp_server_manager.dart';
import '../data/tool_budget.dart';
import '../../mcp/data/terminal_mcp_server.dart';
import '../../mcp/data/web/keyless_mcp_ring.dart';
import '../../mcp/data/web/web_fetch_service.dart';
import '../../mcp/data/web/web_search_service.dart';
import '../../skills/data/skills_mcp_server.dart';
import '../../skills/data/skills_provider.dart';
import '../../skills/data/skills_store.dart';

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
  String toolName, {
  Map<String, dynamic> args = const {},
  required bool webToolsEnabled,
  required bool terminalToolsEnabled,
  required bool skillsEnabled,
  required ToolRegistry registry,
  required TerminalWhitelist? whitelist,
}) async {
  if (toolName == 'calc.add' || toolName == 'calc.multiply') return true;

  if (await registry.isLocalTool(toolName, {webMcpServerUrl})) {
    return webToolsEnabled;
  }

  if (await registry.isLocalTool(toolName, {terminalMcpServerUrl})) {
    if (!terminalToolsEnabled) return false;
    switch (toolName) {
      case 'net.http':
        return whitelist?.allowsTool(
              TerminalWhitelist.whitelistOnlyToolEntry,
            ) ??
            false;
      case 'terminal.run':
        final command = args['command'] is String
            ? args['command']! as String
            : '';
        return whitelist?.allows(command) ?? false;
      default:
        return false;
    }
  }

  if (await registry.isLocalTool(toolName, {skillsMcpServerUrl})) {
    // Reads ride the standard local-server bypass. Writes NEVER auto-approve:
    // adding or deleting skills from chat always goes through the approval
    // dialog, whatever the toggle says — the user must see it happen.
    if (toolName == 'skills.list') return skillsEnabled;
    return false;
  }

  return false;
}

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

/// Keeps the in-process local MCP servers in step with their settings.
///
/// A [Provider] only runs while it is being watched, so a UI surface that
/// should keep the web, terminal AND skills servers in sync MUST watch this
/// provider: `ref.watch(webServerRegistrationProvider);` (used by the MCP
/// tools screen). Rebuilds on any settings change and (de)registers the
/// `web.search` / `web.fetch` server, the `terminal.run` / `net.http`
/// server and the `skills.list` / `skills.add` / `skills.delete` server
/// accordingly. The historical provider/web-host names are kept even though
/// this now covers all local servers (cosmetic only).
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
  if (settings.terminalToolsEnabled) {
    // Fresh services each rebuild — a whitelist edit re-registers the
    // server so the approval layer sees the current entries immediately.
    manager.addTerminalServer(
      TerminalServices(
        runner: const ShellProcessRunner(),
        http: NetHttpTool(),
        whitelist: TerminalWhitelist(settings.toolWhitelist),
      ),
    );
  } else if (manager.hasTerminalServer()) {
    manager.removeServer(terminalMcpServerLabel);
  }
  if (settings.skillsEnabled) {
    // ASYMMETRY (by design): the registration only re-runs on a SETTINGS
    // change, but the write tools bridge straight into the skills provider —
    // every store write is followed by SkillsNotifier.refresh(), so the
    // next chat request's system-builder picks model-added skills up
    // mid-conversation without waiting for a re-registration.
    manager.addSkillsServer(
      SkillsServices(
        list: () => SkillsStore(ref.read(skillsFileHostProvider)).refresh(),
        add: (name, description, content) async {
          final store = SkillsStore(ref.read(skillsFileHostProvider));
          await store.add(
            SkillEntry(name: name, description: description, body: content),
          );
          await ref.read(skillsProvider.notifier).refresh();
        },
        delete: (name) async {
          await SkillsStore(ref.read(skillsFileHostProvider)).delete(name);
          await ref.read(skillsProvider.notifier).refresh();
        },
        enabled: () => ref.read(settingsProvider).skillsEnabled,
      ),
    );
  } else if (manager.hasSkillsServer()) {
    manager.removeServer(skillsMcpServerLabel);
  }
  ref.onDispose(() {
    if (manager.hasWebServer()) {
      // Not awaited — teardown best-effort.
      manager.removeServer(webMcpServerLabel);
    }
    if (manager.hasTerminalServer()) {
      manager.removeServer(terminalMcpServerLabel);
    }
    if (manager.hasSkillsServer()) {
      manager.removeServer(skillsMcpServerLabel);
    }
  });
});
