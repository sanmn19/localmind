import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/mail/data/imap_repository.dart';
import 'package:localmind/features/mail/data/mail_common.dart';
import 'package:localmind/features/mail/data/mail_token_store.dart';

final _farFuture = DateTime.parse('9999-01-01T00:00:00Z');

class _FakeImapWorker implements ImapWorker {
  _FakeImapWorker({this.listResult = const [], this.readResult});

  final List<({String host, int port, String user, String password})> connects =
      [];
  final List<String> queries = [];
  final List<String> readIds = [];
  final List<({String to, String subject, String body})> sends = [];
  int releases = 0;

  List<MailMessageSummary> listResult;
  MailMessage? readResult;
  String sentId = 'imap-4711';

  Object? Function()? connectError;
  Object? Function()? listError;

  @override
  Future<void> connect(
    String host,
    int port,
    String user,
    String password,
  ) async {
    final error = connectError?.call();
    if (error != null) throw error;
    connects.add((host: host, port: port, user: user, password: password));
  }

  @override
  Future<List<MailMessageSummary>> listRecent({
    required String? query,
    required int limit,
  }) async {
    final error = listError?.call();
    if (error != null) throw error;
    queries.add(query ?? '');
    if (listResult.length > limit) return listResult.sublist(0, limit);
    return listResult;
  }

  @override
  Future<MailMessage> fetchBody(String id) async {
    readIds.add(id);
    return readResult ??
        MailMessage(id: id, threadId: '', snippet: '', body: '');
  }

  @override
  Future<String> smtpSend(String to, String subject, String body) async {
    sends.add((to: to, subject: subject, body: body));
    return sentId;
  }

  @override
  Future<void> release() async {
    releases++;
  }
}

Future<ImapRepository> _repository(
  _FakeImapWorker worker, {
  MailTokenStore? tokens,
  String? hostOverride,
  String email = 'alice@gmail.com',
  Duration sessionMaxIdle = const Duration(minutes: 4),
}) async {
  final store = tokens ?? InMemoryMailTokenStore();
  if (tokens == null) {
    await store.updateToken(
      MailProvider.imap,
      email,
      'app-password-abc',
      _farFuture,
    );
  }
  return ImapRepository(
    accountEmail: email,
    tokens: store,
    worker: worker,
    hostOverride: hostOverride,
    sessionMaxIdle: sessionMaxIdle,
  );
}

MailMessageSummary _summary(String id, {String? subject, String? from}) =>
    MailMessageSummary(
      id: id,
      threadId: 't$id',
      snippet: 'snippet of $id',
      from: from,
      subject: subject,
      dateMs: 1700000000000,
    );

