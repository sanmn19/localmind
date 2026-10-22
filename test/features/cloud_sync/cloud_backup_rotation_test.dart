import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/cloud_sync/data/models/cloud_sync_models.dart';
import 'package:localmind/features/cloud_sync/data/storage/cloud_sync_storage.dart';
import 'package:localmind/features/cloud_sync/services/cloud_backup_rotation_service.dart';

class _FakeStorage implements CloudSyncStorage {
  final Map<String, List<int>> objects = {};
  bool failCloudWrite = false;

  @override
  String get stateKey => 'v1/state.enc';

  @override
  String attachmentKey(String identifier) => 'v1/attachments/$identifier.enc';

  @override
  String get backupPrefix => 'backups';

  @override
  String backupKey(DateTime at) =>
      'backups/${at.toUtc().toIso8601String()}';

  @override
  Future<void> testConnection() async {}

  @override
  Future<CloudSyncRemoteState?> readState() async => null;

  @override
  Future<CloudSyncRemoteState?> readObject(String key) async {
    final bytes = objects[key];
    return bytes == null ? null : CloudSyncRemoteState(bytes: bytes, etag: 'v');
  }

  @override
  Future<String?> writeObject(
    String key,
    List<int> bytes, {
    String? expectedEtag,
    bool createOnly = false,
  }) async {
    if (failCloudWrite) return null;
    objects[key] = bytes;
    return 'v';
  }

  @override
  Future<void> deleteObject(String key) async => objects.remove(key);

  @override
  Future<bool> objectExists(String key) async => objects.containsKey(key);

  @override
  Future<List<String>> listBackups() async =>
      objects.keys.where((key) => key.startsWith('backups/')).toList()
        ..sort();
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rotation-test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('writes the local and cloud copy before the new state', () async {
    final storage = _FakeStorage();
    final result = await CloudBackupRotationService(localRoot: root)
        .rotateBeforeWrite(
          storage: storage,
          existingState: const [1, 2, 3],
          now: DateTime.utc(2026, 10, 19, 12),
        );

    expect(result.localPath, isNotNull);
    expect(File(result.localPath!).readAsBytesSync(), [1, 2, 3]);
    expect(result.cloudKey, isNotNull);
    expect(storage.objects[result.cloudKey!], [1, 2, 3]);
  });

  test('a missing cloud copy aborts the rotation', () async {
    final storage = _FakeStorage()..failCloudWrite = true;

    expect(
      () => CloudBackupRotationService(localRoot: root).rotateBeforeWrite(
        storage: storage,
        existingState: const [1],
        now: DateTime.utc(2026, 10, 19, 12),
      ),
      throwsA(isA<CloudSyncFailure>()),
    );
    expect(storage.objects, isEmpty);
  });

  test('keeps the 3 newest local and cloud copies', () async {
    final storage = _FakeStorage();
    final service = CloudBackupRotationService(localRoot: root);
    for (var hour = 0; hour < 5; hour++) {
      await service.rotateBeforeWrite(
        storage: storage,
        existingState: [hour],
        now: DateTime.utc(2026, 10, 19, hour),
      );
    }

    final localFiles = (root
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.enc'))
        .toList())
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(localFiles, hasLength(3));
    expect(storage.objects.keys, hasLength(3));
    expect(
      localFiles.map((file) => file.path.split('/').last).toList(),
      ['2026-10-19T02-00-00-000Z.enc', '2026-10-19T03-00-00-000Z.enc', '2026-10-19T04-00-00-000Z.enc'],
    );
  });
}
