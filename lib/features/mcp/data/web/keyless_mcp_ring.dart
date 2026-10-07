import 'dart:convert';

import 'package:dio/dio.dart';

import 'web_search_service.dart';

/// Anonymous MCP-over-HTTP search/extraction vendors (exa, parallel).
/// Browser-grade headers ([webChromeUserAgent]) are mandatory — these
/// endpoints deny non-browser user-agents with Cloudflare 1010.
class KeylessMcpRing {
  KeylessMcpRing({Dio? dio, this.clock}) : dio = dio ?? _defaultDio();

  final Dio dio;
  final DateTime Function()? clock;

  static const _exaUrl = 'https://mcp.exa.ai/mcp';
  static const _parallelUrl = 'https://search.parallel.ai/mcp';

  static const _protocolVersion = '2024-11-05';
  static const _clientInfo = {'name': 'localmind', 'version': '1.0.0'};

  // Ring order; the cursor remembers which vendor to start with next so a
  // throttled vendor is skipped until it proves itself again.
  static const List<_McpVendor> _vendors = [
    _McpVendor.exa,
    _McpVendor.parallel,
  ];

  // Surfaced when every ring vendor reports a rate-limit-shaped failure; the
  // tail tells the model/user the honest escape hatch (a configured key).
  static const _throttledMessage =
      'All web-search vendors are throttled right now — try again shortly '
      'or configure a provider key';

  static const _rateLimitPattern =
      'rate|quota|limit|exceeded|blocked|invalid session';

  final Map<_McpVendor, String> _sessions = {};
  int _cursor = 0;
  int _nextId = 0;

  Future<List<WebSearchResult>> search(
    String query, {
    int numResults = 5,
  }) async {
    final limit = numResults.clamp(1, 8).toInt();
    final start = _cursor;
    for (var step = 0; step < _vendors.length; step++) {
      final index = (start + step) % _vendors.length;
      final vendor = _vendors[index];
      try {
        final text = await _callText(vendor, _searchToolFor(vendor), {
          ..._searchArgsFor(vendor, query, limit),
        });
        return _parseSearchText(text);
      } on _RateLimitedException {
        // Rotate: subsequent searches skip this vendor until it recovers.
        _cursor = (index + 1) % _vendors.length;
      } on _VendorFailureException {
        // A bad-args rejection or parse hiccup is our bug, not the vendor's
        // throttling: keep the cursor, just fall through to the next vendor.
      }
    }
    throw WebSearchBlockedException(_throttledMessage);
  }

  /// Server-rendered page content for [urls] through exa's `web_fetch_exa`.
  Future<String> fetchViaExa(
    List<String> urls, {
    int maxCharacters = 8000,
  }) async {
    try {
      return await _callText(_McpVendor.exa, 'web_fetch_exa', {
        'urls': urls,
        'maxCharacters': maxCharacters,
      });
    } on _RateLimitedException {
      throw const WebSearchBlockedException(
        'exa fetch is throttled right now — try again shortly',
      );
    } on _VendorFailureException catch (failure) {
      throw WebSearchBlockedException('exa fetch failed: ${failure.detail}');
    }
  }