void main() {
  group('resolveImapEndpoints — host auto-resolution by e-mail domain', () {
    test('gmail.com maps to the Google IMAP/SMTP hosts', () {
      final endpoints = resolveImapEndpoints('gmail.com');
      expect(endpoints, isNotNull);
      expect(endpoints!.imapHost, 'imap.gmail.com');
      expect(endpoints.imapPort, 993);
      expect(endpoints.smtpHost, 'smtp.gmail.com');
      expect(endpoints.smtpPort, 465);
    });

    test('googlemail.com is treated as Google mail', () {
      final endpoints = resolveImapEndpoints('googlemail.com');
      expect(endpoints?.imapHost, 'imap.gmail.com');
    });

    test('known standard providers map their documented hosts', () {
      expect(
        resolveImapEndpoints('fastmail.com')?.imapHost,
        'imap.fastmail.com',
      );
      expect(
        resolveImapEndpoints('fastmail.com')?.smtpHost,
        'smtp.fastmail.com',
      );
      expect(resolveImapEndpoints('icloud.com')?.imapHost, 'imap.mail.me.com');
      expect(resolveImapEndpoints('yandex.com')?.smtpHost, 'smtp.yandex.com');
      expect(resolveImapEndpoints('zoho.com')?.imapHost, 'imap.zoho.com');
    });

    test('domains are matched case-insensitively with whitespace trimmed', () {
      expect(resolveImapEndpoints(' Gmail.COM ')?.imapHost, 'imap.gmail.com');
    });

    test('microsoft-owned consumer domains refuse basic auth explicitly', () {
      for (final domain in [
        'outlook.com',
        'hotmail.com',
        'live.com',
        'msn.com',
      ]) {
        expect(resolveImapEndpoints(domain), isNull, reason: domain);
      }
    });

    test('unknown domains return null so the repo demands a manual host', () {
      expect(resolveImapEndpoints('example.org'), isNull);
      expect(resolveImapEndpoints(''), isNull);
    });
  });

  group('MailProviderName — the imap provider name', () {
    test('the imap value round-trips through nameOf/fromName', () {
      expect(MailProviderName.nameOf(MailProvider.imap), 'imap');
      expect(MailProviderName.fromName('imap'), MailProvider.imap);
      expect(MailProviderName.fromName('gmail'), MailProvider.gmail);
      expect(MailProviderName.fromName('outlook'), MailProvider.outlook);
      expect(MailProviderName.fromName(null), MailProvider.gmail);
      expect(MailProviderName.fromName('nonsense'), MailProvider.gmail);
    });
  });

  group('ImapRepository — session + dispatch through the worker seam', () {
    test('listMessages connects with the auto-resolved hosts and the '
        'stored app password, then lists', () async {
      final worker = _FakeImapWorker(
        listResult: [
          _summary('imap:7', subject: 'Welcome', from: 'alice@example.com'),
        ],
      );
      final repo = await _repository(worker);

      final rows = await repo.listMessages(limit: 2);

      expect(worker.connects.single.host, 'imap.gmail.com');
      expect(worker.connects.single.port, 993);
      expect(worker.connects.single.user, 'alice@gmail.com');
      expect(worker.connects.single.password, 'app-password-abc');
      expect(rows.single.subject, 'Welcome');
    });

    test('a missing app password rejects as not-authenticated before any '
        'connection attempt', () async {
      final worker = _FakeImapWorker();
      final repo = await _repository(
        worker,
        tokens: InMemoryMailTokenStore(),
        email: 'bob@example.org',
      );

      try {
        await repo.listMessages();
        fail('expected MailConnectorException');
      } on MailConnectorException catch (e) {
        expect(e.code, 'mail_not_authenticated');
        expect(e.message, contains('app password'));
      }
      expect(worker.connects, isEmpty);
    });

    test('search forwards the raw query to the worker', () async {
      final worker = _FakeImapWorker(listResult: [_summary('imap:8')]);
      final repo = await _repository(worker);

      final rows = await repo.search('FROM "carol"', limit: 5);

      expect(worker.queries.single, 'FROM "carol"');
      expect(rows.single.id, 'imap:8');
    });

    test('readMessage fetches the full body through the worker', () async {
      final worker = _FakeImapWorker(
        readResult: const MailMessage(
          id: 'imap:9',
          threadId: 't9',
          snippet: 'nuggets',
          from: 'carol@example.org',
          subject: 'Hi',
          dateMs: 1700000000000,
          body: 'Hello imap world.',
        ),
      );
      final repo = await _repository(worker);

      final message = await repo.readMessage('imap:9');

      expect(worker.readIds.single, 'imap:9');
      expect(message.body, 'Hello imap world.');
      expect(message.from, 'carol@example.org');
    });

    test('send validates the recipient and delegates to the worker, '
        'returning a synthesized imap id', () async {
      final worker = _FakeImapWorker();
      final repo = await _repository(worker);

      final id = await repo.send('dan@example.org', 'Hello', 'Body text.');

      expect(worker.sends.single.to, 'dan@example.org');
      expect(worker.sends.single.subject, 'Hello');
      expect(id, startsWith('imap-'));
      expect(id.length, greaterThan('imap-'.length));

      try {
        await repo.send('  ', 'Hello', 'Body text.');
        fail('expected MailConnectorException');
      } on MailConnectorException catch (e) {
        expect(e.code, 'mail_invalid_args');
      }
      expect(worker.sends, hasLength(1));
    });

    test('consecutive calls reuse the lazily cached session', () async {
      final worker = _FakeImapWorker(listResult: [_summary('a')]);
      final repo = await _repository(worker);

      await repo.listMessages();
      await repo.search('FROM "x"');
      await repo.readMessage('imap:1');
      await repo.send('to@x.org', 's', 'b');

      expect(worker.connects, hasLength(1));
    });

    test('an idle-expired session reconnects on the next call', () async {
      final worker = _FakeImapWorker();
      final repo = await _repository(worker, sessionMaxIdle: Duration.zero);

      await repo.listMessages();
      await repo.listMessages();

      expect(worker.connects, hasLength(2));
      expect(worker.releases, greaterThanOrEqualTo(1));
    });

    test('a manual host override wins over the auto-resolution (even for '
        'domains that would otherwise be refused)', () async {
      final worker = _FakeImapWorker();
      final repo = await _repository(
        worker,
        hostOverride: 'imap.custom.dev',
        email: 'bob@unknown-domain.dev',
      );

      await repo.listMessages();

      expect(worker.connects.single.host, 'imap.custom.dev');
      expect(worker.connects.single.port, 993);
    });

    test('an unresolvable host raises mail_connector_misconfigured with the '
        'set-host-manually guidance', () async {
      final worker = _FakeImapWorker();
      final repo = await _repository(worker, email: 'bob@nobody-heard-of.dev');

      try {
        await repo.listMessages();
        fail('expected MailConnectorException');
      } on MailConnectorException catch (e) {
        expect(e.code, 'mail_connector_misconfigured');
        expect(e.message, contains('unknown imap host'));
        expect(e.message, contains('set the host manually'));
      }
      expect(worker.connects, isEmpty);
    });

    test('microsoft consumer domains redirect the user to the Outlook '
        'OAuth flow instead of attempting IMAP', () async {
      final worker = _FakeImapWorker();
      final repo = await _repository(worker, email: 'patty@hotmail.com');

      try {
        await repo.listMessages();
        fail('expected MailConnectorException');
      } on MailConnectorException catch (e) {
        expect(e.code, 'mail_connector_misconfigured');
        expect(e.message, contains('Outlook'));
        expect(e.message, contains('OAuth'));
      }
      expect(worker.connects, isEmpty);
    });

    test(
      'worker auth faults surface as mail_not_authenticated with the '
      're-enter hint; other faults stay structured request failures',
      () async {
        final authFault = _FakeImapWorker()
          ..connectError = () => const MailConnectorException(
            mailNotAuthenticatedCode,
            'sign-in failed — check or re-enter the app password',
          );
        final repo = await _repository(authFault);

        try {
          await repo.listMessages();
          fail('expected MailConnectorException');
        } on MailConnectorException catch (e) {
          expect(e.code, 'mail_not_authenticated');
          expect(e.message, contains('re-enter the app password'));
        }

        final randomFault = _FakeImapWorker()
          ..connectError = () => StateError('socket exploded');
        final repo2 = await _repository(randomFault);

        try {
          await repo2.listMessages();
          fail('expected MailConnectorException');
        } on MailConnectorException catch (e) {
          expect(e.code, 'mail_request_failed');
        }
      },
    );
  });
}
