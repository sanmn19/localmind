import 'package:flutter/foundation.dart';

/// Supported mail connector providers (Tier 2 of the device/mail feature).
enum MailProvider { gmail, outlook }

enum MailProviderStatus { unconfigured, notConnected, connected }

class MailProviderName {
  const MailProviderName._();

  static const gmail = 'gmail';
  static const outlook = 'outlook';

  static MailProvider fromName(String? name) =>
      name == outlook ? MailProvider.outlook : MailProvider.gmail;

  static String? nameOf(MailProvider provider) => switch (provider) {
    MailProvider.gmail => gmail,
    MailProvider.outlook => outlook,
  };
}

/// A connector account row: provider + account email. Persisted in app
/// settings as a list of maps; tokens stay with the provider SDKs'
/// platform caches plus the token store — never in here.
class MailAccount {
  const MailAccount({required this.provider, required this.email});

  factory MailAccount.fromMap(Map<String, dynamic> map) {
    return MailAccount(
      provider: MailProviderName.fromName(map['provider']?.toString()),
      email: map['email']?.toString() ?? '',
    );
  }

  final MailProvider provider;
  final String email;

  MailAccount copyWith({MailProvider? provider, String? email}) => MailAccount(
    provider: provider ?? this.provider,
    email: email ?? this.email,
  );

  Map<String, dynamic> toMap() => {
    'provider': MailProviderName.nameOf(provider),
    'email': email,
  };

  @override
  bool operator ==(Object other) =>
      other is MailAccount &&
      other.provider == provider &&
      other.email == email;

  @override
  int get hashCode => Object.hash(provider, email);
}

/// Stable failure codes across the mail connectors.
const mailNotAuthenticatedCode = 'mail_not_authenticated';
const mailRequestFailedCode = 'mail_request_failed';
const mailInvalidArgsCode = 'mail_invalid_args';
const mailConnectorMisconfiguredCode = 'mail_connector_misconfigured';

class MailConnectorException implements Exception {
  const MailConnectorException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'MailConnectorException($code): $message';
}

/// One mail message, fully read: headers + decoded body text.
class MailMessage {
  const MailMessage({
    required this.id,
    required this.threadId,
    required this.snippet,
    required this.body,
    this.from,
    this.subject,
    this.dateMs,
  });

  final String id;
  final String threadId;
  final String snippet;
  final String body;
  final String? from;
  final String? subject;
  final int? dateMs;
}

/// A list/search row: enough to render the stack without the body.
class MailMessageSummary {
  const MailMessageSummary({
    required this.id,
    required this.threadId,
    this.snippet = '',
    this.from,
    this.subject,
    this.dateMs,
  });

  final String id;
  final String threadId;
  final String snippet;
  final String? from;
  final String? subject;
  final int? dateMs;

  MailMessageSummary copyWith({String? threadId}) => MailMessageSummary(
    id: id,
    threadId: threadId ?? this.threadId,
    snippet: snippet,
    from: from,
    subject: subject,
    dateMs: dateMs,
  );
}

/// The contract the MCP server dispatches mail tools against. The Gmail
/// (and later Outlook) repositories implement it; the server only knows
/// the active account's repository.
abstract class MailMessageApi {
  Future<List<MailMessageSummary>> listMessages({
    String? query,
    int limit = 10,
  });

  Future<MailMessage> readMessage(String id);

  Future<List<MailMessageSummary>> search(String query, {int limit = 10});

  /// Performs the actual send; approvals live at the tool layer.
  Future<String> send(String to, String subject, String body);
}

@immutable
class MailConnectionState {
  const MailConnectionState({
    required this.provider,
    required this.email,
    required this.isConnected,
  });

  final MailProvider provider;
  final String email;
  final bool isConnected;
}
