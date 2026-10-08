import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/mail/data/mail_common.dart';
import 'package:localmind/features/mail/data/mail_token_store.dart';

void main() {
  group('InMemoryMailTokenStore', () {
    test('persists a token until its expiry and drops it afterwards', () async {
      final store = InMemoryMailTokenStore();
      const provider = MailProvider.gmail;
      await store.updateToken(
        provider,
        'alice@example.org',
        'tok-1',
        DateTime.now().add(const Duration(hours: 1)),
      );
      expect(await store.accessToken(provider, 'alice@example.org'), 'tok-1');

      await store.updateToken(
        provider,
        'alice@example.org',
        'stale',
        DateTime.now().subtract(const Duration(seconds: 1)),
      );
      expect(
        await store.accessToken(provider, 'alice@example.org'),
        isNull,
        reason: 'an expired token must not be handed to the API',
      );
    });

    test('keys are per provider AND per account', () async {
      final store = InMemoryMailTokenStore();
      await store.updateToken(
        MailProvider.gmail,
        'alice@example.org',
        'gmail-tok',
        DateTime.now().add(const Duration(hours: 1)),
      );
      await store.updateToken(
        MailProvider.outlook,
        'alice@example.org',
        'ms-tok',
        DateTime.now().add(const Duration(hours: 1)),
      );
      expect(
        await store.accessToken(MailProvider.gmail, 'alice@example.org'),
        'gmail-tok',
      );
      expect(
        await store.accessToken(MailProvider.outlook, 'alice@example.org'),
        'ms-tok',
      );
    });

    test('clear revokes and unknown accounts read as null', () async {
      final store = InMemoryMailTokenStore();
      await store.updateToken(
        MailProvider.gmail,
        'alice@example.org',
        'tok-1',
        DateTime.now().add(const Duration(hours: 1)),
      );
      await store.clear(MailProvider.gmail, 'alice@example.org');
      expect(
        await store.accessToken(MailProvider.gmail, 'alice@example.org'),
        isNull,
      );
      expect(
        await store.accessToken(MailProvider.gmail, 'nobody@example.org'),
        isNull,
      );
    });
  });

  group('SecureMailTokenStore — key/codec helpers', () {
    test('storage key namespaces provider and email', () {
      expect(
        mailTokenStorageKey(MailProvider.gmail, 'alice@example.org'),
        'mail-token:gmail:alice@example.org',
      );
      expect(
        mailTokenStorageKey(MailProvider.outlook, 'alice@example.org'),
        'mail-token:outlook:alice@example.org',
      );
    });

    test('encoded token JSON round-trips token and expiry', () {
      final expiry = DateTime.utc(2026, 10, 8, 12, 30);
      final encoded = encodeMailToken('tok-1', expiry);
      final decoded = decodeMailToken(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.token, 'tok-1');
      expect(decoded.expiry.toUtc(), expiry);
    });

    test('decodeMailToken returns null on corrupt payloads', () {
      expect(decodeMailToken('not json'), isNull);
      expect(decodeMailToken('{"expiryMs": 123}'), isNull);
      expect(decodeMailToken('null'), isNull);
    });
  });
}
