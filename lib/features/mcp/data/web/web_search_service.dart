import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as parser;

import 'keyless_mcp_ring.dart';

const webChromeUserAgent =
    'Mozilla/5.0 (Linux; Android 10; K) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

// DuckDuckGo's anomaly detection trips after several close-together searches;
// spacing request starts keeps bursts from escalating into captcha pages.
const _searchInterval = Duration(seconds: 2);

// A fully-blocked keyless chain arms a cooldown so a model retry loop cannot
// hammer DDG right after anomaly detection triggered.
const _blockCooldown = Duration(seconds: 60);

// Repeat queries within the TTL are served without a network hit; avoiding
// duplicate requests is the cheapest resilience against bot detection.
const _cacheTtl = Duration(minutes: 10);

// Bounding the cache keeps memory flat while still covering a session's
// worth of repeat queries (32 entries ≈ a long conversation's searches).
const _cacheMaxEntries = 32;

const _ddgBlockedMessage =
    'DuckDuckGo blocked this search (bot detection). Configure a search '
    'provider key for reliable results.';

// Surfaced when BOTH keyless endpoints are blocked; the tail is the user
// facing hint the model repeats verbatim after a fully-blocked search.
const _ddgChainBlockedMessage =
    'DuckDuckGo blocked this search (bot detection) on both the lite and html '
    'endpoints — configure a search provider key in Settings → Tools → Web '
    'Browser for reliable results';

/// Search provider chains (Amendment 1: keyless rings survive device-level
/// bot blocks):
///
/// - [auto] (the settings default): the anonymous keyless MCP ring (exa →
///   parallel) first, then the DDG lite→html chain.
/// - [keylessRing]: only the anonymous ring.
/// - Keyed vendors (tavily/brave/serper) with an API key: that vendor first,
///   the ring as rescue; without a key the ring runs alone.
/// - [ddgLite] (explicit 'ddg'): the DDG chain first, ring as rescue.
enum WebSearchProvider { ddgLite, tavily, brave, serper, keylessRing, auto }

/// One chain link: serves the query or throws [WebSearchBlockedException].
typedef _ChainAttempt =
    Future<List<WebSearchResult>> Function(String query, int limit);

class WebSearchResult {
  final String title;
  final String url;
  final String snippet;
  const WebSearchResult(this.title, this.url, this.snippet);
}

class WebSearchBlockedException implements Exception {
  final String message;
  const WebSearchBlockedException(this.message);
  @override
  String toString() => message;
}

class WebSearchService {
  WebSearchService({
    required this.provider,
    this.apiKey,
    Dio? dio,
    DateTime Function()? clock,
    Duration Function()? jitterFor,
    KeylessMcpRing? ring,
  }) : _clock = clock ?? DateTime.now,
       _jitterFor = jitterFor ?? _defaultJitter {
    this.dio = dio ?? Dio();
    this.ring = ring ?? KeylessMcpRing(dio: this.dio, clock: _clock);
  }

  final WebSearchProvider provider;
  final String? apiKey;
  // Assigned in the constructor body so the ring can share the same Dio
  // instance when both are defaulted.
  late final Dio dio;
  late final KeylessMcpRing ring;
  final DateTime Function() _clock;
  final Duration Function() _jitterFor;

  DateTime? _lastSearchAt;
  DateTime? _blockedUntil;
  int _suppressedSearches = 0;
  final Map<String, _SearchCacheEntry> _cache =
      <String, _SearchCacheEntry>{}; // LinkedHashMap: insertion order = LRU

  static Duration _defaultJitter() =>
      Duration(milliseconds: Random().nextInt(501));

  // Waits out the remaining pacing window instead of erroring, then records
  // the dispatch time so consecutive searches stay spaced.
  Future<void> _pace() async {
    final last = _lastSearchAt;
    if (last != null) {
      final remaining =
          _searchInterval + _jitterFor() - _clock().difference(last);
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    }
    _lastSearchAt = _clock();
  }

  // Normalizes a query so repeats only differ by casing or whitespace.
  String _normalize(String query) =>
      query.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  // Removes expired entries and re-inserts hits, keeping the first map key
  // always the least recently used.
  List<WebSearchResult>? _takeFromCache(String key) {
    final entry = _cache.remove(key);
    if (entry == null) return null;
    if (_clock().difference(entry.storedAt) >= _cacheTtl) return null;
    _cache[key] = entry;
    return entry.results;
  }

