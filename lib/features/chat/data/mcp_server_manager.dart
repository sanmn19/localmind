// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:localmind/features/mcp/data/terminal_mcp_server.dart';
import 'package:localmind/features/mcp/data/web/web_fetch_service.dart';
import 'package:localmind/features/mcp/data/web/web_search_service.dart';
import 'package:localmind/features/skills/data/skills_mcp_server.dart';
import 'package:localmind/features/skills/data/skills_store.dart';

import 'mcp_client.dart';

const exampleMcpServerLabel = 'Example MCP';
const exampleMcpServerUrl = 'local://example-mcp';

const webMcpServerLabel = 'Web Browser';
const webMcpServerUrl = 'local://web';

class WebServices {
  const WebServices({required this.search, required this.fetch});
  final WebSearchService search;
  final WebFetchService fetch;
}

/// Backing services for the in-process `local://terminal` MCP server.
/// The whitelist travels with the services so re-registration (settings
/// change) always refreshes it; it gates APPROVALS only — the manager
/// itself never refuses a call the approval flow allowed.
class TerminalServices {
  const TerminalServices({
    required this.runner,
    required this.http,
    required this.whitelist,
  });
  final TerminalProcessRunner runner;
  final NetHttpTool http;
  final TerminalWhitelist whitelist;
}

class McpServerManager {
  final String _appVersion;
  final Map<String, McpClient> _clients = {};
  final Map<String, McpCapabilities> _capabilities = {};
  final Map<String, List<McpTool>> _tools = {};
  final Map<String, String> _serverUrls = {};
  final Map<String, WebServices> _webServices = {};
  final Map<String, TerminalServices> _terminalServices = {};
  final Map<String, SkillsServices> _skillsServices = {};
  final Set<String> _localExampleServers = {};
  final Set<String> _pendingLabels = {};

  McpServerManager({String appVersion = '1.0.0'}) : _appVersion = appVersion;

  Future<void> addServer(
    String label,
    String url, {
    Map<String, String>? headers,
  }) async {
    // Guard against concurrent addServer calls for the same label.
    if (_pendingLabels.contains(label)) return;
    _pendingLabels.add(label);

    try {
      if (_clients.containsKey(label)) {
        final oldClient = _clients.remove(label);
        await oldClient?.close();
        _capabilities.remove(label);
        _tools.remove(label);
        _serverUrls.remove(label);
      }

      final client = McpClient(
        serverUrl: url,
        headers: headers,
        version: _appVersion,
      );

      final capabilities = await client.initialize();
      final tools = await client.listTools();

      _clients[label] = client;
      _capabilities[label] = capabilities;
      _tools[label] = tools;
      _serverUrls[label] = url;
    } finally {
      _pendingLabels.remove(label);
    }
  }

  Future<void> removeServer(String label) async {
    final client = _clients.remove(label);
    await client?.close();
    _capabilities.remove(label);
    _tools.remove(label);
    _serverUrls.remove(label);
    _webServices.remove(label);
    _terminalServices.remove(label);
    _skillsServices.remove(label);
    _localExampleServers.remove(label);
  }

