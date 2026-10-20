import 'dart:convert';

import '../../data/models/cloud_sync_models.dart';
import '../../data/storage/cloud_sync_storage.dart';
import '../../services/google_drive_api.dart';

/// Google Drive backend: an app-created `Localmind` folder holds the encrypted
/// state, attachments and rotated backups. Drive has no usable conditional write
/// for media content, so a device lease replaces `If-Match`.
class GoogleDriveCloudSyncRepository implements CloudSyncStorage {
  GoogleDriveCloudSyncRepository({required this.api});

  final GoogleDriveApi api;

  static const rootFolderName = 'Localmind';
  static const leaseKey = 'v1/lease.json';
  static const leaseTtl = Duration(minutes: 10);

  final _folderIds = <String, String>{};

  @override
  String get stateKey => 'v1/state.enc';

  @override
  String attachmentKey(String identifier) => 'v1/attachments/$identifier.enc';

  @override
  String get backupPrefix => 'backups';

  @override
  String backupKey(DateTime at) {
    final stamp = at
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return 'backups/$stamp.enc';
  }

  @override
  Future<void> testConnection() async {
    await api.listFiles('trashed = false');
  }

  @override
  Future<CloudSyncRemoteState?> readState() => readObject(stateKey);

  @override
  Future<CloudSyncRemoteState?> readObject(String key) async {
    final file = await _findFile(key);
    if (file == null) return null;
    final bytes = await api.download(file['id'] as String);
    return CloudSyncRemoteState(bytes: bytes, etag: _versionOf(file));
  }

  @override
  Future<String?> writeObject(
    String key,
    List<int> bytes, {
    String? expectedEtag,
    bool createOnly = false,
  }) async {
    final parts = key.split('/');
    final name = parts.last;
    final parentId = await _folderId(parts.sublist(0, parts.length - 1));
    final existing = await _findFile(key);
    final result = await api.upload(
      fileId: existing?['id'] as String?,
      name: name,
      parentId: parentId,
      bytes: bytes,
    );
    return _versionOf(result);
  }

  @override
  Future<void> deleteObject(String key) async {
    final file = await _findFile(key);
    if (file == null) return;
    await api.delete(file['id'] as String);
  }

  @override
  Future<bool> objectExists(String key) async => await _findFile(key) != null;

  @override
  Future<List<String>> listBackups() async {
    final parentId = await _folderId([backupPrefix]);
    final files = await api.listFiles(
      "'$parentId' in parents and trashed = false",
    );
    return files
        .map((file) => '$backupPrefix/${file['name']}')
        .toList()
      ..sort();
  }

  Future<CloudSyncLease?> readLease() async {
    final file = await _findFile(leaseKey);
    if (file == null) return null;
    try {
      final bytes = await api.download(file['id'] as String);
      final decoded = jsonDecode(utf8.decode(bytes)) as Map;
      return CloudSyncLease.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> writeLease(CloudSyncLease lease) async {
    final bytes = const Utf8Encoder().convert(lease.encode());
    await writeObject(leaseKey, bytes);
  }

  /// A foreign device with a recent heartbeat owns the sync right now.
  bool isLeaseHeldByOther(CloudSyncLease? lease, String deviceId, DateTime now) {
    if (lease == null) return false;
    if (lease.deviceId == deviceId) return false;
    return now.difference(lease.heartbeatAt) < leaseTtl;
  }

  Future<Map<String, dynamic>?> _findFile(String key) async {
    final parts = key.split('/');
    final name = parts.last;
    final parentId = await _folderId(parts.sublist(0, parts.length - 1));
    final files = await api.listFiles(
      "name = '$name' and '$parentId' in parents and trashed = false",
    );
    return files.firstOrNull;
  }

  Future<String> _folderId(List<String> path) async {
    var parentId = await _rootId();
    final built = <String>[];
    for (final part in path) {
      built.add(part);
      final key = built.join('/');
      final cached = _folderIds[key];
      if (cached != null) {
        parentId = cached;
        continue;
      }
      final files = await api.listFiles(
        "name = '$part' and mimeType = 'application/vnd.google-apps.folder' "
        "and '$parentId' in parents and trashed = false",
      );
      final id = files.isEmpty
          ? (await api.createFolder(part, parentId: parentId))['id'] as String
          : files.first['id'] as String;
      _folderIds[key] = id;
      parentId = id;
    }
    return parentId;
  }

  Future<String> _rootId() async {
    final cached = _folderIds[''];
    if (cached != null) return cached;
    final files = await api.listFiles(
      "name = '$rootFolderName' and "
      "mimeType = 'application/vnd.google-apps.folder' and trashed = false",
    );
    final id = files.isEmpty
        ? (await api.createFolder(rootFolderName))['id'] as String
        : files.first['id'] as String;
    _folderIds[''] = id;
    return id;
  }

  String? _versionOf(Map<String, dynamic> file) {
    final md5 = file['md5Checksum'] as String?;
    if (md5 != null && md5.isNotEmpty) return md5;
    return file['modifiedTime'] as String?;
  }
}
