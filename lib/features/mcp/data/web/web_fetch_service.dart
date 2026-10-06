import 'dart:io';

import 'package:dio/dio.dart';

import 'web_search_service.dart';
import 'html_reader.dart';

/// Fetches a web page over http(s), converts it to readable text and guards
/// against requests to local/private network addresses (SSRF defence).
class WebFetchService {
  WebFetchService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              followRedirects: true,
              maxRedirects: 5,
              validateStatus: (code) => code != null && code < 400,
            ),
          );

  final Dio _dio;

  Future<String> fetch(String url, {int maxChars = 6000}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return 'ERROR: only http(s) URLs are supported';
    }
    if (isBlockedFetchTarget(uri)) {
      return 'ERROR: refused to fetch a local/private address';
    }
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
      final header = title == null ? '' : '# $title\n\n';
      return '$header$text\n\n(source: $url)';
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      return 'ERROR: fetch failed${code == null ? '' : ' (HTTP $code)'}';
    }
  }
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