  Future<void> addExampleServer() async {
    await removeServer(exampleMcpServerLabel);

    _capabilities[exampleMcpServerLabel] = const McpCapabilities(tools: true);
    _tools[exampleMcpServerLabel] = const [
      McpTool(
        name: 'example.echo',
        description: 'Echo a message back from the example MCP server.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'message': {
              'type': 'string',
              'description': 'The message to echo.',
            },
          },
          'required': ['message'],
        },
      ),
      McpTool(
        name: 'example.word_count',
        description: 'Count the words in a text string.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'text': {
              'type': 'string',
              'description': 'The text to count words in.',
            },
          },
          'required': ['text'],
        },
      ),
    ];
    _serverUrls[exampleMcpServerLabel] = exampleMcpServerUrl;
    _localExampleServers.add(exampleMcpServerLabel);
  }

  /// Registers a server without any network round-trip by populating the
  /// internal maps directly (mirrors how [addExampleServer] is seeded).
  ///
  /// Test seam only: the stub label has no client/web/example backing, so
  /// [callTool]'s default dispatch does not serve it — tests that need
  /// execution semantics override [callTool].
  @visibleForTesting
  Future<void> addStubServer(
    String label, {
    required String url,
    required List<McpTool> tools,
    McpCapabilities capabilities = const McpCapabilities(tools: true),
  }) async {
    await removeServer(label);
    _capabilities[label] = capabilities;
    _tools[label] = tools;
    _serverUrls[label] = url;
  }

  Future<void> addWebServer(WebServices services) async {
    await removeServer(webMcpServerLabel);

    _webServices[webMcpServerLabel] = services;
    _capabilities[webMcpServerLabel] = const McpCapabilities(tools: true);
    _tools[webMcpServerLabel] = const [
      McpTool(
        name: 'web.search',
        description:
            'Search the web and return numbered results (title, url, snippet). '
            'Prefer 1-2 precise queries over many broad ones.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': 'The search query.'},
            'max_results': {
              'type': 'integer',
              'description': 'How many results (1-8). Defaults to 6.',
            },
          },
          'required': ['query'],
        },
      ),
      McpTool(
        name: 'web.fetch',
        description:
            'Fetch a web page URL and return its readable content as plain '
            'text (title + body). Use after web.search or for URLs the user '
            'provides.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'url': {
              'type': 'string',
              'description': 'The http(s) URL to fetch.',
            },
            'max_chars': {
              'type': 'integer',
              'description':
                  'Maximum characters of readable content (default 6000, '
                  'max 8000).',
            },
          },
          'required': ['url'],
        },
      ),
    ];
    _serverUrls[webMcpServerLabel] = webMcpServerUrl;
  }

  /// Registers the in-process terminal MCP server (`terminal.run` +
  /// `net.http`). Mirrors [addWebServer]'s idempotent re-add semantics so a
  /// settings rebuild (e.g. a fresh whitelist) just replaces it.
  Future<void> addTerminalServer(TerminalServices services) async {
    await removeServer(terminalMcpServerLabel);

    _terminalServices[terminalMcpServerLabel] = services;
    _capabilities[terminalMcpServerLabel] = const McpCapabilities(tools: true);
    _tools[terminalMcpServerLabel] = const [
      McpTool(
        name: 'terminal.run',
        description:
            'Run a single shell command inside the app sandbox and return '
            'its exit status, stdout and stderr. Simple one-command lines '
            '(no pipes/redirects) may auto-run; anything else asks first.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': 'The shell command line to run.',
            },
          },
          'required': ['command'],
        },
      ),
      McpTool(
        name: 'net.http',
        description:
            'Perform an HTTP request to a public http(s) URL and return the '
            'status plus body. Use for APIs instead of shell curl.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'method': {
              'type': 'string',
              'description': 'HTTP method; defaults to GET.',
            },
            'url': {
              'type': 'string',
              'description': 'The public http(s) URL to request.',
            },
            'headers': {
              'type': 'object',
              'description': 'Optional request headers as name/value pairs.',
            },
            'body': {
              'type': 'string',
              'description': 'Optional request body (usually POST/PUT).',
            },
            'max_chars': {
              'type': 'integer',
              'description':
                  'Maximum characters of the response body (default 8000, '
                  'max 8000).',
            },
          },
          'required': ['url'],
        },
      ),
    ];
    _serverUrls[terminalMcpServerLabel] = terminalMcpServerUrl;
  }

  /// Registers the in-process skills MCP server (`skills.list` /
  /// `skills.read` / `skills.add` / `skills.delete`). Mirrors
  /// [addTerminalServer]'s idempotent re-add semantics so a settings
  /// rebuild just replaces it. Writes stay approval-gated: the bundles
  /// handed here are the only execution path, and auto-approval never
  /// covers `skills.add` / `skills.delete` (see `shouldAutoApproveTool` in
  /// tooling_providers.dart).
  Future<void> addSkillsServer(SkillsServices services) async {
    await removeServer(skillsMcpServerLabel);

    _skillsServices[skillsMcpServerLabel] = services;
    _capabilities[skillsMcpServerLabel] = const McpCapabilities(tools: true);
    _tools[skillsMcpServerLabel] = const [
      McpTool(
        name: 'skills.list',
        description:
            'List the user\'s saved skills. Each row is `- name: '
            'description`; the system context carries only this index — '
            'call skills.read {name} to load a skill\'s full instructions.',
        inputSchema: {'type': 'object'},
      ),
      McpTool(
        name: 'skills.read',
        description:
            'Return the full instructions of one skill by name; use it '
            'before following a skill\'s details.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': 'The skill name.'},
          },
          'required': ['name'],
        },
      ),
      McpTool(
        name: 'skills.add',
        description:
            'Save a new reusable skill: the markdown body is injected into '
            'every future chat when relevant. Names allow lowercase '
            'letters, digits and underscores (max 48).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description':
                  'The skill name; lowercase letters, digits and underscores '
                  '(max 48).',
            },
            'content': {
              'type': 'string',
              'description': 'The markdown body of the skill.',
            },
            'description': {
              'type': 'string',
              'description':
                  'One-line description of when to follow the skill.',
            },
          },
          'required': ['name', 'content'],
        },
      ),
      McpTool(
        name: 'skills.delete',
        description:
            'Delete one of the user\'s saved skills by its exact name.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': 'The skill name.'},
          },
          'required': ['name'],
        },
      ),
    ];
    _serverUrls[skillsMcpServerLabel] = skillsMcpServerUrl;
  }

  /// Test/inspection seam for the skills services bundle.
  @visibleForTesting
  SkillsServices? getSkillsServices() => _skillsServices[skillsMcpServerLabel];

  /// Test/inspection seam for the terminal services bundle.
  @visibleForTesting
  TerminalServices? getTerminalServices() =>
      _terminalServices[terminalMcpServerLabel];

  bool hasServer(String label) =>
      _clients.containsKey(label) ||
      _localExampleServers.contains(label) ||
      _webServices.containsKey(label) ||
      _terminalServices.containsKey(label) ||
      _skillsServices.containsKey(label);

  bool hasExampleServer() =>
      _localExampleServers.contains(exampleMcpServerLabel);

  bool hasWebServer() => _webServices.containsKey(webMcpServerLabel);

  bool hasTerminalServer() =>
      _terminalServices.containsKey(terminalMcpServerLabel);

  bool hasSkillsServer() => _skillsServices.containsKey(skillsMcpServerLabel);

  List<McpTool> getTools(String label) => _tools[label] ?? [];

  Map<String, List<McpTool>> get allTools => Map.unmodifiable(_tools);

  McpCapabilities? getCapabilities(String label) => _capabilities[label];

  String? getServerUrl(String label) => _serverUrls[label];

  Future<String> callTool(
    String serverLabel,
    String toolName,
    Map<String, dynamic> args,
  ) async {
    if (_webServices.containsKey(serverLabel)) {
      return _callWebTool(toolName, args);
    }

    if (_terminalServices.containsKey(serverLabel)) {
      return _callTerminalTool(toolName, args);
    }

    if (_skillsServices.containsKey(serverLabel)) {
      return _callSkillsTool(toolName, args);
    }

    if (_localExampleServers.contains(serverLabel)) {
      return _callExampleTool(toolName, args);
    }

    final client = _clients[serverLabel];
    if (client == null) {
      throw McpException('MCP server not connected: $serverLabel');
    }

    if (!client.isInitialized) {
      await client.initialize();
    }

    return client.callTool(toolName, args);
  }

  Future<String> readResource(String serverLabel, String uri) async {
    final client = _clients[serverLabel];
    if (client == null) {
      throw McpException('MCP server not connected: $serverLabel');
    }

    if (!client.isInitialized) {
      await client.initialize();
    }

    return client.readResource(uri);
  }

  Future<void> clear() async {
    for (final client in _clients.values) {
      await client.close();
    }
    _clients.clear();
    _capabilities.clear();
    _tools.clear();
    _serverUrls.clear();
    _webServices.clear();
    _terminalServices.clear();
    _skillsServices.clear();
    _localExampleServers.clear();
  }

  /// NOTE: the whitelist is deliberately NOT enforced here. It only gates
  /// auto-approval (see `shouldAutoApproveTool` in tooling_providers.dart) —
  /// a non-whitelisted command reaches this point only after the user
  /// approved the dialog, so refusing it here would contradict that decision.
  Future<String> _callTerminalTool(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    final services = _terminalServices[terminalMcpServerLabel];
    if (services == null) {
      throw McpException('MCP server not connected: $terminalMcpServerLabel');
    }

    switch (toolName) {
      case 'terminal.run':
        final command = args['command'];
        if (command is! String) {
          throw McpException('terminal.run requires a string command');
        }
        final result = await services.runner.run(
          command,
          timeout: terminalRunTimeout,
        );
        return formatTerminalRunResult(result);

      case 'net.http':
        final url = args['url'];
        if (url is! String) {
          throw McpException('net.http requires a string url');
        }
        final method = args['method'] is String
            ? args['method'] as String
            : 'GET';
        final body = args['body'] is String ? args['body'] as String : null;
        final rawChars = args['max_chars'];
        final maxChars = rawChars is int
            ? rawChars.clamp(1, netHttpMaxChars).toInt()
            : null;
        return services.http.run(
          method: method,
          url: url,
          headers: _stringHeaders(args['headers']),
          body: body,
          maxChars: maxChars,
        );

      default:
        throw McpException('Terminal MCP tool not found: $toolName');
    }
  }

  /// NOTE: the settings kill switch is NOT re-checked here beyond the
  /// bundle's `enabled` flag — the server only stays registered while
  /// `skillsEnabled` is on, so a refusal here guards the stale-registration
  /// window, not general policy. `skills.add`/`skills.delete` reaching this
  /// point always went through the user's approval dialog.
  Future<String> _callSkillsTool(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    final services = _skillsServices[skillsMcpServerLabel];
    if (services == null) {
      throw McpException('MCP server not connected: $skillsMcpServerLabel');
    }

    if (!services.enabled) {
      throw McpException('the skills feature is disabled');
    }

    switch (toolName) {
      case 'skills.list':
        return formatSkillsList(await services.list());

      case 'skills.read':
        final name = args['name'];
        if (name is! String) {
          throw McpException('skills.read requires a string name');
        }
        final normalizedName = SkillsStore.normalizeName(name);
        final entry = await _findSkill(services, normalizedName);
        if (entry == null) {
          throw McpException('skills.read: no skill named $normalizedName');
        }
        return formatSkillsRead(entry);

      case 'skills.add':
        final name = args['name'];
        if (name is! String) {
          throw McpException('skills.add requires a string name');
        }
        final content = args['content'];
        if (content is! String) {
          throw McpException('skills.add requires a string content');
        }
        final description = args['description'] is String
            ? args['description'] as String
            : '';
        final normalizedName = SkillsStore.normalizeName(name);
        final nameFailure = skillsNameFailure(name);
        if (nameFailure != null) {
          throw McpException('skills.add: $nameFailure');
        }
        final existing = await services.list();
        if (existing.any((entry) => entry.name == normalizedName)) {
          throw McpException(
            'skills.add: a skill named $normalizedName already exists',
          );
        }
        await services.add(normalizedName, description, content);
        return 'Added skill: $normalizedName';

      case 'skills.delete':
        final name = args['name'];
        if (name is! String) {
          throw McpException('skills.delete requires a string name');
        }
        final normalizedName = SkillsStore.normalizeName(name);
        final existing = await services.list();
        if (!existing.any((entry) => entry.name == normalizedName)) {
          throw McpException('skills.delete: no skill named $normalizedName');
        }
        await services.delete(normalizedName);
        return 'Deleted skill: $normalizedName';

      default:
        throw McpException('Skills MCP tool not found: $toolName');
    }
  }

  /// The stored skill matching [name] exactly, or null — the shared
  /// lookup behind the read/delete dispatchers (fresh list each time,
  /// matching `skills.list` semantics).
  static Future<SkillEntry?> _findSkill(
    SkillsServices services,
    String name,
  ) async {
    for (final entry in await services.list()) {
      if (entry.name == name) return entry;
    }
    return null;
  }

  Map<String, String>? _stringHeaders(dynamic raw) {
    if (raw is! Map) return null;
    final headers = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key?.toString() ?? '';
      final value = entry.value?.toString() ?? '';
      if (key.isEmpty) continue;
      headers[key] = value;
    }
    return headers.isEmpty ? null : headers;
  }

  Future<String> _callWebTool(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    final services = _webServices[webMcpServerLabel];
    if (services == null) {
      throw McpException('MCP server not connected: $webMcpServerLabel');
    }

    switch (toolName) {
      case 'web.search':
        final query = args['query'];
        if (query is! String) {
          throw McpException('web.search requires a string query');
        }
        final rawMax = args['max_results'];
        final maxResults = rawMax is int ? rawMax : 6;
        final results = await services.search.search(
          query,
          maxResults: maxResults,
        );
        final lines = <String>[];
        for (final (i, r) in results.indexed) {
          // Unlinked rows (e.g. unstructured ring fallbacks) carry no url —
          // render them as title + snippet only instead of an empty line.
          final urlLine = r.url.isEmpty ? '' : '\n   ${r.url}';
          lines.add("${i + 1}. ${r.title}$urlLine\n   ${r.snippet}");
        }
        return lines.join('\n');
      case 'web.fetch':
        final url = args['url'];
        if (url is! String) {
          throw McpException('web.fetch requires a string url');
        }
        final rawChars = args['max_chars'];
        final maxChars = rawChars is int
            ? rawChars.clamp(1, 8000).toInt()
            : 6000;
        return services.fetch.fetch(url, maxChars: maxChars);
      default:
        throw McpException('Web MCP tool not found: $toolName');
    }
  }

  String _callExampleTool(String toolName, Map<String, dynamic> args) {
    switch (toolName) {
      case 'example.echo':
        final message = args['message'];
        if (message is! String) {
          throw McpException('example.echo requires a string message');
        }
        return message;
      case 'example.word_count':
        final text = args['text'];
        if (text is! String) {
          throw McpException('example.word_count requires a string text value');
        }
        final words = text
            .trim()
            .split(RegExp(r'\s+'))
            .where((word) => word.isNotEmpty)
            .length;
        return words.toString();
      default:
        throw McpException('Example MCP tool not found: $toolName');
    }
  }

  int get serverCount => _tools.length;

  List<String> get serverLabels => _tools.keys.toList();
}
