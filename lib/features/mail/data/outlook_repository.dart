// ignore_for_file: prefer_initializing_formals
import 'package:dio/dio.dart';

import 'mail_common.dart';
import 'mail_token_store.dart';
import 'outlook_auth_client.dart';

/// Microsoft Graph mail endpoints for one connected personal account.
/// Tokens resolve store → silent gateway; auth failures surface as
/// structured connector codes without leaking token material.
class OutlookRepository implements MailMessageApi {
  OutlookRepository({
    required this.accountEmail,
    required Dio dio,
    required MailTokenStore tokens,
    required OutlookAuthGateway gateway,
  }) : _dio = dio,
       _tokens = tokens,
       _gateway = gateway;

  static const _base = 'https://graph.microsoft.com/v1.0/me';

  final String accountEmail;
  final Dio _dio;
  final MailTokenStore _tokens;
  final OutlookAuthGateway _gateway;

  Future<String> _token() async {
    final stored = await _tokens.accessToken(
      MailProvider.outlook,
      accountEmail,
    );
    if (stored != null) return stored;

    final provisioned = await _gateway.silentToken();
    if (provisioned != null) {
      await _tokens.updateToken(
        MailProvider.outlook,
        provisioned.email,
        provisioned.accessToken,
        provisioned.expiry,
      );
      return provisioned.accessToken;
    }
    throw const MailConnectorException(
      mailNotAuthenticatedCode,
      'mail account is not connected — reconnect in the settings screen',
    );
  }

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, String> query,
  ) async {
    final token = await _token();
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$_base/$path',
        queryParameters: query,
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return response.data ?? const {};
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        await _tokens.clear(MailProvider.outlook, accountEmail);
        throw const MailConnectorException(
          mailNotAuthenticatedCode,
          'mail account is not connected — reconnect in the settings screen',
        );
      }
      throw MailConnectorException(
        mailRequestFailedCode,
        'Graph request failed (HTTP ${status ?? 'network error'})',
      );
    }
  }

  static String? _senderAddressMap(Map message) {
    final addressContainer = message['emailAddress'];
    if (addressContainer is Map) return addressContainer['address']?.toString();
    return null;
  }

  static String? _senderAddress(Map<String, dynamic> message) {
    final from = message['from'];
    if (from is Map) return _senderAddressMap(from);
    final sender = message['sender'];
    if (sender is Map) return _senderAddressMap(sender);
    return null;
  }

  MailMessageSummary _summaryFromGraph(Map<String, dynamic> message) {
    final from = message['from'];
    final sender = message['sender'];
    final address = (from is Map
        ? from
        : sender as Map?)?['emailAddress']?['address'];
    final received = message['receivedDateTime']?.toString();
    final dateMs = received == null
        ? null
        : DateTime.tryParse(received)?.toUtc().millisecondsSinceEpoch;
    return MailMessageSummary(
      id: message['id']?.toString() ?? '',
      threadId: message['conversationId']?.toString() ?? '',
      snippet: message['bodyPreview']?.toString() ?? '',
      from: address is String ? address : null,
      subject: message['subject']?.toString(),
      dateMs: dateMs,
    );
  }

  @override
  Future<List<MailMessageSummary>> listMessages({
    String? query,
    int limit = 10,
  }) async {
    if (query != null && query.trim().isNotEmpty) {
      // Graph's $search only works with POST /search on messages...
      // GET with $search is valid on mailFolders when using beta...
      // v1: GET /messages?$search (supported for messages in v1.0).
      final result = await _get('messages', {
        r'$search': '"${query.trim()}"',
        r'$top': '$limit',
        r'$select':
            'id,conversationId,subject,bodyPreview,from,sender,receivedDateTime',
      });
      return _summaries(result);
    }
    final result = await _get('mailFolders/Inbox/messages', {
      r'$top': '$limit',
      r'$select':
          'id,conversationId,subject,bodyPreview,from,sender,receivedDateTime',
      r'$orderby': 'receivedDateTime desc',
    });
    return _summaries(result);
  }

  List<MailMessageSummary> _summaries(Map<String, dynamic> result) {
    final value = result['value'];
    if (value is! List) return const [];
    return <MailMessageSummary>[
      for (final entry in value)
        if (entry is Map<String, dynamic>) _summaryFromGraph(entry),
    ];
  }

  @override
  Future<MailMessage> readMessage(String id) async {
    final message = await _get(id, {});
    final body = message['body'];
    final text = body is Map && body['content'] is String
        ? body['content'] as String
        : message['bodyPreview']?.toString() ?? '';
    return MailMessage(
      id: message['id']?.toString() ?? id,
      threadId: message['conversationId']?.toString() ?? '',
      snippet: message['bodyPreview']?.toString() ?? '',
      body: text,
      from: _senderAddress(message),
      subject: message['subject']?.toString(),
      dateMs: message['receivedDateTime'] == null
          ? null
          : DateTime.tryParse(
              message['receivedDateTime'].toString(),
            )?.toUtc().millisecondsSinceEpoch,
    );
  }

  @override
  Future<List<MailMessageSummary>> search(String query, {int limit = 10}) {
    return listMessages(query: query, limit: limit);
  }

  @override
  Future<String> send(String to, String subject, String body) async {
    if (to.trim().isEmpty) {
      throw const MailConnectorException(
        mailInvalidArgsCode,
        'send requires a recipient address',
      );
    }
    final token = await _token();
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$_base/sendMail',
        data: {
          'message': {
            'subject': subject,
            'body': {'contentType': 'Text', 'content': body},
            'toRecipients': [
              {
                'emailAddress': {'address': to.trim()},
              },
            ],
          },
          'saveToSentItems': true,
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      // Graph sendMail answers 202 Accepted with no body.
      return 'outlook-${DateTime.now().millisecondsSinceEpoch}-'
          '${response.statusCode ?? 202}';
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        await _tokens.clear(MailProvider.outlook, accountEmail);
        throw const MailConnectorException(
          mailNotAuthenticatedCode,
          'mail account is not connected — reconnect in the settings screen',
        );
      }
      throw MailConnectorException(
        mailRequestFailedCode,
        'Outlook send failed (HTTP ${status ?? 'network error'})',
      );
    }
  }
}
