import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/features/cloud_sync/data/models/cloud_sync_models.dart';
import 'package:localmind/features/cloud_sync/data/repositories/cloud_sync_local_repository.dart';
import 'package:localmind/features/cloud_sync/data/storage/cloud_sync_storage.dart';
import 'package:localmind/features/cloud_sync/providers/cloud_sync_providers.dart';
import 'package:localmind/objectbox.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_sync_test_support.dart';

S3SyncConfig _driveConfig({bool enabled = true}) => S3SyncConfig(
  endpoint: 'https://s3.amazonaws.com',
  bucket: 'b',
  provider: CloudSyncProviderKind.googleDrive,
  googleAccount: 'me@example.com',
  enabled: enabled,
);

S3SyncConfig _s3Config({bool enabled = true}) => S3SyncConfig(
  endpoint: 'https://s3.amazonaws.com',
  bucket: 'b',
  enabled: enabled,
);

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

class _FakeStorage implements CloudSyncStorage {
  List<int>? state;
  String? etag;
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
    objects[key] = bytes;
    if (key == stateKey) {
      state = bytes;
      etag = 'etag-${objects.length}';
    }
    return 'etag-${objects.length}';
  }

  @override
  Future<void> deleteObject(String key) async => objects.remove(key);

  @override
  Future<bool> objectExists(String key) async =>
      objects.containsKey(key) || (key == stateKey && state != null);

  @override
  Future<List<String>> listBackups() async =>
      objects.keys.where((key) => key.startsWith('$backupPrefix/')).toList()
        ..sort();

  @override
  bool get requiresLease => false;

  @override
  Future<CloudSyncLease?> readLease() async => null;

  @override
  Future<void> writeLease(CloudSyncLease lease) async {}

  @override
  Future<void> deleteLease() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late SharedPreferences prefs;
  late CloudSyncLocalRepository local;
  late ProviderContainer container;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cloud-sync-periodic');
    addTearDown(() => root.delete(recursive: true));
    mockPathProvider(root);
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    local = CloudSyncLocalRepository(prefs, secureStorage: FakeSecureStorage());
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        cloudSyncLocalRepositoryProvider.overrideWithValue(local),
        databaseProvider.overrideWithValue(_FakeDb()),
        cloudSyncStorageFactoryProvider.overrideWithValue(
          (_, _) => _FakeStorage(),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('periodic pull starts and stops with the controller', () {
    final controller = container.read(cloudSyncControllerProvider.notifier);

    expect(controller.isPeriodicPullActive, isFalse);
    controller.startPeriodicPull(interval: const Duration(milliseconds: 20));
    expect(controller.isPeriodicPullActive, isTrue);
    controller.stopPeriodicPull();
    expect(controller.isPeriodicPullActive, isFalse);
  });

  test('build starts periodic pull for an enabled config on macOS', () async {
    await local.saveConfig(_driveConfig());
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final controller = container.read(cloudSyncControllerProvider.notifier);

    expect(controller.isPeriodicPullActive, isTrue);
  });

  test('build skips periodic pull when sync is disabled', () async {
    await local.saveConfig(_driveConfig(enabled: false));
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final controller = container.read(cloudSyncControllerProvider.notifier);

    expect(controller.isPeriodicPullActive, isFalse);
  });

  test('build skips periodic pull off macOS', () async {
    await local.saveConfig(_driveConfig());
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    final controller = container.read(cloudSyncControllerProvider.notifier);

    expect(controller.isPeriodicPullActive, isFalse);
  });

  test('the timer triggers a sync while it is active', () async {
    await local.saveConfig(_driveConfig());
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final controller = container.read(cloudSyncControllerProvider.notifier);
    expect(
      container.read(cloudSyncControllerProvider).phase,
      CloudSyncPhase.ready,
    );

    controller.startPeriodicPull(interval: const Duration(milliseconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // No unlocked master key is stored, so an attempted sync reports locked.
    expect(
      container.read(cloudSyncControllerProvider).phase,
      CloudSyncPhase.locked,
    );
  });

  test('configure starts the periodic pull on macOS', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = container.read(cloudSyncControllerProvider.notifier);
    expect(controller.isPeriodicPullActive, isFalse);

    await controller.configure(
      config: _driveConfig(enabled: false),
      passphrase: 'correct horse',
    );

    expect(controller.isPeriodicPullActive, isTrue);
    expect(local.loadConfig()?.enabled, isTrue);
  });

  test('configure leaves the periodic pull off elsewhere', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final controller = container.read(cloudSyncControllerProvider.notifier);

    await controller.configure(
      config: _driveConfig(enabled: false),
      passphrase: 'correct horse',
    );

    expect(controller.isPeriodicPullActive, isFalse);
  });

  test('disconnect stops the periodic pull and clears the config', () async {
    await local.saveConfig(_s3Config());
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = container.read(cloudSyncControllerProvider.notifier);
    expect(controller.isPeriodicPullActive, isTrue);

    await controller.disconnect();

    expect(controller.isPeriodicPullActive, isFalse);
    expect(local.loadConfig(), isNull);
  });
}