  // One JSON-RPC tools/call with the cached session; on a 404 (session lost)
  // re-initializes exactly once and retries.
  Future<String> _callText(
    _McpVendor vendor,
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    var retriedSession = false;
    while (true) {
      var session = _sessions[vendor] ?? await _initialize(vendor);
      final int id;
      Response<dynamic> response;
      try {
        id = _nextId++;
        response = await _post(
          vendor,
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'method': 'tools/call',
            'params': {'name': tool, 'arguments': arguments},
          }),
          headers: _followUpHeaders(session),
        );
      } on DioException catch (error) {
        if (_isSessionLost(error) && !retriedSession) {
          retriedSession = true;
          _sessions.remove(vendor);
          continue;
        }
        _throwClassified(error.response, vendor);
      }
      final body = (response.data as String?) ?? '';
      final status = response.statusCode ?? 0;
      if (status == 404 && !retriedSession) {
        retriedSession = true;
        _sessions.remove(vendor);
        continue;
      }
      if (status >= 400) _throwClassifiedText(body, status, vendor);
      final parsed = _decodeEnvelope(body, requestId: id);
      if (parsed == null) {
        throw _VendorFailureException('$tool returned no usable message');
      }
      final text = _extractCardContent(vendor, parsed);
      if (_matchesRateLimit(text)) {
        throw const _RateLimitedException();
      }
      return text;
    }
  }

  // POST initialize, capture Mcp-Session-Id, then fire notifications/initialized.
  Future<String> _initialize(_McpVendor vendor) async {
    final id = _nextId++;
    Response<dynamic> response;
    try {
      response = await _post(
        vendor,
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': 'initialize',
          'params': {
            'protocolVersion': _protocolVersion,
            'capabilities': <String, dynamic>{},
            'clientInfo': _clientInfo,
          },
        }),
        headers: _browserHeaders(),
      );
    } on DioException catch (error) {
      _throwClassified(error.response, vendor);
    }
    final body = (response.data as String?) ?? '';
    final status = response.statusCode ?? 0;
    if (status >= 400) _throwClassifiedText(body, status, vendor);
    final parsed = _decodeEnvelope(body, requestId: id);
    if (parsed == null) {
      throw _VendorFailureException('initialize returned no result');
    }
    final sessionId = _sessionHeader(response.headers);
    try {
      await _post(
        vendor,
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        headers: sessionId == null
            ? _browserHeaders()
            : _followUpHeaders(sessionId),
      );
    } on DioException {
      // The notification is a courtesy ping — failures are non-fatal.
    }
    if (sessionId != null) _sessions[vendor] = sessionId;
    return sessionId ?? '';
  }

  Future<Response<dynamic>> _post(
    _McpVendor vendor,
    String body, {
    required Map<String, String> headers,
  }) {
    return dio.postUri<dynamic>(
      Uri.parse(_urlFor(vendor)),
      data: body,
      options: Options(
        responseType: ResponseType.plain,
        contentType: Headers.jsonContentType,
        headers: headers,
      ),
    );
  }

  Map<String, String> _browserHeaders() => const {
    'User-Agent': webChromeUserAgent,
    'Accept-Language': 'en-US,en;q=0.9',
    'Accept': 'application/json, text/event-stream',
  };

  Map<String, String> _followUpHeaders(String session) => {
    ..._browserHeaders(),
    if (session.isNotEmpty) 'Mcp-Session-Id': session,
    'MCP-Protocol-Version': _protocolVersion,
  };

  String _urlFor(_McpVendor vendor) => switch (vendor) {
    _McpVendor.exa => _exaUrl,
    _McpVendor.parallel => _parallelUrl,
  };

  String _searchToolFor(_McpVendor vendor) => switch (vendor) {
    _McpVendor.exa => 'web_search_exa',
    _McpVendor.parallel => 'web_search',
  };

  Map<String, dynamic> _searchArgsFor(
    _McpVendor vendor,
    String query,
    int limit,
  ) => switch (vendor) {
    _McpVendor.exa => {'query': query, 'numResults': limit},
    // parallel's web_search schema: objective, search_queries
    // (session_id/model_name optional) — max_results is not accepted.
    _McpVendor.parallel => {
      'objective': query,
      'search_queries': [query],
    },
  };

  String? _sessionHeader(Headers headers) {
    for (final entry in headers.map.entries) {
      if (entry.key.toLowerCase() == 'mcp-session-id') {
        final values = entry.value;
        if (values.isNotEmpty) return values.first;
      }
    }
    return null;
  }

  bool _isSessionLost(DioException error) =>
      error.response?.statusCode == 404 ||
      (error.response?.data is String &&
          _asText(error.response?.data).contains('invalid session'));

  // Any 429, or any failure/echo text with rate-limit-shaped wording, counts
  // as throttling and rotates the ring.
  bool _matchesRateLimit(String text) =>
      RegExp(_rateLimitPattern, caseSensitive: false).hasMatch(text);

  Never _throwClassified(Response<dynamic>? response, _McpVendor vendor) {
    final status = response?.statusCode ?? 0;
    _throwClassifiedText(_asText(response?.data), status, vendor);
  }

  Never _throwClassifiedText(String body, int status, _McpVendor vendor) {
    if (status == 429 || _matchesRateLimit(body)) {
      throw const _RateLimitedException();
    }
    throw _VendorFailureException('$vendor responded with HTTP $status');
  }

  // Decodes either vendor transport shape: plain JSON (parallel) or SSE with
  // `data:` lines (exa). Prefers the envelope whose id echoes the request;
  // falls back to the last decodable envelope for servers that don't echo.
  Map<String, dynamic>? _decodeEnvelope(String body, {required int requestId}) {
    final candidates = <Map<String, dynamic>>[];
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) candidates.add(decoded);
        if (decoded is List) {
          candidates.addAll(decoded.whereType<Map<String, dynamic>>());
        }
      } on FormatException {
        return null;
      }
    } else {
      for (final line in body.split('\n')) {
        final data = line.trim();
        if (!data.startsWith('data:')) continue;
        final payload = data.substring('data:'.length).trim();
        if (payload.isEmpty) continue;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map<String, dynamic>) candidates.add(decoded);
        } on FormatException {
          // Ignore malformed lines; the next data line may be the response.
        }
      }
    }
    for (final envelope in candidates.reversed) {
      if (envelope['id'] == requestId &&
          (envelope.containsKey('result') || envelope.containsKey('error'))) {
        return envelope;
      }
    }
    for (final envelope in candidates.reversed) {
      if (envelope.containsKey('result') || envelope.containsKey('error')) {
        return envelope;
      }
    }
    return null;
  }

  // Result envelope → content text; jsonrpc errors and isError results are
  // vendor failures unless their text reads as a rate-limit hit.
  String _extractCardContent(_McpVendor vendor, Map<String, dynamic> envelope) {
    final error = envelope['error'];
    if (error is Map<String, dynamic>) {
      final message = (error['message'] ?? '').toString();
      if (_matchesRateLimit(message)) throw const _RateLimitedException();
      throw _VendorFailureException('$vendor error: $message');
    }
    final result = envelope['result'];
    if (result is! Map<String, dynamic>) {
      throw _VendorFailureException('$vendor returned no result object');
    }
    if (result['isError'] == true) {
      final content = _joinTextContent(result);
      if (_matchesRateLimit(content)) throw const _RateLimitedException();
      throw _VendorFailureException('$vendor reported a tool error');
    }
    final text = _joinTextContent(result);
    if (text.isEmpty) {
      throw _VendorFailureException('$vendor returned empty content');
    }
    return text;
  }

  String _joinTextContent(Map<String, dynamic> result) {
    final content = result['content'];
    if (content is! List) return '';
    return [
      for (final block in content)
        if (block is Map<String, dynamic> && block['type'] == 'text')
          (block['text'] ?? '').toString(),
    ].join('\n');
  }

  // exa (and parallel) search content lists blocks line-by-line:
  //   Title: Example
  //   URL: https://...
  //   <snippet lines until the next Title:>
  // Unparsable text is still returned as one unlinked row so the model can
  // read it; the manager renders row URLs as plain lines (empty URL is fine).
  List<WebSearchResult> _parseSearchText(String text) {
    final results = <WebSearchResult>[];
    String? title;
    var url = '';
    final snippet = <String>[];
    void flush() {
      if (title == null) return;
      results.add(WebSearchResult(title!, url, snippet.join(' ').trim()));
      title = null;
      url = '';
      snippet.clear();
    }

    for (final line in text.split('\n')) {
      final lineValue = line.trim();
      if (lineValue.startsWith('Title:')) {
        flush();
        title = lineValue.substring('Title:'.length).trim();
      } else if (lineValue.startsWith('URL:') && title != null) {
        url = lineValue.substring('URL:'.length).trim();
      } else if (title != null && lineValue.isNotEmpty) {
        snippet.add(lineValue);
      }
    }
    flush();
    if (results.isEmpty) {
      final fallback = text.trim();
      if (fallback.isEmpty) return const [];
      return [WebSearchResult('Results', '', fallback)];
    }
    return results;
  }

  String _asText(Object? value) => value is String ? value : '';

  static Dio _defaultDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );
}

enum _McpVendor { exa, parallel }

class _RateLimitedException implements Exception {
  const _RateLimitedException();
}

class _VendorFailureException implements Exception {
  const _VendorFailureException(this.detail);
  final String detail;
}
