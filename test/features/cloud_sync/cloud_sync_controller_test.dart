import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/services/data_backup_service.dart';
import 'package:localmind/core/services/google_sign_in_session.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/features/cloud_sync/data/models/cloud_sync_models.dart';
import 'package:localmind/features/cloud_sync/data/repositories/cloud_sync_local_repository.dart';
import 'package:localmind/features/cloud_sync/data/storage/cloud_sync_storage.dart';
import 'package:localmind/features/cloud_sync/providers/cloud_sync_providers.dart';
import 'package:localmind/features/cloud_sync/services/cloud_sync_crypto_service.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/objectbox.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_sync_test_support.dart';

class _EmptyBox<T> extends Fake implements Box<T> {
  @override
  List<T> getAll() => const [];

  @override
  int put(T entity, {PutMode mode = PutMode.put}) => 1;

  @override
  int removeMany(List<int> ids) => 0;
}

class _FakeStore extends Fake implements Store {
  @override
  Box<T> box<T>() => _EmptyBox<T>();

  @override
  Future<R> runInTransactionAsync<R, T>(
    TxMode mode,
    R Function(Store, T) fn,
    T arg,
  ) async => fn(this, arg);
}

class _FakeDb extends Fake implements ObjectBoxStore {
  final _store = _FakeStore();

  @override
  Store get store => _store;
}

class _RecordingAuth extends Fake implements GoogleAuthAdapter {
  int signOutCalls = 0;
  String? token = 'token-1';

  @override
  Future<void> initialize() async {}

  @override
  Future<GoogleAccount?> restore() async => null;

  @override
  Future<GoogleAccount> signIn() async =>
      const GoogleAccount(email: 'me@example.com');

  @override
  Future<String?> accessToken({bool interactive = false}) async => token;

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }
}

class _FakeStorage implements CloudSyncStorage {
  List<int>? state;
  String? etag;
  int backupWrites = 0;
  int stateWrites = 0;
  bool failStateWrite = false;
  CloudSyncLease? lease;
  final objects = <String, List<int>>{};

  @override
  String get stateKey => 'v1/state.enc';

  @override
  String attachmentKey(String identifier) => 'v1/attachments/$identifier.enc';

  @override
  String get backupPrefix => 'backups';

  @override
  String backupKey(DateTime at) => 'backups/${at.toUtc().toIso8601String()}';

  @override
  bool get requiresLease => true;

  @override
  Future<CloudSyncLease?> readLease() async => lease;

  @override
  Future<void> writeLease(CloudSyncLease value) async => lease = value;

  @override
  Future<void> deleteLease() async => lease = null;

  @override
  Future<void> testConnection() async {}

  @override
  Future<CloudSyncRemoteState?> readState() async =>
      state == null ? null : CloudSyncRemoteState(bytes: state!, etag: etag);

  @override
  Future<CloudSyncRemoteState?> readObject(String key) async {
    final bytes = objects[key];
    return bytes == null
        ? null
        : CloudSyncRemoteState(bytes: bytes, etag: 'object-$key');
  }

  @override
  Future<String?> writeObject(
    String key,
    List<int> bytes, {
    String? expectedEtag,
    bool createOnly = false,
  }) async {
    if (key == stateKey) {
      if (failStateWrite) {
        throw const CloudSyncFailure(
          CloudSyncFailureKind.connectivity,
          'The state write failed.',
        );
      }
      stateWrites++;
    }
    objects[key] = bytes;
    if (key == stateKey) {
      state = bytes;
      etag = 'etag-${objects.length}';
    }
    if (key.startsWith('$backupPrefix/')) backupWrites++;
    return 'etag-${objects.length}';
  }

  @override
  Future<void> deleteObject(String key) async {
    objects.remove(key);
  }

  @override
  Future<bool> objectExists(String key) async =>
      objects.containsKey(key) || (key == stateKey && state != null);

  @override
  Future<List<String>> listBackups() async =>
      objects.keys.where((key) => key.startsWith('$backupPrefix/')).toList()
        ..sort();
}

Map<String, dynamic> _payload(int themeMode) => {
  'version': 1,
  'type': 'cloudSync',
  'settings': {'themeMode': themeMode},
  'conversations': <dynamic>[],
  'messages': <dynamic>[],
  'personas': <dynamic>[],
  'savedMessages': <dynamic>[],
  'savedMessageFolders': <dynamic>[],
  'conversationFolders': <dynamic>[],
};

