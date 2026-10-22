import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/features/cloud_sync/data/models/cloud_sync_models.dart';
import 'package:localmind/features/cloud_sync/data/repositories/cloud_sync_local_repository.dart';
import 'package:localmind/features/cloud_sync/providers/cloud_sync_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_sync_test_support.dart';

S3SyncConfig _config({bool enabled = true}) => S3SyncConfig(
  endpoint: 'https://s3.amazonaws.com',
  bucket: 'b',
  provider: CloudSyncProviderKind.googleDrive,
  googleAccount: 'me@example.com',
  enabled: enabled,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late CloudSyncLocalRepository local;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    local = CloudSyncLocalRepository(prefs, secureStorage: FakeSecureStorage());
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        cloudSyncLocalRepositoryProvider.overrideWithValue(local),
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
    await local.saveConfig(_config());
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final controller = container.read(cloudSyncControllerProvider.notifier);

    expect(controller.isPeriodicPullActive, isTrue);
  });

  test('build skips periodic pull when sync is disabled', () async {
    await local.saveConfig(_config(enabled: false));
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final controller = container.read(cloudSyncControllerProvider.notifier);

    expect(controller.isPeriodicPullActive, isFalse);
  });

  test('build skips periodic pull off macOS', () async {
    await local.saveConfig(_config());
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    final controller = container.read(cloudSyncControllerProvider.notifier);

    expect(controller.isPeriodicPullActive, isFalse);
  });

  test('the timer triggers a sync while it is active', () async {
    await local.saveConfig(_config());
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
}
