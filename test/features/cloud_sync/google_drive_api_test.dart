import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/cloud_sync/data/models/cloud_sync_models.dart';
import 'package:localmind/features/cloud_sync/services/google_drive_api.dart';

class _CapturedRequest {
  const _CapturedRequest(this.options, this.body);

  final RequestOptions options;
  final List<int> body;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responder);

  final Future<ResponseBody> Function(RequestOptions options) responder;
  final requests = <_CapturedRequest>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        body.addAll(chunk);
      }
    }
    requests.add(_CapturedRequest(options, body));
    return responder(options);
  }

  @override
  void close({bool force = false}) {}
}

Future<String?> _token({bool interactive = false}) async => 'token-1';

ResponseBody _json(String body, [int status = 200]) => ResponseBody.fromString(
  body,
  status,
  headers: {
    'content-type': ['application/json'],
  },
);

(Dio, _FakeAdapter) _drive(
  Future<ResponseBody> Function(RequestOptions options) responder,
) {
  final adapter = _FakeAdapter(responder);
  final dio = Dio()..httpClientAdapter = adapter;
  return (dio, adapter);
}

void main() {
  test('upload sends the metadata part as JSON', () async {
    final (dio, adapter) = _drive((_) async => _json('{"id":"file-1"}'));
    final api = GoogleDriveApi(dio, _token);

    await api.upload(
      name: 'state.enc',
      parentId: 'folder-1',
      bytes: const [1, 2, 3],
    );

    final request = adapter.requests.single;
    expect(
      request.options.path,
      'https://www.googleapis.com/upload/drive/v3/files',
    );
    expect(request.options.method, 'POST');
    expect(request.options.queryParameters['uploadType'], 'multipart');
    final body = String.fromCharCodes(request.body);
    expect(body.toLowerCase(), contains('application/json'));
    expect(body, contains('"name":"state.enc"'));
    expect(body, contains('"parents":["folder-1"]'));
  });

  test('an expired authorization is a credentials failure', () async {
    for (final status in [401, 403]) {
      final (dio, _) = _drive((_) async => _json('{"error":{}}', status));
      final api = GoogleDriveApi(dio, _token);

      await expectLater(
        api.listFiles('trashed = false'),
        throwsA(
          isA<CloudSyncFailure>().having(
            (error) => error.kind,
            'kind',
            CloudSyncFailureKind.credentials,
          ),
        ),
      );
    }
  });

  test('a missing Drive folder or file is a corrupted-data failure', () async {
    final (dio, _) = _drive((_) async => _json('{"error":{}}', 404));
    final api = GoogleDriveApi(dio, _token);

    await expectLater(
      api.download('file-1'),
      throwsA(
        isA<CloudSyncFailure>().having(
          (error) => error.kind,
          'kind',
          CloudSyncFailureKind.corruptedData,
        ),
      ),
    );
  });

  test('a stale Drive write is a conflict failure', () async {
    for (final status in [409, 412]) {
      final (dio, _) = _drive((_) async => _json('{"error":{}}', status));
      final api = GoogleDriveApi(dio, _token);

      await expectLater(
        api.upload(name: 'state.enc', parentId: 'folder-1', bytes: const [1]),
        throwsA(
          isA<CloudSyncFailure>().having(
            (error) => error.kind,
            'kind',
            CloudSyncFailureKind.conflict,
          ),
        ),
      );
    }
  });

  test('other Drive failures surface the API message', () async {
    final (dio, _) = _drive(
      (_) async => _json('{"error":{"message":"Bad metadata"}}', 400),
    );
    final api = GoogleDriveApi(dio, _token);

    await expectLater(
      api.createFolder('Localmind'),
      throwsA(
        isA<CloudSyncFailure>()
            .having((error) => error.kind, 'kind', CloudSyncFailureKind.unknown)
            .having(
              (error) => error.message,
              'message',
              contains('Bad metadata'),
            ),
      ),
    );
  });

  test('an unreachable Drive is a connectivity failure', () async {
    final (dio, _) = _drive(
      (options) async => throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      ),
    );
    final api = GoogleDriveApi(dio, _token);

    await expectLater(
      api.listFiles('trashed = false'),
      throwsA(
        isA<CloudSyncFailure>().having(
          (error) => error.kind,
          'kind',
          CloudSyncFailureKind.connectivity,
        ),
      ),
    );
  });

  test('a missing token fails as credentials without a request', () async {
    final (dio, adapter) = _drive((_) async => _json('{}'));
    final api = GoogleDriveApi(dio, ({bool interactive = false}) async => null);

    await expectLater(
      api.listFiles('trashed = false'),
      throwsA(
        isA<CloudSyncFailure>().having(
          (error) => error.kind,
          'kind',
          CloudSyncFailureKind.credentials,
        ),
      ),
    );
    expect(adapter.requests, isEmpty);
  });
}
