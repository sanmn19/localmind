import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/mail/data/gmail_repository.dart';
import 'package:localmind/features/mail/data/google_auth_client.dart';
import 'package:localmind/features/mail/data/mail_common.dart';
import 'package:localmind/features/mail/data/mail_token_store.dart';

const _gmailBase = 'https://gmail.googleapis.com/gmail/v1/users/me';

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
    if (options.method == 'POST') {
      final builder = BytesBuilder();
      await requestStream?.fold(builder, (b, d) => b..add(d));
      capturedBodies.add(utf8.decode(builder.takeBytes()));
    }
    return route(options);
  }

  final List<String> capturedBodies = [];
}

/// Gateway fake: the repository must never pop a sign-in sheet from a
/// unit test; one canned token is all a token-hit path needs.
class _CannedGateway implements GoogleAuthGateway {
  _CannedGateway(this.token);
  GoogleToken? token;
  int silentCalls = 0;

  @override
  Future<GoogleToken?> signIn() async => token;

  @override
  Future<GoogleToken?> silentToken() async {
    silentCalls++;
    return token;
  }

  @override
  Future<void> signOut() async {}
}

const _farFuture = '9999-01-01T00:00:00Z';

Future<GmailRepository> _repository(
  _RecordingAdapter adapter, {
  MailTokenStore? tokens,
  GoogleAuthGateway? gateway,
}) async {
  final store = tokens ?? InMemoryMailTokenStore();
  if (tokens == null) {
    await store.updateToken(
      MailProvider.gmail,
      'alice@example.org',
      'token-xyz',
      DateTime.parse(_farFuture),
    );
  }
  return GmailRepository(
    accountEmail: 'alice@example.org',
    dio: Dio()..httpClientAdapter = adapter,
    tokens: store,
    gateway: gateway ?? _CannedGateway(null),
  );
}

ResponseBody _ok(Object body) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

