import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/cloud_sync/data/repositories/google_drive_cloud_sync_repository.dart';
import 'package:localmind/features/cloud_sync/services/google_drive_api.dart';

/// An in-memory Drive: the repository's queries are answered from records the
/// same way the real API filters them.
class _FakeDriveApi extends GoogleDriveApi {
  _FakeDriveApi() : super(Dio(), ({bool interactive = false}) async => 't');

  final records = <Map<String, dynamic>>[];
  int createFolderCalls = 0;
  int uploadCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> listFiles(String query) async {
    final name = RegExp(r"name = '([^']+)'").firstMatch(query)?.group(1);
    final parent = RegExp(r"'([^']+)' in parents").firstMatch(query)?.group(1);
    final foldersOnly = query.contains(
      "mimeType = 'application/vnd.google-apps.folder'",
    );
    return records.where((record) {
      if (foldersOnly &&
          record['mimeType'] != 'application/vnd.google-apps.folder') {
        return false;
      }
      if (name != null && record['name'] != name) return false;
      final parents = record['parents'] as List? ?? const [];
      if (parent != null && !parents.contains(parent)) return false;
      return true;
    }).toList();
  }

  @override
  Future<Map<String, dynamic>> createFolder(
    String name, {
    String? parentId,
  }) async {
    createFolderCalls++;
    final folder = <String, dynamic>{
      'id': 'folder-${records.length + 1}',
      'name': name,
      'mimeType': 'application/vnd.google-apps.folder',
      'parents': [?parentId],
    };
    records.add(folder);
    return folder;
  }

  @override
  Future<Map<String, dynamic>> upload({
    String? fileId,
    required String name,
    required String parentId,
    required List<int> bytes,
  }) async {
    uploadCalls++;
    if (fileId != null) {
      final record = records.firstWhere((item) => item['id'] == fileId);
      record['bytes'] = bytes;
      return record;
    }
    final file = <String, dynamic>{
      'id': 'file-${records.length + 1}',
      'name': name,
      'parents': [parentId],
      'md5Checksum': 'md5-$uploadCalls',
      'bytes': bytes,
    };
    records.add(file);
    return file;
  }

  @override
  Future<List<int>> download(String fileId) async =>
      records.firstWhere((item) => item['id'] == fileId)['bytes'] as List<int>;

  @override
  Future<void> delete(String fileId) async =>
      records.removeWhere((item) => item['id'] == fileId);
}

void main() {
  test('readState returns null when the state object is missing', () async {
    final api = _FakeDriveApi();
    final repository = GoogleDriveCloudSyncRepository(api: api);

    expect(await repository.readState(), isNull);
  });

  test('readState returns the stored bytes and version', () async {
    final api = _FakeDriveApi();
    final repository = GoogleDriveCloudSyncRepository(api: api);
    await repository.writeObject('v1/state.enc', const [1, 2, 3]);

    final state = await repository.readState();

    expect(state?.bytes, [1, 2, 3]);
    expect(state?.etag, isNotEmpty);
  });

  test('the folder tree is created once and reused', () async {
    final api = _FakeDriveApi();
    final repository = GoogleDriveCloudSyncRepository(api: api);

    await repository.readState();
    await repository.readState();

    // Localmind + v1, each created once even across both reads.
    expect(api.createFolderCalls, 2);
  });

  test('a missing file reads as null instead of failing', () async {
    final api = _FakeDriveApi();
    final repository = GoogleDriveCloudSyncRepository(api: api);

    expect(await repository.readObject('v1/attachments/missing.enc'), isNull);
  });
}