S3SyncConfig _driveConfig() => const S3SyncConfig(
  endpoint: 'https://s3.amazonaws.com',
  bucket: 'b',
  provider: CloudSyncProviderKind.googleDrive,
  googleAccount: 'me@example.com',
  enabled: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late SharedPreferences prefs;
  late CloudSyncLocalRepository local;
  late CloudSyncCryptoService crypto;
  late List<int> salt;
  late List<int> masterKey;
  late _FakeStorage storage;
  late _RecordingAuth auth;
  late ProviderContainer container;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cloud-sync-controller');
    addTearDown(() => root.delete(recursive: true));
    mockPathProvider(root);
    SharedPreferences.setMockInitialValues({
      'appSettings': AppSettings().toJson(),
    });
    prefs = await SharedPreferences.getInstance();
    local = CloudSyncLocalRepository(prefs, secureStorage: FakeSecureStorage());
    crypto = CloudSyncCryptoService();
    salt = crypto.newSalt();
    masterKey = await crypto.deriveMasterKey('correct horse', salt);
    storage = _FakeStorage();
    auth = _RecordingAuth();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(_FakeDb()),
        cloudSyncLocalRepositoryProvider.overrideWithValue(local),
        cloudSyncStorageFactoryProvider.overrideWithValue((_, _) => storage),
        googleSignInSessionProvider.overrideWithValue(
          GoogleSignInSession(auth),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> enableDrive() async {
    await local.saveConfig(_driveConfig());
    await local.saveSecrets(
      provider: CloudSyncProviderKind.googleDrive,
      masterKey: masterKey,
      salt: salt,
    );
  }

  Future<void> seedRemoteState({Map<String, dynamic>? payload}) async {
    final snapshot = CloudSyncSnapshot(
      deviceId: 'remote-device-1',
      revision: 1,
      updatedAt: DateTime.utc(2026, 10, 1),
      payload: payload ?? _payload(ThemeMode.light.index),
    );
    storage.state = await crypto.encryptState(
      utf8.encode(snapshot.encode()),
      masterKey: masterKey,
      salt: salt,
    );
    storage.etag = 'remote-1';
  }

  Map<String, dynamic> localPayload() => DataBackupService().exportCloudSync(
    container.read(databaseProvider).store,
    AppSettings().toJson(),
  );

  Future<void> setTheme(ThemeMode mode) => container
      .read(settingsProvider.notifier)
      .updateSettings(AppSettings(themeMode: mode));

  test(
    'the hourly window suppresses a second backup and backUpNow forces one',
    () async {
      await enableDrive();
      await seedRemoteState();
      final controller = container.read(cloudSyncControllerProvider.notifier);

      // Establishes the journal base; the remote payload wins on a first sync.
      await controller.syncNow(rethrowErrors: true);
      expect(storage.backupWrites, 0);

      await setTheme(ThemeMode.system);
      await controller.syncNow(rethrowErrors: true);
      expect(storage.backupWrites, 1);

      await setTheme(ThemeMode.dark);
      await controller.syncNow(rethrowErrors: true);
      expect(storage.backupWrites, 1);

      await setTheme(ThemeMode.light);
      await controller.backUpNow();
      expect(storage.backupWrites, 2);
    },
  );

  test(
    'a state write takes and releases the Drive lease for the next device',
    () async {
      await enableDrive();
      await seedRemoteState();
      final controller = container.read(cloudSyncControllerProvider.notifier);

      // The first link adopts the remote settings and has nothing new to write.
      await controller.syncNow(rethrowErrors: true);
      expect(storage.stateWrites, 0);
      expect(storage.lease, isNull);

      await setTheme(ThemeMode.system);
      await controller.syncNow(rethrowErrors: true);
      expect(storage.stateWrites, 1);
      expect(storage.lease, isNull);

      // Another device finds no lease and syncs straight away.
      await prefs.setString('cloudSync.deviceId.v1', 'device-b-0001');
      await controller.syncNow(rethrowErrors: true);
      expect(
        container.read(cloudSyncControllerProvider).phase,
        CloudSyncPhase.synced,
      );
      expect(storage.stateWrites, 1);
      expect(storage.lease, isNull);
    },
  );

  test('a read-only sync writes no state and takes no lease', () async {
    await enableDrive();
    await seedRemoteState(payload: localPayload());
    final controller = container.read(cloudSyncControllerProvider.notifier);

    await controller.syncNow(rethrowErrors: true);
    await controller.syncNow(rethrowErrors: true);
    expect(storage.stateWrites, 0);
    expect(storage.lease, isNull);

    // The periodic pull is a read-only tick as well.
    controller.startPeriodicPull(interval: const Duration(milliseconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    controller.stopPeriodicPull();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(storage.stateWrites, 0);
    expect(storage.lease, isNull);
  });

  test('a failed state write clears the lease', () async {
    await enableDrive();
    await seedRemoteState();
    final controller = container.read(cloudSyncControllerProvider.notifier);
    await controller.syncNow(rethrowErrors: true);

    await setTheme(ThemeMode.system);
    storage.failStateWrite = true;
    await controller.syncNow();

    expect(
      container.read(cloudSyncControllerProvider).phase,
      CloudSyncPhase.error,
    );
    expect(storage.lease, isNull);
  });

  test('disconnecting Drive signs the Google account out', () async {
    await enableDrive();
    final controller = container.read(cloudSyncControllerProvider.notifier);
    storage.lease = CloudSyncLease(
      deviceId: local.getOrCreateDeviceId(),
      heartbeatAt: DateTime.now().toUtc(),
    );

    await controller.disconnect();

    expect(auth.signOutCalls, 1);
    expect(storage.lease, isNull);
    expect(local.loadConfig(), isNull);
  });

  test('disconnecting S3 leaves the Google session alone', () async {
    await local.saveConfig(
      const S3SyncConfig(
        endpoint: 'https://s3.amazonaws.com',
        bucket: 'b',
        enabled: true,
      ),
    );
    await local.saveSecrets(
      provider: CloudSyncProviderKind.s3,
      credentials: const CloudSyncCredentials(
        accessKeyId: 'a',
        secretAccessKey: 'b',
      ),
      masterKey: masterKey,
      salt: salt,
    );
    final controller = container.read(cloudSyncControllerProvider.notifier);

    await controller.disconnect();

    expect(auth.signOutCalls, 0);
    expect(local.loadConfig(), isNull);
  });
}
