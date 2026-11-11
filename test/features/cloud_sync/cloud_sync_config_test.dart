import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/cloud_sync/data/models/cloud_sync_models.dart';
import 'package:localmind/features/cloud_sync/data/repositories/cloud_sync_local_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_sync_test_support.dart';

S3SyncConfig _config(CloudSyncProviderKind provider) => S3SyncConfig(
  endpoint: 'https://s3.amazonaws.com',
  bucket: 'b',
  provider: provider,
  googleAccount: provider == CloudSyncProviderKind.googleDrive
      ? 'me@example.com'
      : null,
  enabled: true,
);

const _legacyConfig =
    '{"endpoint":"https://s3.amazonaws.com","bucket":"legacy"}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a v1 S3 config migrates to v2 with provider=s3', () async {
    SharedPreferences.setMockInitialValues({
      'cloudSync.config.v1': _legacyConfig,
    });
    final prefs = await SharedPreferences.getInstance();
    final repo = CloudSyncLocalRepository(
      prefs,
      secureStorage: FakeSecureStorage(),
    );

    final config = repo.loadConfig();

    expect(config?.provider, CloudSyncProviderKind.s3);
    expect(config?.bucket, 'legacy');
  });

  test('saving a v2 config drops the pre-port v1 key', () async {
    SharedPreferences.setMockInitialValues({
      'cloudSync.config.v1': _legacyConfig,
    });
    final prefs = await SharedPreferences.getInstance();
    final repo = CloudSyncLocalRepository(
      prefs,
      secureStorage: FakeSecureStorage(),
    );

    await repo.saveConfig(_config(CloudSyncProviderKind.googleDrive));

    expect(prefs.getString('cloudSync.config.v1'), isNull);
    expect(repo.loadConfig()?.provider, CloudSyncProviderKind.googleDrive);
  });

  test('disconnect clears the pre-port v1 config', () async {
    SharedPreferences.setMockInitialValues({
      'cloudSync.config.v1': _legacyConfig,
    });
    final prefs = await SharedPreferences.getInstance();
    final root = Directory.systemTemp.createTempSync('cloud-sync-config');
    addTearDown(() => root.deleteSync(recursive: true));
    mockPathProvider(root);
    final repo = CloudSyncLocalRepository(
      prefs,
      secureStorage: FakeSecureStorage(),
    );
    expect(repo.loadConfig(), isNotNull);

    await repo.disconnect();

    expect(repo.loadConfig(), isNull);
    expect(prefs.getString('cloudSync.config.v1'), isNull);
  });

  test(
    'per-provider master keys and salts do not overwrite each other',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = CloudSyncLocalRepository(
        prefs,
        secureStorage: FakeSecureStorage(),
      );

      await repo.saveSecrets(
        provider: CloudSyncProviderKind.s3,
        credentials: const CloudSyncCredentials(
          accessKeyId: 'a',
          secretAccessKey: 'b',
        ),
        masterKey: const [1, 1],
        salt: const [2, 2],
      );
      await repo.saveSecrets(
        provider: CloudSyncProviderKind.googleDrive,
        masterKey: const [3, 3],
        salt: const [4, 4],
      );

      expect(await repo.loadMasterKey(CloudSyncProviderKind.s3), [1, 1]);
      expect(await repo.loadMasterKey(CloudSyncProviderKind.googleDrive), [
        3,
        3,
      ]);
    },
  );

  test(
    'the account email round-trips in config and tokens stay out of prefs',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = CloudSyncLocalRepository(
        prefs,
        secureStorage: FakeSecureStorage(),
      );

      await repo.saveConfig(_config(CloudSyncProviderKind.googleDrive));
      final raw = prefs.getString('cloudSync.config.v2')!;

      expect(raw, contains('me@example.com'));
      expect(repo.loadConfig()?.provider, CloudSyncProviderKind.googleDrive);
      expect(raw.contains('accessToken'), isFalse);
      expect(raw.contains('refreshToken'), isFalse);
    },
  );
}
