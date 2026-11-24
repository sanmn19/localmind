// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'mcp_client.dart';

/// The Binder channel the Android host uses for the on-device MCP hub.
const hubMcpChannelName = 'pro.momin.localmind/mcp_hub';

/// MCP client backed by the on-device hub's bound service.
///
/// The hub's protocol carries tools only (`listTools` / `callTool`), so the
/// resource methods answer empty / unsupported rather than inventing a transport
/// the hub does not have. Consent stays in the hub's own UI.
class HubMcpClient implements McpConnection {
  HubMcpClient({MethodChannel? channel, String version = '1.0.0'})
    : _channel = channel ?? const MethodChannel(hubMcpChannelName),
      _version = version;

  final MethodChannel _channel;
  final String _version;
  bool _initialized = false;
  McpCapabilities? _capabilities;
  Future<McpCapabilities>? _initializationFuture;

  @override
  bool get isInitialized => _initialized;

  @override
  McpCapabilities? get capabilities => _capabilities;

  @override
  Future<McpCapabilities> initialize() async {
    if (_initialized && _capabilities != null) {
      return _capabilities!;
    }
    if (_initializationFuture != null) {
      return _initializationFuture!;
    }

    _initializationFuture = _doInitialize();
    try {
      return await _initializationFuture!;
    } finally {
      _initializationFuture = null;
    }
  }

  Future<McpCapabilities> _doInitialize() async {
    try {
      final raw = await _channel.invokeMapMethod<dynamic, dynamic>(
        'initialize',
        {
          'clientInfo': {'name': 'localmind', 'version': _version},
        },
      );
      final capabilities = McpCapabilities.fromJson(
        raw == null ? const {'tools': true} : Map<String, dynamic>.from(raw),
      );
      _capabilities = capabilities;
      _initialized = true;
      return capabilities;
    } on PlatformException catch (error) {
      _throwHubError('Failed to initialize MCP Hub client', error);
    } on MissingPluginException catch (error) {
      _throwHubError('Failed to initialize MCP Hub client', error);
    }
  }

  @override
  Future<List<McpTool>> listTools() async {
    if (!_initialized) {
      await initialize();
    }

    try {
      final raw = await _channel.invokeMethod<String>('listTools');
      if (raw == null || raw.isEmpty) return [];

      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('catalogue is not a JSON object');
      }
      final tools = decoded['tools'];
      if (tools is! List) return [];

      return tools
          .whereType<Map>()
          .map((tool) => McpTool.fromJson(Map<String, dynamic>.from(tool)))
          .toList();
    } on PlatformException catch (error) {
      _throwHubError('Failed to list MCP Hub tools', error);
    } on MissingPluginException catch (error) {
      _throwHubError('Failed to list MCP Hub tools', error);
    } on FormatException catch (error) {
      throw McpException('Failed to parse MCP Hub tool catalogue: $error');
    }
  }

  @override
  Future<String> callTool(String name, Map<String, dynamic> arguments) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      final raw = await _channel.invokeMapMethod<dynamic, dynamic>('callTool', {
        'name': name,
        'arguments': jsonEncode(arguments),
      });
      if (raw == null) {
        throw McpException('MCP Hub tool call returned no result');
      }

      // A publisher that spills its payload into a descriptor hands the text
      // back as `body`; otherwise the MCP result carries the content block.
      final body = raw['body'];
      if (body is String) return body;

      final resultJson = raw['resultJson'];
      if (resultJson is! String) {
        throw McpException('MCP Hub tool call returned no result');
      }
      return _resultText(resultJson);
    } on PlatformException catch (error) {
      _throwHubError('Failed to call MCP Hub tool $name', error);
    } on MissingPluginException catch (error) {
      _throwHubError('Failed to call MCP Hub tool $name', error);
    }
  }

  /// The hub protocol has no resource surface; an empty list is the honest
  /// answer rather than a fabricated resource.
  @override
  Future<List<McpResource>> listResources() async {
    if (!_initialized) {
      await initialize();
    }
    return const [];
  }

  @override
  Future<String> readResource(String uri) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      final text = await _channel.invokeMethod<String>('readResource', {
        'uri': uri,
      });
      return text ?? '';
    } on PlatformException catch (error) {
      _throwHubError('Failed to read MCP Hub resource $uri', error);
    } on MissingPluginException catch (error) {
      _throwHubError('Failed to read MCP Hub resource $uri', error);
    }
  }

  @override
  Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('close');
    } on PlatformException {
      // A hub that already went away needs no further cleanup.
    } on MissingPluginException {
      // Non-Android hosts have no Binder channel to close.
    } finally {
      _initialized = false;
      _capabilities = null;
    }
  }

  /// Reads the first text block of an MCP `CallToolResult`. A payload that is
  /// not a result object (some publishers answer with bare text) is returned
  /// verbatim; a result with empty content yields an empty string, matching
  /// [McpClient.callTool].
  String _resultText(String resultJson) {
    Object? decoded;
    try {
      decoded = jsonDecode(resultJson);
    } on FormatException {
      return resultJson;
    }
    if (decoded is! Map) return resultJson;

    final content = decoded['content'];
    if (content is! List) return resultJson;
    if (content.isEmpty) return '';

    final first = content.first;
    if (first is Map && first['text'] is String) {
      return first['text'] as String;
    }
    return resultJson;
  }

  Never _throwHubError(String action, Object error) {
    if (error is PlatformException) {
      throw McpException('$action: ${error.message ?? error.code}');
    }
    if (error is MissingPluginException) {
      throw McpException('$action: the MCP Hub channel is unavailable');
    }
    throw McpException('$action: $error');
  }
}
