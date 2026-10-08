import '../mcp_server_manager.dart';
import 'tool_definition.dart';

abstract class ToolProvider {
  Future<List<ToolDefinition>> listTools();
  Future<ToolExecutionResult> execute(String name, Map<String, dynamic> args);
}

class ToolRegistry {
  final List<ToolProvider> providers;

  ToolRegistry({required this.providers});

  Future<List<ToolDefinition>> listTools({Set<String>? allowedTools}) async {
    final all = <ToolDefinition>[];
    for (final provider in providers) {
      all.addAll(await provider.listTools());
    }
    if (allowedTools == null || allowedTools.isEmpty) return all;
    return all.where((t) => allowedTools.contains(t.name)).toList();
  }

  Future<ToolExecutionResult> execute(
    String name,
    Map<String, dynamic> args,
  ) async {
    // Prefer ROUTING to the local in-process web server when it owns the
    // name: a user-configured remote MCP integration exposing a tool with
    // the same name (e.g. `web.search`) must never hijack execution.
    ToolProvider? owner;
    for (final provider in providers) {
      final tools = await provider.listTools();
      if (!tools.any((t) => t.name == name)) continue;
      if (tools.any(
        (t) => t.name == name && t.providerRef == webMcpServerUrl,
      )) {
        owner = provider;
        break;
      }
      owner ??= provider;
    }
    if (owner == null) {
      return const ToolExecutionResult.failure('Tool not found');
    }
    return owner.execute(name, args);
  }

  /// True iff [name] is currently advertised with
  /// `providerRef == webMcpServerUrl` (the in-process web server).
  Future<bool> isLocalWebTool(String name) async {
    for (final provider in providers) {
      final tools = await provider.listTools();
      if (tools.any(
        (t) => t.name == name && t.providerRef == webMcpServerUrl,
      )) {
        return true;
      }
    }
    return false;
  }
}
