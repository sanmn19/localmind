import '../mcp_server_manager.dart';
import '../../../mcp/data/device_mcp_server.dart';
import '../../../mcp/data/terminal_mcp_server.dart';
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
    // Prefer ROUTING to the in-process local MCP servers (web/terminal)
    // when they own the name: a user-configured remote MCP integration
    // exposing a tool with the same name must never hijack execution.
    ToolProvider? owner;
    for (final provider in providers) {
      final tools = await provider.listTools();
      if (!tools.any((t) => t.name == name)) continue;
      if (tools.any((t) => t.name == name && _isLocalUrl(t.providerRef))) {
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

  /// True iff [name] is currently advertised with a `providerRef` in
  /// [localUrls] (e.g. the in-process `local://web` or `local://terminal`
  /// servers). Used for prefer-local routing AND for the ownership test that
  /// keeps remote MCP servers from inheriting local auto-approval.
  Future<bool> isLocalTool(String name, Set<String> localUrls) async {
    for (final provider in providers) {
      final tools = await provider.listTools();
      if (tools.any(
        (t) => t.name == name && localUrls.contains(t.providerRef),
      )) {
        return true;
      }
    }
    return false;
  }

  /// True iff [name] is currently advertised with
  /// `providerRef == webMcpServerUrl` (the in-process web server).
  Future<bool> isLocalWebTool(String name) =>
      isLocalTool(name, {webMcpServerUrl});

  /// True iff [name] is currently advertised with
  /// `providerRef == terminalMcpServerUrl` (the in-process terminal server).
  Future<bool> isLocalTerminalTool(String name) =>
      isLocalTool(name, {terminalMcpServerUrl});

  static bool _isLocalUrl(String? providerRef) =>
      providerRef == webMcpServerUrl ||
      providerRef == terminalMcpServerUrl ||
      providerRef == deviceMcpServerUrl;
}
