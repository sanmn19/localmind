import 'dart:typed_data';
import 'package:dio/dio.dart';

class StubResponse {
  const StubResponse(this.statusCode, this.body, {this.headers = const {}});
  final int statusCode;
  final String body;

  /// Extra response headers (header name -> values), e.g. Mcp-Session-Id.
  final Map<String, List<String>> headers;
}

class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.routes, {this.onRequest, this.sequences = const {}});

  /// Static single-response routes keyed by full request URL.
  final Map<String, StubResponse> routes;

  /// Sequenced routes: each request to the URL consumes the next response;
  /// once the sequence is exhausted the last response repeats. Needed when a
  /// single endpoint must answer differently per request (e.g. handshake ->
  /// 404 -> re-handshake -> success).
  final Map<String, List<StubResponse>> sequences;

  final void Function(RequestOptions options)? onRequest;

  final Map<String, int> _sequenceCursors = {};

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    onRequest?.call(options);
    // Wait for request body of POSTs to be consumed before responding,
    // to keep dio's internal queue happy.
    if (options.method == 'POST') {
      await requestStream?.fold<BytesBuilder>(
        BytesBuilder(),
        (b, d) => b..add(d),
      );
    }
    final url = options.uri.toString();
    final StubResponse? route;
    final queue = sequences[url];
    if (queue != null && queue.isNotEmpty) {
      var index = _sequenceCursors[url] ?? 0;
      if (index >= queue.length) index = queue.length - 1;
      _sequenceCursors[url] = index + 1;
      route = queue[index];
    } else {
      route = routes[url];
    }
    if (route == null) return ResponseBody.fromString('', 404);
    return ResponseBody.fromString(
      route.body,
      route.statusCode,
      headers: {
        Headers.contentTypeHeader: [
          route.headers[Headers.contentTypeHeader]?.first ??
              Headers.jsonContentType,
        ],
        ...route.headers,
      },
    );
  }
}
