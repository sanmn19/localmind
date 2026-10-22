import 'dart:convert';
import 'dart:math';

import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';

import '../models/cloud_sync_models.dart';
import '../storage/cloud_sync_storage.dart';

class S3CloudSyncRepository implements CloudSyncStorage {
  S3CloudSyncRepository({required this.config, required this.credentials})
    : _signer = AWSSigV4Signer(
        credentialsProvider: AWSCredentialsProvider(
          AWSCredentials(
            credentials.accessKeyId,
            credentials.secretAccessKey,
            credentials.sessionToken,
          ),
        ),
      );

  final S3SyncConfig config;
  final CloudSyncCredentials credentials;
  final AWSSigV4Signer _signer;

  final _scopeTimeout = const Duration(seconds: 30);

  @override
  String get stateKey => _key('v1/state.enc');

  @override
  String get backupPrefix => _key('backups');

  @override
  String backupKey(DateTime at) {
    final stamp = at
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return _key('backups/$stamp.enc');
  }

  @override
  Future<List<String>> listBackups() async {
    // S3 ListObjectsV2 under the backups prefix; keys are returned sorted.
    final uri = _objectUri(
      '',
    ).replace(queryParameters: {'list-type': '2', 'prefix': _key('backups/')});
    final response = await _send(
      AWSHttpRequest.get(uri, headers: {AWSHeaders.host: uri.authority}),
    );
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    final keys = RegExp(
      r'<Key>([^<]+)</Key>',
    ).allMatches(body).map((match) => match.group(1)!).toList()..sort();
    return keys;
  }

  @override
  String attachmentKey(String identifier) =>
      _key('v1/attachments/$identifier.enc');

  @override
  bool get requiresLease => false;

  @override
  Future<CloudSyncLease?> readLease() async => null;

  @override
  Future<void> writeLease(CloudSyncLease lease) async {}

  @override
  Future<void> deleteLease() async {}

  String _key(String suffix) {
    final prefix = config.prefix.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    return prefix.isEmpty ? suffix : '$prefix/$suffix';
  }

  Uri _objectUri(String key) {
    final endpoint = config.endpointUri;
    final normalizedKey = key
        .split('/')
        .where((part) => part.isNotEmpty)
        .join('/');
    final basePath = endpoint.path.replaceAll(RegExp(r'/+$'), '');
    if (config.pathStyle) {
      return endpoint.replace(
        path: '$basePath/${config.bucket}/$normalizedKey',
        query: null,
        fragment: null,
      );
    }
    return endpoint.replace(
      host: '${config.bucket}.${endpoint.host}',
      path: '$basePath/$normalizedKey',
      query: null,
      fragment: null,
    );
  }

