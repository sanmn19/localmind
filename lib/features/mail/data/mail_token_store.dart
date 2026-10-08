import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'mail_common.dart';

/// Backs the [MailTokenStore] secrets with the platform keystore.
/// Abstract so tests can inject a stub without touching real storage.
abstract class SecureStorageApi {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class FlutterSecureStorageApi implements SecureStorageApi {
  const FlutterSecureStorageApi();

  @override
  Future<String?> read(String key) =>
      const FlutterSecureStorage().read(key: key);

  @override
  Future<void> write(String key, String value) =>
      const FlutterSecureStorage().write(key: key, value: value);

  @override
  Future<void> delete(String key) =>
      const FlutterSecureStorage().delete(key: key);
}

/// Caches the mail connectors' bearer tokens per provider+account with an
/// explicit expiry. The provider SDKs manage their own caches; this store
/// is the app-side re-provisioning cache the repositories consult first.
abstract class MailTokenStore {
  Future<void> updateToken(
    MailProvider provider,
    String email,
    String token,
    DateTime expiry,
  );

  /// Returns the unexpired token or null (expired = never surfaced).
  Future<String?> accessToken(MailProvider provider, String email);

  Future<void> clear(MailProvider provider, String email);
}

class InMemoryMailTokenStore implements MailTokenStore {
  final Map<String, (String token, DateTime expiry)> _entries = {};

  static String _key(MailProvider provider, String email) =>
      '${provider.name}:$email';

  @override
  Future<void> updateToken(
    MailProvider provider,
    String email,
    String token,
    DateTime expiry,
  ) async {
    _entries[_key(provider, email)] = (token, expiry);
  }

  @override
  Future<String?> accessToken(MailProvider provider, String email) async {
    final entry = _entries[_key(provider, email)];
    if (entry == null) return null;
    final (token, expiry) = entry;
    if (expiry.isBefore(DateTime.now())) return null;
    return token;
  }

  @override
  Future<void> clear(MailProvider provider, String email) async {
    _entries.remove(_key(provider, email));
    return;
  }
}

/// Encoded-token helpers shared with the secure store so the on-disk
/// format stays testable.
String mailTokenStorageKey(MailProvider provider, String email) =>
    'mail-token:${provider.name}:$email';

String encodeMailToken(String token, DateTime expiry) => jsonEncode({
  'token': token,
  'expiryMs': expiry.toUtc().millisecondsSinceEpoch,
});

({String token, DateTime expiry})? decodeMailToken(String payload) {
  try {
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) return null;
    final token = decoded['token']?.toString();
    final expiryMs = decoded['expiryMs'];
    if (token == null || token.isEmpty || expiryMs is! int) return null;
    return (
      token: token,
      expiry: DateTime.fromMillisecondsSinceEpoch(expiryMs, isUtc: true),
    );
  } on FormatException {
    return null;
  }
}

class SecureMailTokenStore implements MailTokenStore {
  SecureMailTokenStore({SecureStorageApi? storage})
    : _storage = storage ?? const FlutterSecureStorageApi();

  final SecureStorageApi _storage;

  @override
  Future<void> updateToken(
    MailProvider provider,
    String email,
    String token,
    DateTime expiry,
  ) {
    return _storage.write(
      mailTokenStorageKey(provider, email),
      encodeMailToken(token, expiry),
    );
  }

  @override
  Future<String?> accessToken(MailProvider provider, String email) async {
    final payload = await _storage.read(mailTokenStorageKey(provider, email));
    if (payload == null || payload.isEmpty) return null;
    final decoded = decodeMailToken(payload);
    if (decoded == null) return null;
    if (decoded.expiry.isBefore(DateTime.now())) return null;
    return decoded.token;
  }

  @override
  Future<void> clear(MailProvider provider, String email) {
    return _storage.delete(mailTokenStorageKey(provider, email));
  }
}

/// The app-scoped instance: repositories read tokens through this.
final mailTokenStoreProvider = Provider<MailTokenStore>((ref) {
  return SecureMailTokenStore();
});
