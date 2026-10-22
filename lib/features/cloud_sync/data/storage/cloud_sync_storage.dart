import '../models/cloud_sync_models.dart';

/// A cloud object store the encrypted sync state and attachments live in.
///
/// S3 and Google Drive implement this; the controller only speaks this surface.
abstract class CloudSyncStorage {
  /// The encrypted state object key (e.g. `v1/state.enc`).
  String get stateKey;

  /// The key of one encrypted attachment.
  String attachmentKey(String identifier);

  /// The key of a rotated backup of the state object.
  String backupKey(DateTime at);

  /// The prefix rotated backups live under.
  String get backupPrefix;

  Future<void> testConnection();

  Future<CloudSyncRemoteState?> readState();

  Future<CloudSyncRemoteState?> readObject(String key);

  /// Writes [bytes]; returns the new version token (backend-specific).
  ///
  /// [expectedEtag]/[createOnly] are honored where the backend supports
  /// conditional writes (S3); Drive ignores them and relies on its device lease.
  Future<String?> writeObject(
    String key,
    List<int> bytes, {
    String? expectedEtag,
    bool createOnly = false,
  });

  Future<void> deleteObject(String key);

  Future<bool> objectExists(String key);

  /// Keys under [backupPrefix], newest last (ISO timestamp names).
  Future<List<String>> listBackups();
}
