import 'dart:convert';

import 'package:dio/dio.dart';

import '../data/models/cloud_sync_models.dart';

/// Minimal Drive v3 REST client (JSON metadata + media upload/download).
///
/// Every transport failure is surfaced as a [CloudSyncFailure] so the controller
/// treats Drive like S3: expired authorization, a missing backup folder, a stale
/// write and an unreachable server each map to their own kind.
class GoogleDriveApi {
  GoogleDriveApi(this._dio, this._accessToken);

  static const _api = 'https://www.googleapis.com/drive/v3';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3';

  final Dio _dio;
  final Future<String?> Function({bool interactive}) _accessToken;

  Future<List<Map<String, dynamic>>> listFiles(String query) =>
      _guard(() async {
        final token = await _token();
        final response = await _dio.get<Map<String, dynamic>>(
          '$_api/files',
          queryParameters: {
            'q': query,
            'fields': 'files(id,name,mimeType,md5Checksum,modifiedTime)',
            'pageSize': 1000,
            'spaces': 'drive',
          },
          options: _options(token),
        );
        _ensureSuccess(response);
        final files = response.data?['files'];
        return files is List
            ? files.whereType<Map<String, dynamic>>().toList()
            : [];
      });

  Future<Map<String, dynamic>> createFolder(String name, {String? parentId}) =>
      _guard(() async {
        final token = await _token();
        final response = await _dio.post<Map<String, dynamic>>(
          '$_api/files',
          data: {
            'name': name,
            'mimeType': 'application/vnd.google-apps.folder',
            if (parentId != null) 'parents': [parentId],
          },
          queryParameters: {'fields': 'id,name,md5Checksum,modifiedTime'},
          options: _options(token),
        );
        _ensureSuccess(response);
        return response.data ?? const {};
      });

  /// Creates ([fileId] null) or replaces the content of an existing file.
  Future<Map<String, dynamic>> upload({
    String? fileId,
    required String name,
    required String parentId,
    required List<int> bytes,
  }) => _guard(() async {
    final token = await _token();
    final Response<Map<String, dynamic>> response;
    if (fileId == null) {
      final form = FormData();
      // Drive requires the metadata part to be JSON; Dio's form fields are
      // text/plain, which Drive rejects with a 400.
      form.files.add(
        MapEntry(
          'metadata',
          MultipartFile.fromString(
            jsonEncode({
              'name': name,
              'parents': [parentId],
            }),
            contentType: DioMediaType('application', 'json'),
          ),
        ),
      );
      form.files.add(
        MapEntry('file', MultipartFile.fromBytes(bytes, filename: name)),
      );
      response = await _dio.post<Map<String, dynamic>>(
        '$_upload/files',
        data: form,
        queryParameters: {
          'uploadType': 'multipart',
          'fields': 'id,name,md5Checksum,modifiedTime',
        },
        options: _options(token),
      );
    } else {
      response = await _dio.patch<Map<String, dynamic>>(
        '$_upload/files/$fileId',
        data: bytes,
        queryParameters: {
          'uploadType': 'media',
          'fields': 'id,name,md5Checksum,modifiedTime',
        },
        options: _options(token, contentType: 'application/octet-stream'),
      );
    }
    _ensureSuccess(response);
    return response.data ?? const {};
  });

  Future<List<int>> download(String fileId) => _guard(() async {
    final token = await _token();
    final response = await _dio.get<List<int>>(
      '$_api/files/$fileId',
      queryParameters: {'alt': 'media'},
      options: _options(token, responseType: ResponseType.bytes),
    );
    _ensureSuccess(response);
    return response.data ?? const [];
  });

  Future<void> delete(String fileId) => _guard(() async {
    final token = await _token();
    final response = await _dio.delete<void>(
      '$_api/files/$fileId',
      options: _options(token),
    );
    if (response.statusCode == 404) return;
    _ensureSuccess(response);
  });

  Future<T> _guard<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on CloudSyncFailure {
      rethrow;
    } on DioException catch (error) {
      throw _failureFor(error);
    }
  }

  CloudSyncFailure _failureFor(DioException error) {
    final status = error.response?.statusCode;
    if (status == null) {
      final unreachable =
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.connectionError;
      if (unreachable) {
        return const CloudSyncFailure(
          CloudSyncFailureKind.connectivity,
          'Could not reach Google Drive.',
        );
      }
      return CloudSyncFailure(
        CloudSyncFailureKind.unknown,
        error.message ?? 'Drive request failed.',
      );
    }
    return _failureForStatus(status, error.response?.data);
  }

  CloudSyncFailure _failureForStatus(int status, dynamic data) {
    if (status == 401 || status == 403) {
      return CloudSyncFailure(
        CloudSyncFailureKind.credentials,
        'Google Drive authorization expired. Connect the account again.',
        statusCode: status,
      );
    }
    if (status == 404) {
      return CloudSyncFailure(
        CloudSyncFailureKind.corruptedData,
        'The Drive backup folder or file was not found.',
        statusCode: status,
      );
    }
    if (status == 409 || status == 412) {
      return CloudSyncFailure(
        CloudSyncFailureKind.conflict,
        'Another device changed the Drive backup. Retry the sync.',
        statusCode: status,
      );
    }
    final apiMessage = data is Map && data['error'] is Map
        ? (data['error'] as Map)['message']?.toString()
        : null;
    return CloudSyncFailure(
      CloudSyncFailureKind.unknown,
      'Drive request failed ($status${apiMessage == null ? '' : ': $apiMessage'}).',
      statusCode: status,
    );
  }

  Future<String> _token() async {
    final token = await _accessToken(interactive: false);
    if (token == null || token.isEmpty) {
      throw const CloudSyncFailure(
        CloudSyncFailureKind.credentials,
        'Google Drive is not authorized. Connect the account again.',
      );
    }
    return token;
  }

  Options _options(
    String token, {
    String? contentType,
    ResponseType? responseType,
  }) => Options(
    headers: {'Authorization': 'Bearer $token', 'Content-Type': ?contentType},
    responseType: responseType,
    receiveTimeout: const Duration(seconds: 60),
    sendTimeout: const Duration(minutes: 2),
    validateStatus: (status) => status != null && status < 500,
  );

  void _ensureSuccess(Response response) {
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) return;
    throw _failureForStatus(status, response.data);
  }
}
