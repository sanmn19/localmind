// ignore_for_file: prefer_initializing_formals
import 'dart:convert';

import 'package:dio/dio.dart';

import 'google_auth_client.dart';
import 'mail_common.dart';
import 'mail_token_store.dart';

/// Builds the RFC822 message Gmail's send endpoint expects (headers + a
/// blank line + verbatim body) and wraps it base64url for the `raw` field.
String buildGmailRawMessage({
  required String to,
  required String subject,
  required String body,
}) {
  final headers = <String, String>{
    'To': to.trim(),
    'Subject': subject,
    'MIME-Version': '1.0',
    'Content-Type': 'text/plain; charset="UTF-8"',
  };
  final buffer = StringBuffer();
  for (final entry in headers.entries) {
    buffer.write('${entry.key}: ${entry.value}\r\n');
  }
  buffer.write('\r\n');
  buffer.write(body);
  return buffer.toString();
}

/// RFC 2045 base64url (Gmail's `-`/`_` alphabet) → UTF-8 text.
String _decodeGmailData(String data) {
  return utf8.decode(
    base64Url.decode(base64Url.normalize(data)),
    allowMalformed: true,
  );
}

String? _headerValue(Iterable<Map<String, dynamic>> headers, String name) {
  for (final header in headers) {
    if (header['name']?.toString().toLowerCase() == name.toLowerCase()) {
      return header['value']?.toString();
    }
  }
  return null;
}

String? _findTextPart(Map<String, dynamic> payload) {
  final mimeType = payload['mimeType']?.toString();
  if (mimeType == 'text/plain') {
    final data = (payload['body'] as Map?)?['data']?.toString();
    if (data != null && data.isNotEmpty) return _decodeGmailData(data);
    return null;
  }
  final parts = payload['parts'];
  if (parts is List) {
    // Depth-first: plain text from any nested part wins.
    for (final part in parts) {
      if (part is! Map<String, dynamic>) continue;
      final found = _findTextPart(part);
      if (found != null) return found;
    }
  }
  return null;
}

/// Gmail REST repository for one connected account. Tokens resolve store →
/// silent gateway; 401/403 responses surface as structured connector codes
/// so tool results stay model-readable without leaking token values.
class GmailRepository implements MailMessageApi {
  GmailRepository({
    required this.accountEmail,
    required Dio dio,
    required MailTokenStore tokens,
    required GoogleAuthGateway gateway,
  }) : _dio = dio,
       _tokens = tokens,
       _gateway = gateway;

  static const _base = 'https://gmail.googleapis.com/gmail/v1/users/me';

  final String accountEmail;
  final Dio _dio;
  final MailTokenStore _tokens;
  final GoogleAuthGateway _gateway;

  Future<String?> _token() async {
    final stored = await _tokens.accessToken(MailProvider.gmail, accountEmail);
    if (stored != null) return stored;

    final provisioned = await _gateway.silentToken();
    if (provisioned != null) {
      await _tokens.updateToken(
        MailProvider.gmail,
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
    String path, {
    Map<String, dynamic>? query,
  }) async {
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
        // The stored token may have been revoked elsewhere; drop it so the
        // next attempt re-provisions silently.
        await _tokens.clear(MailProvider.gmail, accountEmail);
        throw const MailConnectorException(
          mailNotAuthenticatedCode,
          'mail account is not connected — reconnect in the settings screen',
        );
      }
      throw MailConnectorException(
        mailRequestFailedCode,
        'Gmail request failed (HTTP ${status ?? 'network error'})',
      );
    }
  }

  MailMessageSummary _summaryFromMetadata(Map<String, dynamic> message) {
    final payload = message['payload'];
    final headers = <Map<String, dynamic>>[];
    if (payload is Map<String, dynamic> && payload['headers'] is List) {
      headers.addAll(
        (payload['headers'] as List).whereType<Map>().map(
          (h) => h.cast<String, dynamic>(),
        ),
      );
    }
    final internalDate = int.tryParse(
      message['internalDate']?.toString() ?? '',
    );
    return MailMessageSummary(
      id: message['id']?.toString() ?? '',
      threadId: message['threadId']?.toString() ?? '',
      snippet: message['snippet']?.toString() ?? '',
      from: _headerValue(headers, 'From'),
      subject: _headerValue(headers, 'Subject'),
      dateMs: internalDate,
    );
  }

  @override
  Future<List<MailMessageSummary>> listMessages({
    String? query,
    int limit = 10,
  }) async {
    final list = await _get(
      'messages',
      query: {
        'maxResults': '$limit',
        if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
      },
    );
    final entries = list['messages'];
    if (entries is! List) return const [];

    final summaries = <MailMessageSummary>[];
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) continue;
      final id = entry['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final full = await _get('messages/$id');
      final summary = _summaryFromMetadata(full);
      final listedThreadId = entry['threadId']?.toString();
      summaries.add(
        (listedThreadId == null || listedThreadId.isEmpty)
            ? summary
            : summary.copyWith(threadId: listedThreadId),
      );
    }
    return summaries;
  }

  @override
  Future<MailMessage> readMessage(String id) async {
    final message = await _get('messages/$id', query: {'format': 'full'});
    final payload = message['payload'];
    String body = '';
    Map<String, dynamic>? headers;
    if (payload is Map<String, dynamic>) {
      body = _findTextPart(payload) ?? '';
      if (payload['headers'] is List) {
        headers = {'headers': payload['headers']};
      }
    }
    if (body.isEmpty) {
      body = message['snippet']?.toString() ?? '';
    }
    final headerList = (headers?['headers'] as List?)
        ?.whereType<Map>()
        .map((h) => h.cast<String, dynamic>())
        .toList();
    final internalDate = int.tryParse(
      message['internalDate']?.toString() ?? '',
    );
    return MailMessage(
      id: message['id']?.toString() ?? id,
      threadId: message['threadId']?.toString() ?? '',
      snippet: message['snippet']?.toString() ?? '',
      body: body,
      from: headerList == null ? null : _headerValue(headerList, 'From'),
      subject: headerList == null ? null : _headerValue(headerList, 'Subject'),
      dateMs: internalDate,
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
        '$_base/messages/send',
        data: {
          'raw': base64Url.encode(
            utf8.encode(
              buildGmailRawMessage(to: to, subject: subject, body: body),
            ),
          ),
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return response.data?['id']?.toString() ?? '';
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        await _tokens.clear(MailProvider.gmail, accountEmail);
        throw const MailConnectorException(
          mailNotAuthenticatedCode,
          'mail account is not connected — reconnect in the settings screen',
        );
      }
      throw MailConnectorException(
        mailRequestFailedCode,
        'Gmail send failed (HTTP ${status ?? 'network error'})',
      );
    }
  }
}
