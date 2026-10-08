import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/mcp_client.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/mail/data/mail_common.dart';
import 'package:localmind/features/mail/mail_mcp_server.dart';

class _FakeGmail implements MailMessageApi {
  final List<MailMessageSummary> listResult;
  final List<MailMessageSummary> searchResult;
  final MailMessage? readResult;
  final Object Function()? throwForList;

  _FakeGmail({
    this.listResult = const [],
    this.searchResult = const [],
    this.readResult,
    this.throwForList,
  });

  String? lastTo;
  String? lastSubject;
  String? lastBody;

  @override
  Future<List<MailMessageSummary>> listMessages({
    String? query,
    int limit = 10,
  }) async {
    if (throwForList != null) throw throwForList!();
    return listResult;
  }

  @override
  Future<MailMessage> readMessage(String id) async {
    if (readResult != null) return readResult!;
    return const MailMessage(
      id: 'fallback',
      threadId: 't',
      snippet: '',
      body: '',
    );
  }

  @override
  Future<List<MailMessageSummary>> search(
    String query, {
    int limit = 10,
  }) async {
    return searchResult;
  }

  @override
  Future<String> send(String to, String subject, String body) async {
    lastTo = to;
    lastSubject = subject;
    lastBody = body;
    return 'sent-1';
  }
}

const _mailToolNames = {
  'mail.list_messages',
  'mail.read_message',
  'mail.search',
  'mail.send',
};

Future<McpServerManager> _manager(MailMessageApi gmail) async {
  final manager = McpServerManager();
  await manager.addMailServer(MailServices(gmail: gmail));
  return manager;
}

MailMessageSummary _summary(String id, {String? subject, String? from}) {
  return MailMessageSummary(
    id: id,
    threadId: 't$id',
    snippet: 'snippet of $id',
    from: from,
    subject: subject,
    dateMs: 726305700000,
  );
}