void main() {
  group('GmailRepository — message mapping', () {
    test('listMessages hydrates metadata for each listed message id', () async {
      final adapter = _RecordingAdapter((options) {
        final url = options.uri.toString();
        if (url.contains('$_gmailBase/messages?')) {
          return _ok({
            'messages': [
              {'id': 'm1', 'threadId': 't1'},
              {'id': 'm2', 'threadId': 't2'},
            ],
            'resultSizeEstimate': 2,
          });
        }
        if (url.startsWith('$_gmailBase/messages/m1')) {
          return _ok(
            _metadataFixture(
              id: 'm1',
              from: 'Alice <alice@example.org>',
              subject: 'Welcome to the crew',
              internalDate: '726305700000',
              snippet: 'Hello team',
            ),
          );
        }
        if (url.startsWith('$_gmailBase/messages/m2')) {
          return _ok(
            _metadataFixture(
              id: 'm2',
              from: 'bob@example.org',
              subject: 'Re: welcome',
              internalDate: '726306000000',
              snippet: 'Thanks for having me',
            ),
          );
        }
        return ResponseBody.fromString('unexpected', 404);
      });
      final repo = await _repository(adapter);

      final summaries = await repo.listMessages(limit: 2);

      expect(summaries, hasLength(2));
      expect(summaries.first.id, 'm1');
      expect(summaries.first.threadId, 't1');
      expect(summaries.first.snippet, 'Hello team');
      expect(summaries.first.from, 'Alice <alice@example.org>');
      expect(summaries.first.subject, 'Welcome to the crew');
      expect(summaries.first.dateMs, 726305700000);
      expect(summaries.last.id, 'm2');
      final listCall = adapter.captured.firstWhere(
        (o) => !o.uri.path.contains('/messages/'),
      );
      expect(listCall.uri.toString(), '$_gmailBase/messages?maxResults=2');
      expect(listCall.method, 'GET');
    });

    test('listMessages keeps empty results as an empty list', () async {
      final adapter = _RecordingAdapter(
        (_) => _ok({'messages': null, 'resultSizeEstimate': 0}),
      );
      final repo = await _repository(adapter);
      expect(await repo.listMessages(), isEmpty);
    });

    test('search sends the Gmail q parameter and returns summaries', () async {
      final adapter = _RecordingAdapter((options) {
        final url = options.uri.toString();
        if (url.contains('$_gmailBase/messages?')) {
          return _ok({
            'messages': [
              {'id': 's1', 'threadId': 't1'},
            ],
          });
        }
        return _ok(
          _metadataFixture(
            id: 's1',
            from: 'carol@example.org',
            subject: 'party friday',
            internalDate: '726305700000',
            snippet: 'bring snacks',
          ),
        );
      });
      final repo = await _repository(adapter);

      final result = await repo.search('from:carol party', limit: 5);

      expect(result, hasLength(1));
      expect(result.first.subject, 'party friday');
      final searchCall = adapter.captured.first;
      expect(
        searchCall.uri.queryParameters,
        containsPair('q', 'from:carol party'),
      );
      expect(searchCall.uri.queryParameters, containsPair('maxResults', '5'));
    });

    test(
      'readMessage decodes the base64url plain-text part and headers',
      () async {
        final adapter = _RecordingAdapter(
          (options) => _ok(
            _fullFixture(
              subject: 'Welcome to the crew',
              fromHeader: 'Alice <alice@example.org>',
              bodyText: 'Hello there — welcome aboard.',
              internalDate: '726305700000',
            ),
          ),
        );
        final repo = await _repository(adapter);

        final message = await repo.readMessage('m1');

        expect(message.id, 'm1');
        expect(message.subject, 'Welcome to the crew');
        expect(message.from, 'Alice <alice@example.org>');
        expect(message.body, 'Hello there — welcome aboard.');
        expect(message.dateMs, 726305700000);
      },
    );

    test(
      'readMessage falls back to the snippet when no text part exists',
      () async {
        final adapter = _RecordingAdapter(
          (options) => _ok({
            'id': 'm9',
            'threadId': 't9',
            'snippet': 'Fallback text here',
            'internalDate': '1',
            'payload': {
              'headers': [
                {'name': 'Subject', 'value': 'Newsletter'},
                {'name': 'From', 'value': 'news@example.org'},
              ],
              'mimeType': 'multipart/mixed',
              'parts': [
                {
                  'mimeType': 'image/png',
                  'body': {'data': 'aGk='},
                },
              ],
            },
          }),
        );
        final repo = await _repository(adapter);

        final message = await repo.readMessage('m9');

        expect(message.body, 'Fallback text here');
      },
    );

    test(
      'readMessage picks the text/plain part out of multipart structures',
      () async {
        final adapter = _RecordingAdapter(
          (options) => _ok({
            'id': 'm10',
            'threadId': 't10',
            'snippet': 'unused',
            'payload': {
              'headers': [
                {'name': 'Subject', 'value': 'multipart'},
                {'name': 'From', 'value': 'multi@example.org'},
              ],
              'mimeType': 'multipart/alternative',
              'parts': [
                {
                  'mimeType': 'text/html',
                  'body': {'data': _b64('<p>rich</p>')},
                },
                {
                  'mimeType': 'multipart/alternative',
                  'parts': [
                    {
                      'mimeType': 'text/plain',
                      'body': {'data': _b64('plain inside nested')},
                    },
                  ],
                },
              ],
            },
          }),
        );
        final repo = await _repository(adapter);

        final message = await repo.readMessage('m10');

        expect(message.body, 'plain inside nested');
      },
    );
  });

  group('GmailRepository — send', () {
    test('posts a base64url RFC822 raw message to the send endpoint', () async {
      final adapter = _RecordingAdapter(
        (_) => _ok({
          'id': 'sent-id-1',
          'threadId': 't1',
          'labelIds': ['SENT'],
        }),
      );
      final repo = await _repository(adapter);

      final id = await repo.send(
        'bob@example.com',
        'Signed contract',
        'Attached the scanned contract.\n\n— Alice',
      );

      expect(id, 'sent-id-1');
      expect(
        adapter.captured.single.uri.toString(),
        '$_gmailBase/messages/send',
      );
      expect(adapter.captured.single.method, 'POST');
      expect(adapter.capturedBodies, hasLength(1));
      final envelope =
          jsonDecode(adapter.capturedBodies.single) as Map<String, dynamic>;
      final raw = envelope['raw'] as String;
      final rfc822 = utf8.decode(base64Url.decode(raw));
      expect(rfc822, contains('To: bob@example.com'));
      expect(rfc822, contains('Subject: Signed contract'));
      expect(rfc822, contains('Content-Type: text/plain; charset="UTF-8"'));
      expect(
        rfc822.substring(rfc822.indexOf('\r\n\r\n') + 4),
        'Attached the scanned contract.\n\n— Alice',
      );
    });

    test('buildGmailRawMessage keeps the body verbatim after headers', () {
      final raw = buildGmailRawMessage(
        to: 'bob@example.com',
        subject: 'Line: breaks? & symbols',
        body: 'first\nsecond',
      );
      expect(
        raw.startsWith(
          'To: bob@example.com\r\n'
          'Subject: Line: breaks? & symbols\r\n'
          'MIME-Version: 1.0\r\n'
          'Content-Type: text/plain; charset="UTF-8"\r\n'
          '\r\n'
          'first\nsecond',
        ),
        isTrue,
      );
    });
  });

  group('GmailRepository — tokens and errors', () {
    test('sends the stored bearer token on API calls', () async {
      final adapter = _RecordingAdapter(
        (_) => _ok({'messages': null, 'resultSizeEstimate': 0}),
      );
      final repo = await _repository(adapter);

      await repo.listMessages();

      expect(adapter.captured, isNotEmpty);
      for (final request in adapter.captured) {
        expect(request.headers['Authorization'], 'Bearer token-xyz');
      }
    });

    test(
      're-provisions silently from the gateway when the store is empty',
      () async {
        final adapter = _RecordingAdapter(
          (_) => _ok({'messages': null, 'resultSizeEstimate': 0}),
        );
        final store = InMemoryMailTokenStore();
        final gateway = _CannedGateway(
          GoogleToken(
            accessToken: 'fresh-token',
            email: 'alice@example.org',
            expiry: DateTime.parse(_farFuture),
          ),
        );
        final repo = await _repository(
          adapter,
          tokens: store,
          gateway: gateway,
        );

        await repo.listMessages();

        expect(gateway.silentCalls, 1);
        expect(
          await store.accessToken(MailProvider.gmail, 'alice@example.org'),
          'fresh-token',
        );
      },
    );

    test(
      'a store miss with no silent token surfaces mail_not_authenticated',
      () async {
        final adapter = _RecordingAdapter((_) => _ok({'messages': []}));
        final gateway = _CannedGateway(null);
        final repo = await _repository(
          adapter,
          tokens: InMemoryMailTokenStore(),
          gateway: gateway,
        );

        try {
          await repo.listMessages();
          fail('expected MailConnectorException');
        } on MailConnectorException catch (e) {
          expect(e.code, 'mail_not_authenticated');
          expect(
            e.message,
            isNot(contains('token-xyz')),
            reason: 'token values must never land in error text',
          );
        }
      },
    );

    test('HTTP 401 maps to mail_not_authenticated', () async {
      final adapter = _RecordingAdapter(
        (options) => ResponseBody.fromString('{"error": "unauthorized"}', 401),
      );
      final repo = await _repository(adapter);

      try {
        await repo.listMessages();
        fail('expected MailConnectorException');
      } on MailConnectorException catch (e) {
        expect(e.code, 'mail_not_authenticated');
      }
    });

    test('HTTP 500 maps to mail_request_failed', () async {
      final adapter = _RecordingAdapter(
        (options) => ResponseBody.fromString('boom', 500),
      );
      final repo = await _repository(adapter);

      try {
        await repo.search('hello');
        fail('expected MailConnectorException');
      } on MailConnectorException catch (e) {
        expect(e.code, 'mail_request_failed');
      }
    });

    test('an empty recipient rejects before any HTTP call', () async {
      final adapter = _RecordingAdapter((_) => _ok({'id': 'x'}));
      final repo = await _repository(adapter);

      try {
        await repo.send('  ', 'subject', 'body');
        fail('expected MailConnectorException');
      } on MailConnectorException catch (e) {
        expect(e.code, 'mail_invalid_args');
        expect(adapter.captured, isEmpty);
      }
    });
  });
}

Map<String, dynamic> _metadataFixture({
  required String id,
  required String from,
  required String subject,
  required String internalDate,
  required String snippet,
  String threadId = 't-thread',
}) {
  return {
    'id': id,
    'threadId': threadId,
    'snippet': snippet,
    'internalDate': internalDate,
    'payload': {
      'headers': [
        {'name': 'From', 'value': from},
        {'name': 'Subject', 'value': subject},
        {'name': 'Date', 'value': 'Mon, 1 Jan 2026 00:00:00 +0000'},
      ],
    },
  };
}

Map<String, dynamic> _fullFixture({
  required String subject,
  required String fromHeader,
  required String bodyText,
  required String internalDate,
}) {
  return {
    'id': 'm1',
    'threadId': 't1',
    'snippet': bodyText,
    'internalDate': internalDate,
    'payload': {
      'mimeType': 'text/plain',
      'headers': [
        {'name': 'From', 'value': fromHeader},
        {'name': 'Subject', 'value': subject},
      ],
      'body': {'data': _b64(bodyText)},
    },
  };
}

String _b64(String text) => base64Url.encode(utf8.encode(text));
