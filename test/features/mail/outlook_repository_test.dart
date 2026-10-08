import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/mail/data/mail_common.dart';
import 'package:localmind/features/mail/data/mail_token_store.dart';
import 'package:localmind/features/mail/data/outlook_auth_client.dart';
import 'package:localmind/features/mail/data/outlook_repository.dart';

const _graphBase = 'https://graph.microsoft.com/v1.0/me';

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.route);

  final ResponseBody Function(RequestOptions options) route;
  final List<RequestOptions> captured = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured.add(options);
    return route(options);
  }
}

class _CannedGateway implements OutlookAuthGateway {
  _CannedGateway(this.token);
  OutlookToken? token;
  int signOuts = 0;
  int signInCalls = 0;

  @override
  Future<OutlookToken?> signIn() async {
    signInCalls++;
    return token;
  }

  @override
  Future<OutlookToken?> silentToken() async {
    return token;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
  }
}

OutlookRepository _repository(
  _RecordingAdapter adapter, {
  MailTokenStore? tokens,
  OutlookToken? gatewayToken,
}) {
  final store = tokens ?? InMemoryMailTokenStore();
  if (tokens == null) {
    store.updateToken(
      MailProvider.outlook,
      'patty@outlook.com',
      'graph-tok',
      DateTime.now().add(const Duration(hours: 1)),
    );
  }
  final gateway = _CannedGateway(gatewayToken);
  return OutlookRepository(
    accountEmail: 'patty@outlook.com',
    dio: Dio()..httpClientAdapter = adapter,
    tokens: store,
    gateway: gateway,
  );
}

ResponseBody _ok(Object body) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

Map<String, dynamic> _graphMessage({
  required String id,
  required String subject,
  required String from,
  required String preview,
  String received = '2024-06-01T09:00:00Z',
  String conversation = 'conv-1',
}) {
  return {
    'id': id,
    'conversationId': conversation,
    'subject': subject,
    'bodyPreview': preview,
    'from': {
      'emailAddress': {'name': from, 'address': from},
    },
    'receivedDateTime': received,
  };
}

void main() {
  group('OutlookRepository — mapping', () {
    test('listMessages maps inbox rows to summaries', () async {
      final adapter = _RecordingAdapter((options) {
        if (options.uri.path.contains('/mailFolders/Inbox/messages')) {
          return _ok({
            'value': [
              _graphMessage(
                id: 'AAA1',
                subject: 'Invoice pending',
                from: 'billing@contoso.com',
                preview: 'Your invoice details are inside.',
              ),
              _graphMessage(
                id: 'AAA2',
                subject: 'Hi',
                from: 'friend@example.net',
                preview: 'short body',
              ),
            ],
          });
        }
        return ResponseBody.fromString('unexpected', 404);
      });
      final repo = _repository(adapter);

      final rows = await repo.listMessages(limit: 2);

      expect(rows, hasLength(2));
      expect(rows.first.id, 'AAA1');
      expect(rows.first.from, 'billing@contoso.com');
      expect(rows.first.subject, 'Invoice pending');
      expect(rows.first.dateMs, isNotNull);
    });

    test('listMessages with a query uses the graph search parameter', () async {
      final adapter = _RecordingAdapter((options) {
        if (options.uri.path.contains('/messages')) {
          expect(
            options.uri.queryParameters,
            containsPair(r'$search', '"from:carol party"'),
          );
          return _ok({
            'value': [
              _graphMessage(
                id: 'Q1',
                subject: 'found',
                from: 'c@x',
                preview: 'p',
              ),
            ],
          });
        }
        return ResponseBody.fromString('unexpected', 404);
      });
      final repo = _repository(adapter);

      final rows = await repo.listMessages(query: 'from:carol party', limit: 3);
      expect(rows.single.subject, 'found');
    });

    test('readMessage pulls the body content', () async {
      final adapter = _RecordingAdapter((options) {
        return _ok({
          ..._graphMessage(
            id: 'AAA1',
            subject: 'read me',
            from: 'a@b.c',
            preview: 'prev',
          ),
          'body': {'contentType': 'Text', 'content': 'the full message body'},
        });
      });
      final repo = _repository(adapter);

      final message = await repo.readMessage('AAA1');

      expect(message.body, 'the full message body');
      expect(message.subject, 'read me');
      expect(message.from, 'a@b.c');
    });

    test('send posts a Graph sendMail payload and synthesizes an id', () async {
      final adapter = _RecordingAdapter(
        (options) => ResponseBody.fromString('', 202),
      );
      final repo = _repository(adapter);

      final id = await repo.send(
        'bob@example.com',
        'Signed contract',
        'Attached.',
      );

      expect(adapter.captured.single.uri.toString(), '$_graphBase/sendMail');
      expect(id, isNotEmpty);
    });
  });

  group('OutlookRepository — tokens/errors', () {
    test(
      'missing token + silent miss surfaces mail_not_authenticated',
      () async {
        final adapter = _RecordingAdapter((_) => _ok({'value': []}));
        final gateway = _CannedGateway(null);
        final store = InMemoryMailTokenStore();
        final repo = OutlookRepository(
          accountEmail: 'patty@outlook.com',
          dio: Dio()..httpClientAdapter = adapter,
          tokens: store,
          gateway: gateway,
        );

        try {
          await repo.listMessages();
          fail('expected MailConnectorException');
        } on MailConnectorException catch (e) {
          expect(e.code, 'mail_not_authenticated');
          expect(e.message, isNot(contains('token')));
        }
      },
    );

    test('gateway token flows into the store and requests carry it', () async {
      final adapter = _RecordingAdapter((_) => _ok({'value': []}));
      final store = InMemoryMailTokenStore();
      final gateway = _CannedGateway(
        OutlookToken(
          accessToken: 'graph-tok',
          email: 'patty@outlook.com',
          expiry: DateTime.now().add(const Duration(hours: 1)),
        ),
      );
      final repo = OutlookRepository(
        accountEmail: 'patty@outlook.com',
        dio: Dio()..httpClientAdapter = adapter,
        tokens: store,
        gateway: gateway,
      );

      await repo.listMessages();

      for (final request in adapter.captured) {
        expect(request.headers['Authorization'], 'Bearer graph-tok');
      }
      expect(
        await store.accessToken(MailProvider.outlook, 'patty@outlook.com'),
        'graph-tok',
      );
    });

    test(
      'gateway misconfiguration surfaces while the client id is missing',
      () async {
        final gateway = MsalOutlookAuthGateway(
          clientId: '',
          tokens: InMemoryMailTokenStore(),
        );

        try {
          await gateway.signIn();
          fail('expected misconfigured connector');
        } on Exception catch (e) {
          expect('${e.runtimeType}', contains('MailConnector'));
          expect('$e', contains('not configured'));
        }
      },
    );
  });
}
