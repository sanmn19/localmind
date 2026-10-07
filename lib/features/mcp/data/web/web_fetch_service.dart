import 'dart:io';

import 'package:dio/dio.dart';

import 'keyless_mcp_ring.dart';
import 'web_search_service.dart';
import 'html_reader.dart';

/// Fetches a web page over http(s), converts it to readable text and guards
/// against requests to local/private network addresses (SSRF defence).
class WebFetchService {
  WebFetchService({Dio? dio, this.fallbackRing}) : _dio = dio ?? _defaultDio();

  final Dio _dio;

  /// Ring used to rescue blocked fetches through exa's server-rendered
  /// `web_fetch_exa` (Amendment 1). When null, a default ring sharing the
  /// primary [_dio] is used; the registration provider injects the same ring
  /// instance the search service holds so sessions stay warm.
  final KeylessMcpRing? fallbackRing;

  late final KeylessMcpRing ring = fallbackRing ?? KeylessMcpRing(dio: _dio);

  Future<String> fetch(String url, {int maxChars = 6000}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return 'ERROR: only http(s) URLs are supported';
    }
    if (isBlockedFetchTarget(uri)) {
      return 'ERROR: refused to fetch a local/private address';
    }
    String error;
    try {
      final response = await _dio.getUri<String>(
        uri,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'User-Agent': webChromeUserAgent,
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,'
                'image/avif,image/webp,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9',
          },
        ),
      );
      final html = response.data ?? '';
      final title = extractHtmlTitle(html);
      final text = htmlToReadableText(html, maxChars: maxChars);
      if (text.isNotEmpty) {
        final header = title == null ? '' : '# $title\n\n';
        return '$header$text\n\n(source: $url)';
      }
      // 2xx but nothing readable — JS-only shell or a bot-garbage page.
      error = 'ERROR: fetch failed (empty body)';
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      error = 'ERROR: fetch failed${code == null ? '' : ' (HTTP $code)'}';
    }
    return _rescueViaExa(url, maxChars, error);
  }

  // Exa rescue for bot-detected direct fetches. On overall success the page
  // is returned with an explicit mirror source note; on any ring failure the
  // direct error carries the mirror hint as one model-readable line.
  Future<String> _rescueViaExa(
    String url,
    int maxChars,
    String directError,
  ) async {
    try {
      final text = await ring.fetchViaExa([url], maxCharacters: maxChars);
      if (text.trim().isEmpty) {
        return '$directError; exa mirror unavailable: empty response';
      }
      return '$text\n\n(source: $url · via exa mirror)';
    } on WebSearchBlockedException catch (failure) {
      return '$directError; exa mirror unavailable: ${failure.message}';
    } catch (failure) {
      return '$directError; exa mirror unavailable: $failure';
    }
  }

  static Dio _defaultDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: true,
      maxRedirects: 5,
      validateStatus: (code) => code != null && code < 400,
    ),
  );
}

/// True when [uri] targets localhost, a hostless URL, or a literal IP inside
/// loopback or the private ranges 10.0.0.0/8, 172.16.0.0/12 (covers
/// 172.16.x.x-172.31.x.x), 192.168.0.0/16, 169.254.0.0/16, and 100.64.0.0/10
/// (carrier NAT + tailscale, ends at 100.127.255.255).
bool isBlockedFetchTarget(Uri uri) {
  final host = uri.host.toLowerCase();
  if (host.isEmpty || host == 'localhost') return true;
  final address = InternetAddress.tryParse(host);
  if (address == null) return false;
  if (address.isLoopback) return true;
  const blockedV4Ranges = [
    ([10, 0, 0, 0], 8),
    ([172, 16, 0, 0], 12),
    ([192, 168, 0, 0], 16),
    ([169, 254, 0, 0], 16),
    ([100, 64, 0, 0], 10),
  ];
  final bytes = address.rawAddress;
  if (bytes.length != 4) return false; // No IPv6 private ranges in scope.
  for (final (network, prefixBits) in blockedV4Ranges) {
    if (_inCidr4(bytes, network, prefixBits)) return true;
  }
  return false;
}

/// True when the first [prefixBits] bits of [address] match [network].
bool _inCidr4(List<int> address, List<int> network, int prefixBits) {
  for (var i = 0; i < prefixBits; i++) {
    final byte = i >> 3;
    final bit = 7 - (i & 7);
    if (((address[byte] ^ network[byte]) >> bit) & 1 == 1) return false;
  }
  return true;
}
