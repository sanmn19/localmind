import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/mcp/data/terminal_mcp_server.dart';
import 'package:localmind/features/skills/data/skills_mcp_server.dart';

import 'tool_definition.dart';
import 'tool_registry.dart';

class McpToolProvider implements ToolProvider {
  final McpServerManager serverManager;

  McpToolProvider({required this.serverManager});

  @override
  Future<List<ToolDefinition>> listTools() async {
    final tools = <ToolDefinition>[];
    for (final label in serverManager.serverLabels) {
      final serverTools = serverManager.getTools(label);
      if (serverTools.isEmpty) continue;
      // providerRef carries the server URL (`local://web`,
      // `local://example-mcp`, or a remote https URL) so ownership of a
      // tool name can be attributed to a concrete server.
      final providerRef = serverManager.getServerUrl(label) ?? label;
      for (final tool in serverTools) {
        tools.add(
          ToolDefinition(
            name: tool.name,
            description: tool.description ?? '',
            inputSchema: tool.inputSchema,
            providerType: ToolProviderType.mcp,
            providerRef: providerRef,
          ),
        );
      }
    }
    return tools;
  }

  @override
  Future<ToolExecutionResult> execute(
    String name,
    Map<String, dynamic> args,
  ) async {
    final owners = [
      for (final label in serverManager.serverLabels)
        if (serverManager.getTools(label).any((t) => t.name == name)) label,
    ];
    if (owners.isEmpty) {
      return const ToolExecutionResult.failure('MCP tool not found');
    }
    // Several servers may expose the same tool name (user-configured
    // remote integrations can shadow the built-in web/terminal tools).
    // ROUTE to a local in-process server when it owns the name:
    // serverLabels is insertion order and the local re-registration on
    // every settings rebuild can reorder, so first-match alone would let
    // a remote registered earlier hijack execution.
    final label = owners.firstWhere(
      (candidate) => localServerManagerUrls.contains(
        serverManager.getServerUrl(candidate),
      ),
      orElse: () => owners.first,
    );
    try {
      final result = await serverManager.callTool(label, name, args);
      return ToolExecutionResult.success(result);
    } catch (e) {
      return ToolExecutionResult.failure(e.toString());
    }
  }
}

const localServerManagerUrls = {
  webMcpServerUrl,
  terminalMcpServerUrl,
  skillsMcpServerUrl,
};