  // Stores a successful result and resets any block cooldown: a working
  // chain proves the instance is usable again.
  List<WebSearchResult> _store(String key, List<WebSearchResult> results) {
    _cache[key] = _SearchCacheEntry(results, _clock());
    while (_cache.length > _cacheMaxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _blockedUntil = null;
    _suppressedSearches = 0;
    return results;
  }

  Future<List<WebSearchResult>> search(
    String query, {
    int maxResults = 6,
  }) async {
    final limit = maxResults.clamp(1, 8).toInt();
    final cacheKey = '${provider.name}/${_normalize(query)}/$limit';
    final cached = _takeFromCache(cacheKey);
    if (cached != null) return cached;
    await _pace();
    WebSearchBlockedException? lastError;
    for (final attempt in _resolveChain()) {
      try {
        return _store(cacheKey, await attempt(query, limit));
      } on WebSearchBlockedException catch (error) {
        lastError = error;
      } on DioException catch (error) {
        final status = error.response?.statusCode ?? error.type.name;
        lastError = WebSearchBlockedException('Search failed: $status');
      }
    }
    // Chain end: surface the last link's failure to the model.
    throw lastError ?? WebSearchBlockedException('search failed');
  }

  // Amendment 1 resolution: auto runs ring→ddg; explicit keyed providers run
  // themselves first with the ring as rescue; a keyed provider without a key
  // falls straight to the ring; explicit ddg is rescued by the ring; ring is
  // ring-only.
  List<_ChainAttempt> _resolveChain() {
    switch (provider) {
      case WebSearchProvider.auto:
        return [_ringAttempt, _ddgAttempt];
      case WebSearchProvider.keylessRing:
        return [_ringAttempt];
      case WebSearchProvider.ddgLite:
        return [_ddgAttempt, _ringAttempt];
      case WebSearchProvider.tavily:
        return _keyedChain((query, limit) => _searchTavily(query, limit));
      case WebSearchProvider.brave:
        return _keyedChain((query, limit) => _searchBrave(query, limit));
      case WebSearchProvider.serper:
        return _keyedChain((query, limit) => _searchSerper(query, limit));
    }
  }

  List<_ChainAttempt> _keyedChain(_ChainAttempt request) =>
      apiKey == null ? [_ringAttempt] : [request, _ringAttempt];

  Future<List<WebSearchResult>> _ringAttempt(String query, int limit) =>
      ring.search(query, numResults: limit);

  // The ddg chain keeps its block cooldown: a fully blocked lite→html run
  // arms it so a model retry loop cannot hammer DDG right after anomaly
  // detection triggered. Only this leg is suppressed; the ring stays usable.
  Future<List<WebSearchResult>> _ddgAttempt(String query, int limit) async {
    if (_blockedUntil != null && _clock().isBefore(_blockedUntil!)) {
      _suppressedSearches += 1;
      throw WebSearchBlockedException(
        'search backoff active, try again shortly or '
        'configure a key (suppressed searches: $_suppressedSearches)',
      );
    }
    try {
      return (await _searchDdgWithFallback(query)).take(limit).toList();
    } on DioException catch (error) {
      final status = error.response?.statusCode ?? error.type.name;
      throw WebSearchBlockedException('Search failed: $status');
    }
  }

  // Keyless chain: lite first, then the html endpoint. Two anomalies in a
  // row arm the block cooldown and surface the configure-a-key hint.
  Future<List<WebSearchResult>> _searchDdgWithFallback(String query) async {
    try {
      return await _liteSearch(query);
    } on WebSearchBlockedException {
      // Lite endpoint flagged an anomaly — retry on the html endpoint.
    }
    try {
      return await _htmlSearch(query);
    } on WebSearchBlockedException {
      // fallthrough: both endpoints report anomalies
    } on DioException {
      // fallthrough: html endpoint failed outright (e.g. an error status)
    }
    _blockedUntil = _clock().add(_blockCooldown);
    _suppressedSearches = 0;
    throw WebSearchBlockedException(_ddgChainBlockedMessage);
  }

  Future<List<WebSearchResult>> _liteSearch(String query) async {
    final response = await dio.get<dynamic>(
      'https://lite.duckduckgo.com/lite/',
      queryParameters: {'q': query},
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'User-Agent': webChromeUserAgent,
          'Accept-Language': 'en-US,en;q=0.9',
          'Accept': 'text/html',
        },
      ),
    );
    final body = (response.data as String?) ?? '';
    if (body.contains('anomaly-modal')) {
      throw WebSearchBlockedException(_ddgBlockedMessage);
    }
    final results = _parseLiteResults(body);
    if (results.isEmpty) {
      throw WebSearchBlockedException(_ddgBlockedMessage);
    }
    return results;
  }

  List<WebSearchResult> _parseLiteResults(String html) {
    final document = parser.parse(html);
    final ordered = <_LiteEntry>[];

    void walk(Element element) {
      final isLink =
          element.localName == 'a' && element.classes.contains('result-link');
      final isSnippet =
          (element.localName == 'td' || element.localName == 'span') &&
          element.classes.contains('result-snippet');
      if (isLink) {
        ordered.add(_LiteEntry(element, false));
      } else if (isSnippet) {
        ordered.add(_LiteEntry(element, true));
      }
      element.nodes.whereType<Element>().forEach(walk);
    }

    document.nodes.whereType<Element>().forEach(walk);

    final results = <WebSearchResult>[];
    var pendingLink = false;
    for (final entry in ordered) {
      if (!entry.isSnippet) {
        results.add(
          WebSearchResult(
            _collapse(entry.element.text),
            entry.element.attributes['href'] ?? '',
            '',
          ),
        );
        pendingLink = true;
      } else if (pendingLink) {
        final last = results.last;
        results[results.length - 1] = WebSearchResult(
          last.title,
          last.url,
          _collapse(entry.element.text),
        );
        pendingLink = false;
      }
    }
    return results;
  }

  Future<List<WebSearchResult>> _htmlSearch(String query) async {
    final response = await dio.get<dynamic>(
      'https://html.duckduckgo.com/html/',
      queryParameters: {'q': query},
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'User-Agent': webChromeUserAgent,
          'Accept-Language': 'en-US,en;q=0.9',
          'Accept': 'text/html',
        },
      ),
    );
    final body = (response.data as String?) ?? '';
    if (body.contains('anomaly-modal')) {
      throw WebSearchBlockedException(_ddgBlockedMessage);
    }
    final results = _parseHtmlResults(body);
    if (results.isEmpty) {
      throw WebSearchBlockedException(_ddgBlockedMessage);
    }
    return results;
  }

  // html.duckduckgo.com markup: results sit in div.result; links use
  // a.result__a (href often a /l/?uddg=<encoded> redirect) with snippets
  // in a.result__snippet.
  List<WebSearchResult> _parseHtmlResults(String html) {
    final results = <WebSearchResult>[];
    for (final block in parser.parse(html).querySelectorAll('div.result')) {
      final link = block.querySelector('a.result__a');
      if (link == null) continue;
      var url = link.attributes['href'] ?? '';
      final redirect = Uri.tryParse(url)?.queryParameters['uddg'];
      if (redirect != null) url = redirect;
      results.add(
        WebSearchResult(
          _collapse(link.text),
          url,
          _collapse(block.querySelector('a.result__snippet')?.text ?? ''),
        ),
      );
    }
    return results;
  }

  String _collapse(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

  Future<List<WebSearchResult>> _searchTavily(String query, int limit) async {
    final response = await dio.post<dynamic>(
      'https://api.tavily.com/search',
      data: jsonEncode({
        'api_key': apiKey,
        'query': query,
        'max_results': limit,
      }),
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = _asMap(response.data);
    return [
      for (final item in _asList(data['results']))
        WebSearchResult(
          (item['title'] ?? '').toString(),
          (item['url'] ?? '').toString(),
          (item['content'] ?? '').toString(),
        ),
    ].take(limit).toList();
  }

  Future<List<WebSearchResult>> _searchBrave(String query, int limit) async {
    final response = await dio.get<dynamic>(
      'https://api.search.brave.com/res/v1/web/search',
      queryParameters: {'q': query, 'count': limit},
      options: Options(headers: {'X-Subscription-Token': apiKey}),
    );
    final web = _asMap(_asMap(response.data)['web']);
    return [
      for (final item in _asList(web['results']))
        WebSearchResult(
          (item['title'] ?? '').toString(),
          (item['url'] ?? '').toString(),
          (item['description'] ?? '').toString(),
        ),
    ].take(limit).toList();
  }

  Future<List<WebSearchResult>> _searchSerper(String query, int limit) async {
    final response = await dio.post<dynamic>(
      'https://google.serper.dev/search',
      data: jsonEncode({'q': query, 'num': limit}),
      options: Options(
        headers: {'X-API-KEY': apiKey},
        contentType: Headers.jsonContentType,
      ),
    );
    final data = _asMap(response.data);
    return [
      for (final item in _asList(data['organic']))
        WebSearchResult(
          (item['title'] ?? '').toString(),
          (item['link'] ?? '').toString(),
          (item['snippet'] ?? '').toString(),
        ),
    ].take(limit).toList();
  }

  Map<String, dynamic> _asMap(Object? value) =>
      value is Map<String, dynamic> ? value : const <String, dynamic>{};

  List<Map<String, dynamic>> _asList(Object? value) => value is List
      ? value.whereType<Map<String, dynamic>>().toList()
      : const <Map<String, dynamic>>[];
}

class _LiteEntry {
  const _LiteEntry(this.element, this.isSnippet);
  final Element element;
  final bool isSnippet;
}

class _SearchCacheEntry {
  const _SearchCacheEntry(this.results, this.storedAt);
  final List<WebSearchResult> results;
  final DateTime storedAt;
}
