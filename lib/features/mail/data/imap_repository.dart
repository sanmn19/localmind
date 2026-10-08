// ignore_for_file: prefer_initializing_formals

import 'imap_worker.dart';
import 'mail_common.dart';
import 'mail_token_store.dart';

/// Resolved server endpoints for an IMAP/SMTP e-mail account.
class ImapEndpoints {
  const ImapEndpoints({
    required this.imapHost,
    required this.imapPort,
    required this.smtpHost,
    required this.smtpPort,
  });

  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;
}

/// Domain → documented server hosts. Gmail and a handful of widespread
/// standard providers answer automatically; everything else requires the
/// manual host field of the connect form.
const Map<String, ImapEndpoints> knownImapDomains = {
  'gmail.com': ImapEndpoints(
    imapHost: 'imap.gmail.com',
    imapPort: 993,
    smtpHost: 'smtp.gmail.com',
    smtpPort: 465,
  ),
  'googlemail.com': ImapEndpoints(
    imapHost: 'imap.gmail.com',
    imapPort: 993,
    smtpHost: 'smtp.gmail.com',
    smtpPort: 465,
  ),
  'fastmail.com': ImapEndpoints(
    imapHost: 'imap.fastmail.com',
    imapPort: 993,
    smtpHost: 'smtp.fastmail.com',
    smtpPort: 465,
  ),
  'icloud.com': ImapEndpoints(
    imapHost: 'imap.mail.me.com',
    imapPort: 993,
    smtpHost: 'smtp.mail.me.com',
    smtpPort: 587,
  ),
  'yandex.com': ImapEndpoints(
    imapHost: 'imap.yandex.com',
    imapPort: 993,
    smtpHost: 'smtp.yandex.com',
    smtpPort: 465,
  ),
  'yandex.ru': ImapEndpoints(
    imapHost: 'imap.yandex.com',
    imapPort: 993,
    smtpHost: 'smtp.yandex.com',
    smtpPort: 465,
  ),
  'zoho.com': ImapEndpoints(
    imapHost: 'imap.zoho.com',
    imapPort: 993,
    smtpHost: 'smtp.zoho.com',
    smtpPort: 465,
  ),
};

const Set<String> _microsoftConsumerDomains = {
  'outlook.com',
  'hotmail.com',
  'live.com',
  'msn.com',
};

/// Auto-resolves the server endpoints for the given e-mail domain.
/// Returns null when the domain either belongs to a Microsoft consumer
/// service (no basic auth anymore — the OAuth Outlook connector covers it)
/// or is unknown to the map (the user must fill the manual host field).
ImapEndpoints? resolveImapEndpoints(String domain) {
  final normalized = domain.trim().toLowerCase();
  if (_microsoftConsumerDomains.contains(normalized)) return null;
  return knownImapDomains[normalized];
}

/// The reason [resolveImapEndpoints] returned null for a domain, rendered
/// as the model/user-readable error the repository throws.
String imapHostResolutionError(String domain) {
  final normalized = domain.trim().toLowerCase();
  if (_microsoftConsumerDomains.contains(normalized)) {
    return 'Microsoft removed basic auth for $normalized — connect Outlook '
        'via its OAuth flow instead';
  }
  return "unknown imap host for '$normalized' — set the host manually in "
      'the connect form';
}

/// Splits "alice@example.org" into its e-mail domain (lowercased).
String mailDomainOf(String address) {
  final parts = address.trim().toLowerCase().split('@');
  if (parts.length != 2) return '';
  return parts[1];
}

/// Abstract seam over enough_mail, mirroring how
/// [DeviceContactsService] keeps plugin types out of unit tests: the real
/// implementation lives in `imap_worker.dart`; tests substitute a fake.
abstract class ImapWorker {
  /// Establishes the IMAP session (login + inbox selection).
  Future<void> connect(String host, int port, String user, String password);

  /// Lists up to [limit] recent inbox messages, or the matches of a raw
  /// IMAP SEARCH query fragment (e.g. `FROM "carol"`) when [query] is set.
  Future<List<MailMessageSummary>> listRecent({
    required String? query,
    required int limit,
  });

  /// Fetches one message fully (headers + decoded body) by its numeric id.
  Future<MailMessage> fetchBody(String id);

  /// Sends a plain-text e-mail; returns a synthesized message id.
  Future<String> smtpSend(String to, String subject, String body);

  /// Ends the IMAP session and releases sockets.
  Future<void> release();
}

