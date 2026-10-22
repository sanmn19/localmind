import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/cloud_sync/data/models/cloud_sync_models.dart';
import 'package:localmind/features/cloud_sync/data/repositories/cloud_sync_local_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSecureStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> values = {};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final args = invocation.namedArguments;
    if (invocation.memberName == #read) {
      return Future<String?>.value(values[args[#key] as String]);
    }
    if (invocation.memberName == #write) {
      final key = args[#key] as String;
      final value = args[#value] as String?;
      if (value == null) {
        values.remove(key);
      } else {
        values[key] = value;
      }
      return Future<void>.value();
    }
    if (invocation.memberName == #delete) {
      values.remove(args[#key] as String);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

S3SyncConfig _config(CloudSyncProviderKind provider) => S3SyncConfig(
      endpoint: 'https://s3.amazonaws.com',
      bucket: 'b',
      provider: provider,
      googleAccount: provider == CloudSyncProviderKind.googleDrive
          ? 'me@example.com'
          : null,
      enabled: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a v1 S3 config migrates to v2 with provider=s3', () async {
    SharedPreferences.setMockInitialValues({
      'cloudSync.config.v1': '{"endpoint":"https://s3.amazonaws.com","bucket":"b"}',
    });
    final prefs = await SharedPreferences.getInstance();
    final repo = CloudSyncLocalRepository(
      prefs,
      secureStorage: _FakeSecureStorage(),
    );

    final config = repo.loadConfig();

    expect(config?.provider, CloudSyncProviderKind.s3);
    expect(config?.bucket, 'b');
  });

  test('per-provider master keys and salts do not overwrite each other',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secure = _FakeSecureStorage();
    final repo = CloudSyncLocalRepository(prefs, secureStorage: secure);

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
    expect(
      await repo.loadMasterKey(CloudSyncProviderKind.googleDrive),
      [3, 3],
    );
  });

  test('the account email round-trips in config and tokens stay out of prefs',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final repo = CloudSyncLocalRepository(
      prefs,
      secureStorage: _FakeSecureStorage(),
    );

    await repo.saveConfig(_config(CloudSyncProviderKind.googleDrive));
    final raw = prefs.getString('cloudSync.config.v2')!;

    expect(raw, contains('me@example.com'));
    expect(repo.loadConfig()?.provider, CloudSyncProviderKind.googleDrive);
    expect(raw.contains('accessToken'), isFalse);
    expect(raw.contains('refreshToken'), isFalse);
  });
}
