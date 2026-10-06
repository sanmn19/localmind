import 'dart:typed_data';
import 'package:dio/dio.dart';

class StubResponse {
  const StubResponse(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.routes, {this.onRequest});
  final Map<String, StubResponse> routes;
  final void Function(RequestOptions options)? onRequest;

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
    final route = routes[options.uri.toString()];
    if (route == null) return ResponseBody.fromString('', 404);
    return ResponseBody.fromString(
      route.body,
      route.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}
