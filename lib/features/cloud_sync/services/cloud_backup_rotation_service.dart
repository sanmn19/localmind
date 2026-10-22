import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/models/cloud_sync_models.dart';
import '../data/storage/cloud_sync_storage.dart';

class RotationResult {
  const RotationResult({this.localPath, this.cloudKey});

  final String? localPath;

  final String? cloudKey;
}

/// Snapshots the existing remote state before it is replaced: one local copy and
/// one cloud copy, both verified, then the 3 newest of each are kept.
class CloudBackupRotationService {
  CloudBackupRotationService({required this.localRoot});

  final Directory localRoot;

  static const keep = 3;

  /// Backups are written at most once per hour unless explicitly forced.
  static const minimumInterval = Duration(hours: 1);

  /// Whether the remote state is due for a snapshot before it is replaced.
  static bool shouldRotate({
    required bool forced,
    required DateTime? lastBackupAt,
    required DateTime now,
  }) =>
      forced ||
      lastBackupAt == null ||
      now.difference(lastBackupAt) >= minimumInterval;

  Future<RotationResult> rotateBeforeWrite({
    required CloudSyncStorage storage,
    required List<int> existingState,
    required DateTime now,
  }) async {
    await localRoot.create(recursive: true);

    final stamp = _stamp(now);
    final localFile = File(p.join(localRoot.path, '$stamp.enc'));
    final temporary = File('${localFile.path}.tmp');
    await temporary.writeAsBytes(existingState, flush: true);
    final written = await temporary.length();
    if (written != existingState.length) {
      await temporary.delete();
      throw const CloudSyncFailure(
        CloudSyncFailureKind.unknown,
        'Could not write the local backup copy.',
      );
    }
    await temporary.rename(localFile.path);

    final cloudKey = storage.backupKey(now);
    await storage.writeObject(cloudKey, existingState);
    if (!await storage.objectExists(cloudKey)) {
      throw const CloudSyncFailure(
        CloudSyncFailureKind.connectivity,
        'Could not write the cloud backup copy.',
      );
    }

    await _pruneLocal();
    await _pruneCloud(storage);
    return RotationResult(localPath: localFile.path, cloudKey: cloudKey);
  }

  Future<void> _pruneLocal() async {
    final files =
        (await localRoot
              .list()
              .where((entity) => entity is File)
              .cast<File>()
              .where((file) => file.path.endsWith('.enc'))
              .toList())
          ..sort((a, b) => a.path.compareTo(b.path));
    while (files.length > keep) {
      final oldest = files.removeAt(0);
      if (await oldest.exists()) await oldest.delete();
    }
  }

  Future<void> _pruneCloud(CloudSyncStorage storage) async {
    final keys = (await storage.listBackups())..sort();
    while (keys.length > keep) {
      await storage.deleteObject(keys.removeAt(0));
    }
  }

  String _stamp(DateTime at) =>
      at.toUtc().toIso8601String().replaceAll(':', '-').replaceAll('.', '-');
}
