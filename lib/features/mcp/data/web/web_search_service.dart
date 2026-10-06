import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as parser;

const webChromeUserAgent =
    'Mozilla/5.0 (Linux; Android 10; K) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

const _ddgBlockedMessage =
    'DuckDuckGo blocked this search (bot detection). Configure a search '
    'provider key for reliable results.';

enum WebSearchProvider { ddgLite, tavily, brave, serper }

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
  WebSearchService({required this.provider, this.apiKey, Dio? dio})
    : dio = dio ?? Dio();

  final WebSearchProvider provider;
  final String? apiKey;
  final Dio dio;

  Future<List<WebSearchResult>> search(
    String query, {
    int maxResults = 6,
  }) async {
    final limit = maxResults.clamp(1, 8).toInt();
    try {
      switch (provider) {
        case WebSearchProvider.ddgLite:
          return (await _liteSearch(query)).take(limit).toList();
        case WebSearchProvider.tavily:
          return await _searchTavily(query, limit);
        case WebSearchProvider.brave:
          return await _searchBrave(query, limit);
        case WebSearchProvider.serper:
          return await _searchSerper(query, limit);
      }
    } on DioException catch (error) {
      final status = error.response?.statusCode ?? error.type.name;
      throw WebSearchBlockedException('Search failed: $status');
    }
  }

  void _requireKey() {
    if (apiKey != null) return;
    final displayName = switch (provider) {
      WebSearchProvider.tavily => 'Tavily',
      WebSearchProvider.brave => 'Brave',
      WebSearchProvider.serper => 'Serper',
      WebSearchProvider.ddgLite => 'DuckDuckGo Lite',
    };
    throw WebSearchBlockedException(
      'No API key configured for $displayName — configure one in Settings',
    );
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

  String _collapse(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

  Future<List<WebSearchResult>> _searchTavily(String query, int limit) async {
    _requireKey();
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
    _requireKey();
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
    _requireKey();
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