  Future<AWSHttpResponse> _send(
    AWSHttpRequest request, {
    Set<int> success = const {200},
  }) async {
    try {
      final signed = await _signer.sign(
        request,
        credentialScope: AWSCredentialScope(
          region: config.region,
          service: AWSService.s3,
        ),
        serviceConfiguration: S3ServiceConfiguration(),
      );
      final response = await signed.send().response.timeout(_scopeTimeout);
      final flattened = AWSHttpResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        body: await Future<List<int>>.value(response.bodyBytes),
      );
      await response.close();
      if (!success.contains(flattened.statusCode)) {
        final kind = switch (flattened.statusCode) {
          401 || 403 => CloudSyncFailureKind.credentials,
          409 || 412 => CloudSyncFailureKind.conflict,
          _ => CloudSyncFailureKind.connectivity,
        };
        final body = flattened.bodyBytes.isEmpty
            ? ''
            : utf8.decode(flattened.bodyBytes, allowMalformed: true);
        throw CloudSyncFailure(
          kind,
          _friendlyError(flattened.statusCode, body),
          statusCode: flattened.statusCode,
        );
      }
      return flattened;
    } on CloudSyncFailure {
      rethrow;
    } catch (error) {
      throw CloudSyncFailure(
        CloudSyncFailureKind.connectivity,
        'Could not reach the S3 server: $error',
      );
    }
  }

  String _friendlyError(int status, String body) {
    final code = RegExp(r'<Code>([^<]+)</Code>').firstMatch(body)?.group(1);
    return switch (status) {
      401 || 403 => 'S3 rejected the credentials or bucket permissions.',
      404 => 'The configured S3 bucket or object was not found.',
      409 || 412 => 'The cloud data changed on another device.',
      _ => 'S3 request failed ($status${code == null ? '' : ', $code'}).',
    };
  }

  @override
  Future<CloudSyncRemoteState?> readState() => readObject(stateKey);

  @override
  Future<bool> objectExists(String key) async {
    final uri = _objectUri(key);
    final response = await _send(
      AWSHttpRequest.head(uri, headers: {AWSHeaders.host: uri.authority}),
      success: const {200, 404},
    );
    return response.statusCode == 200;
  }

  @override
  Future<CloudSyncRemoteState?> readObject(String key) async {
    final uri = _objectUri(key);
    final response = await _send(
      AWSHttpRequest.get(uri, headers: {AWSHeaders.host: uri.authority}),
      success: const {200, 404},
    );
    if (response.statusCode == 404) return null;
    return CloudSyncRemoteState(
      bytes: response.bodyBytes,
      etag: response.headers['etag'],
    );
  }

  Future<String?> writeState(
    List<int> bytes, {
    String? expectedEtag,
    bool createOnly = false,
  }) => writeObject(
    stateKey,
    bytes,
    expectedEtag: expectedEtag,
    createOnly: createOnly,
  );

  @override
  Future<String?> writeObject(
    String key,
    List<int> bytes, {
    String? expectedEtag,
    bool createOnly = false,
  }) async {
    final uri = _objectUri(key);
    final headers = <String, String>{
      AWSHeaders.host: uri.authority,
      AWSHeaders.contentType: 'application/octet-stream',
      AWSHeaders.contentLength: bytes.length.toString(),
    };
    if (expectedEtag != null) headers['if-match'] = expectedEtag;
    if (createOnly) headers['if-none-match'] = '*';
    final response = await _send(
      AWSHttpRequest.put(uri, body: bytes, headers: headers),
    );
    return response.headers['etag'];
  }

  @override
  Future<void> deleteObject(String key) async {
    final uri = _objectUri(key);
    await _send(
      AWSHttpRequest.delete(uri, headers: {AWSHeaders.host: uri.authority}),
      success: const {200, 204, 404},
    );
  }

  @override
  Future<void> testConnection() async {
    final validation = config.validate();
    if (validation != null) {
      throw CloudSyncFailure(CloudSyncFailureKind.validation, validation);
    }
    if (!credentials.isValid) {
      throw const CloudSyncFailure(
        CloudSyncFailureKind.validation,
        'Access key and secret key are required.',
      );
    }
    final suffix = Random.secure().nextInt(1 << 32).toRadixString(16);
    final key = _key('v1/.connection-test-$suffix');
    try {
      final firstEtag = await writeObject(key, const [1], createOnly: true);
      final read = await readObject(key);
      if (read == null || read.bytes.length != 1 || read.bytes.single != 1) {
        throw const CloudSyncFailure(
          CloudSyncFailureKind.incompatibleServer,
          'The S3 server did not return the test object correctly.',
        );
      }
      if (firstEtag == null) {
        throw const CloudSyncFailure(
          CloudSyncFailureKind.incompatibleServer,
          'The S3 server does not expose ETags required for safe sync.',
        );
      }
      final secondEtag = await writeObject(key, const [
        2,
      ], expectedEtag: firstEtag);
      if (secondEtag == null) {
        throw const CloudSyncFailure(
          CloudSyncFailureKind.incompatibleServer,
          'The S3 server stopped returning ETags during the connection test.',
        );
      }
      try {
        await writeObject(key, const [3], expectedEtag: firstEtag);
      } on CloudSyncFailure catch (error) {
        if (error.kind == CloudSyncFailureKind.conflict) return;
        rethrow;
      }
      throw const CloudSyncFailure(
        CloudSyncFailureKind.incompatibleServer,
        'The S3 server does not enforce conditional writes required for safe sync.',
      );
    } finally {
      try {
        await deleteObject(key);
      } catch (_) {}
    }
  }
}
