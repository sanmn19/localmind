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

/// True when [uri] targets localhost, a literal loopback/private/labelled IP
/// (10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10) or a hostless URL.
bool isBlockedFetchTarget(Uri uri) {
  final host = uri.host.toLowerCase();
  if (host.isEmpty || host == 'localhost') return true;
  final address = InternetAddress.tryParse(host);
  if (address == null) return false;
  if (address.isLoopback) return true;
  final blockedPrefixes = [
    [10, 0],
    for (var second = 16; second <= 31; second++) [172, second],
    [192, 168],
    [169, 254],
    [100, 64],
  ];
  for (final range in blockedPrefixes) {
    if (address.rawAddress[0] == range[0] &&
        address.rawAddress[1] == range[1]) {
      return true;
    }
  }
  return false;
}
