// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:localmind/core/services/device_tools_service.dart';
import 'package:localmind/features/mcp/data/device_contacts_repository.dart';
import 'package:localmind/features/mcp/data/device_mcp_server.dart';
import 'package:localmind/features/mcp/data/terminal_mcp_server.dart';
import 'package:localmind/features/mail/data/mail_common.dart';
import 'package:localmind/features/mail/mail_mcp_server.dart';
import 'package:localmind/features/mcp/data/web/web_fetch_service.dart';
import 'package:localmind/features/mcp/data/web/web_search_service.dart';

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
  final Map<String, DeviceServices> _deviceServices = {};
  final Map<String, MailServices> _mailServices = {};
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
    _deviceServices.remove(label);
    _mailServices.remove(label);
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

  /// Test/inspection seam for the terminal services bundle.
  @visibleForTesting
  TerminalServices? getTerminalServices() =>
      _terminalServices[terminalMcpServerLabel];

  /// Registers the in-process device MCP server (`apps.*` + `contacts.*`).
  /// Mirrors [addWebServer]'s idempotent re-add semantics so a settings
  /// rebuild just replaces it. Every tool routes through the injected
  /// [DeviceServices] — the OS app / ContentProvider is the real gate, so
  /// this server performs no network or send-side action itself.
  Future<void> addDeviceServer(DeviceServices services) async {
    await removeServer(deviceMcpServerLabel);

    _deviceServices[deviceMcpServerLabel] = services;
    _capabilities[deviceMcpServerLabel] = const McpCapabilities(tools: true);
    _tools[deviceMcpServerLabel] = const [
      McpTool(
        name: 'apps.compose_email',
        description:
            'Open the device mail app pre-filled with an email (to/subject/'
            'body, optional comma-separated cc). No message is sent '
            'automatically — the user reviews and sends in their mail app.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'to': {
              'type': 'string',
              'description':
                  'Recipient e-mail address (or comma-separated addresses).',
            },
            'subject': {'type': 'string', 'description': 'Subject line.'},
            'body': {'type': 'string', 'description': 'Plain-text body.'},
            'cc': {
              'type': 'string',
              'description': 'Optional comma-separated copy-to addresses.',
            },
          },
          'required': ['to', 'subject', 'body'],
        },
      ),
      McpTool(
        name: 'apps.open',
        description:
            'Launch an installed app by package name (e.g. com.example.app) '
            'or open a deep link URI that carries a scheme '
            '(https://..., localmind://...).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'target': {
              'type': 'string',
              'description': 'Package name or deep-link URI.',
            },
          },
          'required': ['target'],
        },
      ),
      McpTool(
        name: 'apps.list_installed',
        description:
            'List installed apps on this device (label + package name). Use '
            'the package name with apps.open to launch one.',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
      McpTool(
        name: 'apps.screenshot',
        description:
            'Screenshot an app or the whole screen. With scroll=true, '
            'scrolls and stitches a long image until the content ends (max '
            '6 screens). The model must treat the [path=…] marker in the '
            'result as the attached image context.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'package': {
              'type': 'string',
              'description':
                  'Optional package name to launch first (and let settle) '
                  'before capturing. Omit to screenshot the current screen.',
            },
            'scroll': {
              'type': 'boolean',
              'description':
                  'Swipe up, re-capture and stitch a tall long-screenshot '
                  'instead of a single frame. Defaults to false.',
            },
          },
        },
      ),
      McpTool(
        name: 'contacts.search',
        description:
            'Search the device contacts by name or detail and return name, '
            'e-mails and phone numbers.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'Free-text contact look-up.',
            },
          },
          'required': ['query'],
        },
      ),
      McpTool(
        name: 'contacts.by_email',
        description: 'Find device contacts matching an e-mail address.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'email': {'type': 'string', 'description': 'E-mail to match.'},
          },
          'required': ['email'],
        },
      ),
      McpTool(
        name: 'contacts.by_phone',
        description: 'Find device contacts matching a phone number.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'phone': {'type': 'string', 'description': 'Phone to match.'},
          },
          'required': ['phone'],
        },
      ),
    ];
    _serverUrls[deviceMcpServerLabel] = deviceMcpServerUrl;
  }

  /// Registers the in-process mail MCP server (`mail.*`): dispatches to the
  /// connected accounts' repositories. Re-add replaces the bundle (new
  /// account/token material), mirroring [addWebServer].
  Future<void> addMailServer(MailServices services) async {
    await removeServer(mailMcpServerLabel);

    _mailServices[mailMcpServerLabel] = services;
    _capabilities[mailMcpServerLabel] = const McpCapabilities(tools: true);
    _tools[mailMcpServerLabel] = const [
      McpTool(
        name: 'mail.list_messages',
        description:
            'List recent messages from the connected mail account. Returns '
            'numbered rows: sender — subject, snippet, ISO date.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description':
                  'Optional mail search query (Gmail-style operators apply). '
                  'Defaults to the most recent inbox messages.',
            },
            'limit': {
              'type': 'integer',
              'description': 'How many messages (1-10). Defaults to 10.',
            },
          },
        },
      ),
      McpTool(
        name: 'mail.search',
        description:
            'Search the connected mail account. Returns the same '
            'numbered rows as mail.list_messages.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'The search query (e.g. from:carol invoice).',
            },
            'limit': {
              'type': 'integer',
              'description': 'How many results (1-10). Defaults to 10.',
            },
          },
          'required': ['query'],
        },
      ),
      McpTool(
        name: 'mail.read_message',
        description:
            'Read one message fully by id (from mail.list_messages / '
            'mail.search rows or a previously returned id).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': 'The message id.'},
          },
          'required': ['id'],
        },
      ),
      McpTool(
        name: 'mail.send',
        description:
            'Send an e-mail from the connected account. ALWAYS presents an '
            'approval dialog in the app before anything goes out.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'to': {
              'type': 'string',
              'description': 'The recipient e-mail address.',
            },
            'subject': {'type': 'string', 'description': 'Subject line.'},
            'body': {
              'type': 'string',
              'description': 'Plain-text body of the e-mail.',
            },
            'provider': {
              'type': 'string',
              'description':
                  "Which connected account to send with ('gmail' or "
                  "'outlook'). Optional when only one account is connected.",
            },
          },
          'required': ['to', 'subject', 'body'],
        },
      ),
    ];
    _serverUrls[mailMcpServerLabel] = mailMcpServerUrl;
  }

  /// Test/inspection seam for the mail services bundle.
  @visibleForTesting
  MailServices? getMailServices() => _mailServices[mailMcpServerLabel];

  bool hasMailServer() => _mailServices.containsKey(mailMcpServerLabel);

  /// Test/inspection seam for the device services bundle.
  @visibleForTesting
  DeviceServices? getDeviceServices() => _deviceServices[deviceMcpServerLabel];

  bool hasServer(String label) =>
      _clients.containsKey(label) ||
      _localExampleServers.contains(label) ||
      _webServices.containsKey(label) ||
      _terminalServices.containsKey(label) ||
      _deviceServices.containsKey(label) ||
      _mailServices.containsKey(label);

  bool hasExampleServer() =>
      _localExampleServers.contains(exampleMcpServerLabel);

  bool hasWebServer() => _webServices.containsKey(webMcpServerLabel);

  bool hasTerminalServer() =>
      _terminalServices.containsKey(terminalMcpServerLabel);

  bool hasDeviceServer() => _deviceServices.containsKey(deviceMcpServerLabel);

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

    if (_deviceServices.containsKey(serverLabel)) {
      return _callDeviceTool(toolName, args);
    }

    if (_mailServices.containsKey(serverLabel)) {
      return _callMailTool(toolName, args);
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
    _deviceServices.clear();
    _mailServices.clear();
    _localExampleServers.clear();
  }

  int _clampInt(
    Map<String, dynamic> args,
    String key,
    int min,
    int max,
    int fallback,
  ) {
    final value = args[key];
    if (value is! int) return fallback;
    return value.clamp(min, max);
  }

  /// The mail tools dispatch across every connected account. A single
  /// connected provider keeps the bare rows; multiple add `[provider]`
  /// section headers so message ids stay provider-attributable, which is
  /// what read/send's `provider` argument consumes.
  /// Connected-repository selection honoring an optional `provider` arg.
  List<(MailProvider, MailMessageApi)> _mailApisFor(
    MailServices services,
    String? providerFilter,
  ) {
    final wanted = providerFilter == null || providerFilter.isEmpty
        ? null
        : MailProviderName.fromName(providerFilter);
    final apis = <(MailProvider, MailMessageApi)>[
      if (wanted == null || wanted == MailProvider.gmail)
        (MailProvider.gmail, services.gmail),
      if (services.outlook != null &&
          (wanted == null || wanted == MailProvider.outlook))
        (MailProvider.outlook, services.outlook!),
    ];
    return apis;
  }

  Future<String> _renderPerProvider(
    List<(MailProvider, MailMessageApi)> apis,
    Future<List<MailMessageSummary>> Function(MailMessageApi api) fetch,
  ) async {
    final rendered = <String>[];
    final multiProvider = apis.length > 1;
    for (final (provider, api) in apis) {
      final rows = mailListRender(await fetch(api));
      rendered.add(
        multiProvider ? '[${MailProviderName.nameOf(provider)}]\n$rows' : rows,
      );
    }
    return rendered.join('\n\n');
  }

  Future<String> _callMailTool(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    final services = _mailServices[mailMcpServerLabel];
    if (services == null) {
      throw McpException('Mail server is not connected');
    }

    final apis = _mailApisFor(services, args['provider']?.toString());
    if (apis.isEmpty) {
      throw McpException('No mail account matches the requested provider');
    }
    try {
      switch (toolName) {
        case 'mail.list_messages':
        case 'mail.search':
          final limit = _clampInt(args, 'limit', 1, 10, 10);
          if (toolName == 'mail.search') {
            final query = args['query'];
            if (query is! String || query.trim().isEmpty) {
              throw McpException('mail.search requires a query string');
            }
            return mailToolOutput(
              await _renderPerProvider(
                apis,
                (api) => api.search(query, limit: limit),
              ),
            );
          }
          return mailToolOutput(
            await _renderPerProvider(
              apis,
              (api) => api.listMessages(limit: limit),
            ),
          );
        case 'mail.read_message':
          final id = args['id'];
          if (id is! String || id.trim().isEmpty) {
            throw McpException('mail.read_message requires a message id');
          }
          final (_, MailMessageApi sendTarget) = apis.first;
          final message = await sendTarget.readMessage(id);
          return mailToolOutput(mailReadRender(message));
        case 'mail.send':
          final to = args['to'];
          final subject = args['subject'];
          final body = args['body'];
          if (to is! String || to.trim().isEmpty) {
            throw McpException('mail.send requires a recipient address (to)');
          }
          if (subject is! String || subject.trim().isEmpty) {
            throw McpException('mail.send requires a subject');
          }
          if (body is! String || body.isEmpty) {
            throw McpException('mail.send requires a body');
          }
          final (MailProvider provider, MailMessageApi sendApi) = apis.first;
          final id = await sendApi.send(to, subject, body);
          return 'Sent e-mail to $to (id $id)';
        default:
          throw McpException('Mail MCP tool not found: $toolName');
      }
    } on MailConnectorException catch (error) {
      return 'ERROR: ${error.message}';
    }
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

  /// Device dispatch — mirrors the terminal/web dispatch shape. Failures of
  /// the backing channels surface as `ERROR: ...` strings (the model stays
  /// readable); known-but-bad arguments reject with [McpException].
  Future<String> _callDeviceTool(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    final services = _deviceServices[deviceMcpServerLabel];
    if (services == null) {
      throw McpException('MCP server not connected: $deviceMcpServerLabel');
    }

    try {
      switch (toolName) {
        case 'apps.compose_email':
          final to = args['to'];
          final subject = args['subject'];
          final body = args['body'];
          if (to is! String || subject is! String || body is! String) {
            throw McpException(
              'apps.compose_email requires string to/subject/body arguments',
            );
          }
          if (to.trim().isEmpty) {
            return 'ERROR: recipient address is required';
          }
          return await services.launcher.composeEmail(
            to: to,
            subject: subject,
            body: body,
            cc: _composeCcList(args['cc']),
          );

        case 'apps.open':
          final target = args['target'];
          if (target is! String) {
            throw McpException('apps.open requires a string target');
          }
          if (!isValidOpenTarget(target)) {
            return 'ERROR: not a valid package or deep link: $target';
          }
          return await services.launcher.open(target);

        case 'apps.list_installed':
          return formatDeviceAppList(await services.launcher.listInstalled());

        case 'apps.screenshot':
          final rawPackage = args['package'];
          if (rawPackage != null && rawPackage is! String) {
            throw McpException(
              'apps.screenshot requires a string package argument',
            );
          }
          final package = rawPackage as String?;
          if (package != null &&
              package.trim().isNotEmpty &&
              !isValidOpenTarget(package.trim())) {
            return 'ERROR: not a valid package: $package';
          }
          final scroll = args['scroll'] is bool
              ? args['scroll']! as bool
              : false;
          return await services.screenshot.screenshot(
            package: (package?.trim().isEmpty ?? true) ? null : package!.trim(),
            scroll: scroll,
          );

        case 'contacts.search':
          final query = args['query'];
          if (query is! String) {
            throw McpException('contacts.search requires a string query');
          }
          return formatContactSummaries(await services.contacts.search(query));

        case 'contacts.by_email':
          final email = args['email'];
          if (email is! String) {
            throw McpException('contacts.by_email requires a string email');
          }
          return formatContactSummaries(await services.contacts.byEmail(email));

        case 'contacts.by_phone':
          final phone = args['phone'];
          if (phone is! String) {
            throw McpException('contacts.by_phone requires a string phone');
          }
          return formatContactSummaries(await services.contacts.byPhone(phone));

        default:
          throw McpException('Device MCP tool not found: $toolName');
      }
    } on ContactsPermissionDenied {
      // Deliberate rejection surface for the denied READ_CONTACTS gate (the
      // runtime prompt was refused or is permanently denied): guide the user
      // to system settings instead of the generic channel line.
      return 'ERROR: contacts permission needed — grant it in system settings';
    } on DeviceChannelUnavailable catch (error) {
      // The screenshot capture needs the accessibility service; a disabled
      // one gets its own actionable guidance instead of the generic line.
      if (error.reason == deviceToolsErrorScreenCaptureServiceOff) {
        return "ERROR: enable LocalMind's Screen Capture in "
            'Accessibility settings';
      }
      return 'ERROR: device channel unavailable';
    }
  }

  /// `cc` accepts either a comma-separated string or a list of addresses;
  /// empty input yields no cc segment at all.
  List<String>? _composeCcList(dynamic raw) {
    if (raw is List) {
      final entries = [
        for (final item in raw)
          if (item is String && item.trim().isNotEmpty) item.trim(),
      ];
      return entries.isEmpty ? null : entries;
    }
    if (raw is String) {
      final entries = [
        for (final part in raw.split(','))
          if (part.trim().isNotEmpty) part.trim(),
      ];
      return entries.isEmpty ? null : entries;
    }
    return null;
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