/// IMAP/SMTP mail repository backed by plain e-mail + app-password
/// credentials (no OAuth): Gmail ships app-passwords, other standard IMAP
/// providers use their normal login. The password lives in the token store
/// keyed by [MailProvider.imap] + account e-mail; hosts auto-resolve from
/// the account domain unless overridden per row. A session is lazily
/// connected on first use and released after [sessionMaxIdle] of inactivity.
class ImapRepository implements MailMessageApi {
  ImapRepository({
    required this.accountEmail,
    required MailTokenStore tokens,
    ImapWorker? worker,
    String? hostOverride,
    this.sessionMaxIdle = const Duration(minutes: 4),
  }) : _tokens = tokens,
       _worker = worker ?? EnoughMailWorker(),
       hostOverride = hostOverride?.trim();

  final String accountEmail;

  /// The connect-form's manual IMAP host — wins over the domain
  /// auto-resolution. Null/empty = auto-resolve from the e-mail domain.
  final String? hostOverride;
  final MailTokenStore _tokens;
  final ImapWorker _worker;
  final Duration sessionMaxIdle;

  bool _connected = false;
  DateTime _lastUsed = DateTime.fromMillisecondsSinceEpoch(0);

  Future<String> _password() async {
    final stored = await _tokens.accessToken(MailProvider.imap, accountEmail);
    if (stored == null) {
      throw MailConnectorException(
        mailNotAuthenticatedCode,
        'no app password stored for $accountEmail — check or re-enter the '
        'app password in the connect form',
      );
    }
    return stored;
  }

  ImapEndpoints _endpoints() {
    final override = hostOverride;
    if (override != null && override.isNotEmpty) {
      return ImapEndpoints(
        imapHost: override,
        imapPort: 993,
        smtpHost: '',
        smtpPort: 465,
      );
    }
    final domain = mailDomainOf(accountEmail);
    final resolved = resolveImapEndpoints(domain);
    if (resolved == null) {
      throw MailConnectorException(
        mailConnectorMisconfiguredCode,
        imapHostResolutionError(domain),
      );
    }
    return resolved;
  }

  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on MailConnectorException {
      rethrow;
    } catch (error) {
      throw MailConnectorException(
        mailRequestFailedCode,
        'IMAP request failed ($error)',
      );
    }
  }

  /// Reuses the connected session while it stayed idle shorter than
  /// [sessionMaxIdle]; otherwise releases the stale one and re-connects.
  Future<void> _ensureSession() async {
    final stillFresh =
        _connected && DateTime.now().difference(_lastUsed) <= sessionMaxIdle;
    if (!stillFresh) {
      if (_connected) {
        _connected = false;
        try {
          await _worker.release();
        } catch (_) {}
      }
      final password = await _password();
      final endpoints = _endpoints();
      await _worker.connect(
        endpoints.imapHost,
        endpoints.imapPort,
        accountEmail,
        password,
      );
      _connected = true;
    }
    _lastUsed = DateTime.now();
  }

  Future<void> release() async {
    if (!_connected) return;
    _connected = false;
    try {
      await _worker.release();
    } catch (_) {}
  }

  @override
  Future<List<MailMessageSummary>> listMessages({
    String? query,
    int limit = 10,
  }) => _guard(() async {
    await _ensureSession();
    final trimmed = query?.trim();
    return _worker.listRecent(
      query: trimmed == null || trimmed.isEmpty ? null : trimmed,
      limit: limit.clamp(1, 100),
    );
  });

  @override
  Future<MailMessage> readMessage(String id) => _guard(() async {
    await _ensureSession();
    return _worker.fetchBody(id.trim());
  });

  @override
  Future<List<MailMessageSummary>> search(String query, {int limit = 10}) {
    return listMessages(query: query, limit: limit);
  }

  @override
  Future<String> send(String to, String subject, String body) =>
      _guard(() async {
        if (to.trim().isEmpty) {
          throw const MailConnectorException(
            mailInvalidArgsCode,
            'send requires a recipient address',
          );
        }
        await _ensureSession();
        final workerId = await _worker.smtpSend(to, subject, body);
        final trimmed = workerId.trim();
        return trimmed.startsWith('imap-') || trimmed.isEmpty
            ? (trimmed.isEmpty
                  ? 'imap-${DateTime.now().millisecondsSinceEpoch}'
                  : trimmed)
            : 'imap-$trimmed';
      });
}
