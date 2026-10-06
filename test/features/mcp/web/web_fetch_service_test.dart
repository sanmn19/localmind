import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/mcp/data/web/web_fetch_service.dart';
import 'package:localmind/features/mcp/data/web/web_search_service.dart';
import 'stub_dio_adapter.dart';

void main() {
  test('private and local targets are rejected before any network call', () {
    expect(isBlockedFetchTarget(Uri.parse('http://localhost/x')), isTrue);
    expect(isBlockedFetchTarget(Uri.parse('http://LOCALHOST/x')), isTrue);
    expect(isBlockedFetchTarget(Uri.parse('http://127.0.0.1/x')), isTrue);
    expect(isBlockedFetchTarget(Uri.parse('http://10.0.0.3/x')), isTrue);
    expect(isBlockedFetchTarget(Uri.parse('http://10.5.0.1/x')), isTrue);
    expect(isBlockedFetchTarget(Uri.parse('http://172.16.0.9/x')), isTrue);
    expect(isBlockedFetchTarget(Uri.parse('http://172.31.5.5/x')), isTrue);
    expect(isBlockedFetchTarget(Uri.parse('http://172.31.255.255/x')), isTrue);
    expect(isBlockedFetchTarget(Uri.parse('http://192.168.1.5/x')), isTrue);
    expect(isBlockedFetchTarget(Uri.parse('http://169.254.169.254/m')), isTrue);
    expect(
      isBlockedFetchTarget(Uri.parse('http://100.64.0.7/tailnet')),
      isTrue,
    );
    expect(isBlockedFetchTarget(Uri.parse('http://100.100.0.1/x')), isTrue);
    expect(isBlockedFetchTarget(Uri.parse('http://example.com/x')), isFalse);
    expect(isBlockedFetchTarget(Uri.parse('http://8.8.8.8/x')), isFalse);
    expect(isBlockedFetchTarget(Uri.parse('http://172.32.0.1/x')), isFalse);
    expect(isBlockedFetchTarget(Uri.parse('http://100.128.0.1/x')), isFalse);
  });

  test(
    'fetch rejects non-http(s) schemes and empty hosts without network',
    () async {
      var requests = 0;
      final dio = Dio()
        ..httpClientAdapter = StubAdapter(
          {},
          onRequest: (_) {
            requests++;
          },
        );
      final service = WebFetchService(dio: dio);
      expect(
        await service.fetch('ftp://example.com/file'),
        startsWith('ERROR: '),
      );
      expect(await service.fetch('http:///no-host'), startsWith('ERROR: '));
      expect(requests, 0);
    },
  );

  test('converts html to title + readable text with source footer', () async {
    var sawUa = false;
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(
        {
          'https://example.com/page': const StubResponse(
            200,
            '<html><head><title>Doc</title></head><body><h1>H</h1>'
            '<p>Body text</p></body></html>',
          ),
        },
        onRequest: (options) {
          sawUa = options.headers['User-Agent'] == webChromeUserAgent;
        },
      );
    final service = WebFetchService(dio: dio);
    final out = await service.fetch('https://example.com/page');
    expect(sawUa, isTrue);
    expect(out, contains('# Doc'));
    expect(out, contains('Body text'));
    expect(out, contains('source: https://example.com/page'));
  });

  test('truncates long pages to maxChars', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter({
        'https://example.com/long': StubResponse(
          200,
          '<html><head><title>Long</title></head><body><p>'
          '${'word ' * 100}</p></body></html>',
        ),
      });
    final service = WebFetchService(dio: dio);
    final out = await service.fetch('https://example.com/long', maxChars: 50);
    expect(out, contains('[truncated after 50 characters]'));
    expect(out, contains('source: https://example.com/long'));
  });

  test(
    'network failure returns ERROR-prefixed text (model-readable)',
    () async {
      final dio = Dio()..httpClientAdapter = StubAdapter({}); // 404 for all
      final service = WebFetchService(dio: dio);
      final out = await service.fetch('https://example.com/x');
      expect(out.startsWith('ERROR: '), isTrue);
      expect(out, contains('404'));
    },
  );
}
