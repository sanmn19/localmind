import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/cloud_sync_models.dart';

class CloudSyncLocalRepository {
  CloudSyncLocalRepository(
    this._preferences, {
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
  }) : _secureStorage = secureStorage; // ignore: prefer_initializing_formals

  static const _configKey = 'cloudSync.config.v2';
  static const _legacyConfigKey = 'cloudSync.config.v1';
  static const _deviceKey = 'cloudSync.deviceId.v1';
  static const _journalKey = 'cloudSync.journal.v1';
  static const _lastSyncKey = 'cloudSync.lastSyncedAt.v1';
  static const _accessKey = 'cloudSync.accessKeyId.v1';
  static const _secretKey = 'cloudSync.secretAccessKey.v1';
  static const _sessionKey = 'cloudSync.sessionToken.v1';
  static const _masterKey = 'cloudSync.masterKey.v1';
  static const _saltKey = 'cloudSync.salt.v1';

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secureStorage;

  S3SyncConfig? loadConfig() {
    final raw =
        _preferences.getString(_configKey) ??
        _preferences.getString(_legacyConfigKey);
    if (raw == null) return null;
    try {
      return S3SyncConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveConfig(S3SyncConfig config) =>
      _preferences.setString(_configKey, jsonEncode(config.toJson()));

  String _masterKeyKey(CloudSyncProviderKind provider) =>
      'cloudSync.${provider.name}.masterKey.v1';

  String _saltKeyFor(CloudSyncProviderKind provider) =>
      'cloudSync.${provider.name}.salt.v1';

  Future<CloudSyncCredentials?> loadCredentials() async {
    final accessKey = await _secureStorage.read(key: _accessKey);
    final secret = await _secureStorage.read(key: _secretKey);
    if (accessKey == null || secret == null) return null;
    return CloudSyncCredentials(
      accessKeyId: accessKey,
      secretAccessKey: secret,
      sessionToken: await _secureStorage.read(key: _sessionKey),
    );
  }

  Future<void> saveSecrets({
    required CloudSyncProviderKind provider,
    CloudSyncCredentials? credentials,
    required List<int> masterKey,
    required List<int> salt,
  }) async {
    await Future.wait([
      _secureStorage.write(
        key: _masterKeyKey(provider),
        value: base64Encode(masterKey),
      ),
      _secureStorage.write(
        key: _saltKeyFor(provider),
        value: base64Encode(salt),
      ),
      if (provider == CloudSyncProviderKind.s3 && credentials != null) ...[
        _secureStorage.write(key: _accessKey, value: credentials.accessKeyId),
        _secureStorage.write(
          key: _secretKey,
          value: credentials.secretAccessKey,
        ),
        if (credentials.sessionToken?.isNotEmpty == true)
          _secureStorage.write(
            key: _sessionKey,
            value: credentials.sessionToken,
          )
        else
          _secureStorage.delete(key: _sessionKey),
      ],
    ]);
  }

  Future<List<int>?> loadMasterKey(CloudSyncProviderKind provider) async {
    final value =
        await _secureStorage.read(key: _masterKeyKey(provider)) ??
        (provider == CloudSyncProviderKind.s3
            ? await _secureStorage.read(key: _masterKey)
            : null);
    return value == null ? null : base64Decode(value);
  }

  Future<List<int>?> loadSalt(CloudSyncProviderKind provider) async {
    final value =
        await _secureStorage.read(key: _saltKeyFor(provider)) ??
        (provider == CloudSyncProviderKind.s3
            ? await _secureStorage.read(key: _saltKey)
            : null);
    return value == null ? null : base64Decode(value);
  }

  String getOrCreateDeviceId() {
    final existing = _preferences.getString(_deviceKey);
    if (existing != null) return existing;
    final random = Random.secure();
    final id = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    _preferences.setString(_deviceKey, id);
    return id;
  }

  Future<File> _journalFile() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'cloud-sync'));
    await directory.create(recursive: true);
    return File(p.join(directory.path, 'journal-v1.json'));
  }

  Future<Map<String, dynamic>> loadJournal() async {
    final file = await _journalFile();
    String? raw;
    if (await file.exists()) {
      raw = await file.readAsString();
    } else {
      raw = _preferences.getString(_journalKey);
    }
    if (raw == null) return <String, dynamic>{};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  DateTime? loadLastSync() =>
      DateTime.tryParse(_preferences.getString(_lastSyncKey) ?? '');

  Future<void> saveJournal(Map<String, dynamic> journal) async {
    final file = await _journalFile();
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(journal), flush: true);
    await temporary.rename(file.path);
    await _preferences.remove(_journalKey);
    final lastSync = journal['lastSyncedAt'] as String?;
    if (lastSync != null) await _preferences.setString(_lastSyncKey, lastSync);
  }

  Future<void> disconnect({CloudSyncProviderKind? provider}) async {
    final active = loadConfig()?.provider;
    await _preferences.remove(_configKey);
    await _preferences.remove(_journalKey);
    await _preferences.remove(_lastSyncKey);
    final journal = await _journalFile();
    if (await journal.exists()) await journal.delete();
    if (provider == null || provider == CloudSyncProviderKind.s3) {
      await Future.wait([
        _secureStorage.delete(key: _accessKey),
        _secureStorage.delete(key: _secretKey),
        _secureStorage.delete(key: _sessionKey),
      ]);
    }
    final targets = provider == null
        ? CloudSyncProviderKind.values
        : [provider];
    for (final kind in targets) {
      await _secureStorage.delete(key: _masterKeyKey(kind));
      await _secureStorage.delete(key: _saltKeyFor(kind));
    }
    if (active == null || active == CloudSyncProviderKind.s3) {
      await _secureStorage.delete(key: _masterKey);
      await _secureStorage.delete(key: _saltKey);
    }
  }
}
