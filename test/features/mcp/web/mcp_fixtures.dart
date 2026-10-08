import 'dart:convert';

/// Shared MCP-over-HTTP fixture builders for the keyless ring tests.
/// exa answers SSE (`event: message\ndata: {...}`), parallel answers plain
/// JSON — one payload per JSON-RPC id.

const exaMcpUrl = 'https://mcp.exa.ai/mcp';
const parallelMcpUrl = 'https://search.parallel.ai/mcp';

Map<String, dynamic> mcpInitializeResult({String name = 'exa'}) => {
  'protocolVersion': '2024-11-05',
  'capabilities': <String, dynamic>{},
  'serverInfo': {'name': name, 'version': '1.0.0'},
};

Map<String, dynamic> mcpTextResult(String text, {bool isError = false}) => {
  'content': [
    {'type': 'text', 'text': text},
  ],
  'isError': isError,
};

String sseEnvelope(int id, Map<String, dynamic> result) =>
    'event: message\ndata: ${jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result})}\n\n';

String jsonEnvelope(int id, Map<String, dynamic> result) =>
    jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result});

/// exa-shaped search content: 'Title:/URL:' pairs followed by snippet lines.
const mcpPairText =
    'Title: Alpha\nURL: https://a.example/one\nfirst snippet line 1\n'
    'first snippet line 2\nTitle: Beta\nURL: https://a.example/two\n'
    'second snippet';