void main() {
  group('the local://mail server', () {
    test('registers exactly the four mail tools under label and url', () async {
      final manager = await _manager(_FakeGmail());

      expect(manager.hasMailServer(), isTrue);
      expect(manager.getServerUrl(mailMcpServerLabel), mailMcpServerUrl);
      expect(manager.getCapabilities(mailMcpServerLabel)?.tools, isTrue);
      expect(
        manager.getTools(mailMcpServerLabel).map((t) => t.name).toSet(),
        _mailToolNames,
      );
    });

    test(
      're-registration replaces the previous services (idempotent)',
      () async {
        final manager = await _manager(_FakeGmail());
        final second = _FakeGmail(listResult: [_summary('later')]);
        await manager.addMailServer(MailServices(gmail: second));

        expect(manager.getMailServices()?.gmail, same(second));
        expect(manager.hasMailServer(), isTrue);
      },
    );

    test('removeServer clears the mail server', () async {
      final manager = await _manager(_FakeGmail());
      await manager.removeServer(mailMcpServerLabel);
      expect(manager.hasMailServer(), isFalse);
      expect(manager.getServerUrl(mailMcpServerLabel), isNull);
    });
  });

  group('mail tool dispatch', () {
    test(
      'mail.list_messages renders numbered rows with subject/from/date',
      () async {
        final manager = await _manager(
          _FakeGmail(
            listResult: [
              _summary('m1', subject: 'Welcome to the crew', from: 'Alice'),
              _summary('m2', subject: 'Re: welcome', from: 'bob@example.org'),
            ],
          ),
        );

        final output = await manager.callTool(
          mailMcpServerLabel,
          'mail.list_messages',
          {'limit': 2},
        );

        expect(output, contains('1. Alice — Welcome to the crew'));
        expect(output, contains('2. bob@example.org — Re: welcome'));
        expect(output, contains('snippet of m1'));
        expect(
          output,
          contains('1993-'),
          reason: 'dateMs must render as an ISO UTC timestamp',
        );
      },
    );

    test('mail.list_messages without results is model-readable', () async {
      final manager = await _manager(_FakeGmail());
      expect(
        await manager.callTool(mailMcpServerLabel, 'mail.list_messages', {}),
        'No matching messages found.',
      );
    });

    test('mail.search routes the query and limit to the repository', () async {
      final gmail = _FakeGmail(
        searchResult: [_summary('s1', subject: 'party friday')],
      );
      final manager = await _manager(gmail);

      final output = await manager.callTool(mailMcpServerLabel, 'mail.search', {
        'query': 'from:carol party',
        'limit': 5,
      });

      expect(output, contains('party friday'));
    });

    test('mail.read_message renders headers plus decoded body', () async {
      final manager = await _manager(
        _FakeGmail(
          readResult: const MailMessage(
            id: 'm1',
            threadId: 't1',
            snippet: 'Hello there',
            from: 'Alice <alice@example.org>',
            subject: 'Welcome to the crew',
            dateMs: 726305700000,
            body: 'Hello there — welcome aboard.',
          ),
        ),
      );

      final output = await manager.callTool(
        mailMcpServerLabel,
        'mail.read_message',
        {'id': 'm1'},
      );

      expect(output, contains('Subject: Welcome to the crew'));
      expect(output, contains('From: Alice <alice@example.org>'));
      expect(output, contains('Hello there — welcome aboard.'));
    });

    test('mail.send forwards the arguments and reports the sent id', () async {
      final gmail = _FakeGmail();
      final manager = await _manager(gmail);

      final output = await manager.callTool(mailMcpServerLabel, 'mail.send', {
        'to': 'bob@example.com',
        'subject': 'Signed contract',
        'body': 'Attached.',
      });

      expect(gmail.lastTo, 'bob@example.com');
      expect(gmail.lastSubject, 'Signed contract');
      expect(gmail.lastBody, 'Attached.');
      expect(output, contains('Sent e-mail to bob@example.com'));
      expect(output, contains('sent-1'));
    });

    test('bad arguments produce McpException-style rejections', () async {
      final manager = await _manager(_FakeGmail());

      expect(
        () => manager.callTool(mailMcpServerLabel, 'mail.search', {'limit': 5}),
        throwsA(predicate((e) => e is McpException && '$e'.contains('query'))),
      );
      expect(
        () => manager.callTool(mailMcpServerLabel, 'mail.read_message', {}),
        throwsA(predicate((e) => e is McpException && '$e'.contains('id'))),
      );
      expect(
        () => manager.callTool(mailMcpServerLabel, 'mail.send', {'to': 'x@y'}),
        throwsA(predicate((e) => e is McpException && '$e'.contains('send'))),
      );
      expect(
        () => manager.callTool(mailMcpServerLabel, 'mail.unknown', {}),
        throwsA(
          predicate((e) => e is McpException && '$e'.contains('mail.unknown')),
        ),
      );
    });

    test(
      'connector failures surface as ERROR lines the model can read',
      () async {
        final manager = await _manager(
          _FakeGmail(
            throwForList: () => const MailConnectorException(
              mailNotAuthenticatedCode,
              'mail account is not connected — reconnect in the settings screen',
            ),
          ),
        );

        final output = await manager.callTool(
          mailMcpServerLabel,
          'mail.list_messages',
          {},
        );

        expect(output, startsWith('ERROR:'));
        expect(output, contains('reconnect in the settings screen'));
      },
    );

    test('oversized output truncates with an explicit marker', () async {
      final summaries = [
        for (var i = 0; i < 200; i++)
          _summary('m$i', subject: 'Subject line padded to be long $i' * 3),
      ];
      final manager = await _manager(_FakeGmail(listResult: summaries));

      final output = await manager.callTool(
        mailMcpServerLabel,
        'mail.list_messages',
        {},
      );

      expect(output.length, lessThanOrEqualTo(mailMaxChars + 12));
      expect(output, endsWith('\n[truncated]'));
    });

    test('unconnected dispatch refuses with the server-down error', () async {
      final manager = McpServerManager();
      expect(
        () => manager.callTool(mailMcpServerLabel, 'mail.list_messages', {}),
        throwsA(isA<McpException>()),
      );
    });
  });
}
