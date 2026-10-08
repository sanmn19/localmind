import 'dart:async';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart';

import 'imap_repository.dart';
import 'mail_common.dart';

/// The real [ImapWorker] over enough_mail's low-level [ImapClient] and
/// [SmtpClient]. One session per connect: IMAP login + inbox selection; the
/// SMTP connection is established per send from the derived `smtp.*` host
/// of the connected IMAP host and torn down right after dispatch.
class EnoughMailWorker implements ImapWorker {
  ImapClient? _imap;
  SmtpClient _smtp = SmtpClient(_heloDomain, isLogEnabled: false);
  String? _user;
  String? _password;
  String? _smtpHost;
  int _smtpPort;

  EnoughMailWorker() : _smtpPort = 465;

  static const _heloDomain = 'enough.mail.client';
  static const _listCriteria =
      '(FLAGS UID INTERNALDATE '
      'BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE)] BODY.PEEK[TEXT])';
  static const _fullCriteria =
      '(FLAGS UID INTERNALDATE '
      'BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE)] BODY.PEEK[])';
  static const _snippetMax = 400;
  static const _searchRowCap = 100;

  @override
  Future<void> connect(
    String host,
    int port,
    String user,
    String password,
  ) async {
    try {
      final imap = ImapClient(isLogEnabled: false);
      await imap.connectToServer(host, port, isSecure: port != 143);
      await imap.login(user, password);
      await imap.selectInbox();
      _imap = imap;
      _user = user;
      _password = password;
      _smtpHost = _smtpHostFor(host);
      _smtpPort = port == 143 ? 587 : 465;
    } on ImapException catch (error) {
      throw MailConnectorException(
        mailNotAuthenticatedCode,
        'sign-in failed — check or re-enter the app password (${error.message})',
      );
    } on SocketException catch (error) {
      throw MailConnectorException(
        mailRequestFailedCode,
        'could not connect to $host:$port (${error.message})',
      );
    } on TimeoutException {
      throw MailConnectorException(
        mailRequestFailedCode,
        'could not connect to $host:$port (timed out)',
      );
    }
  }

  /// Derives the SMTP host from the IMAP host by swapping the first label
  /// for `smtp.` when it maps the incoming service (imap./in./mail.).
  static String _smtpHostFor(String host) {
    final normalized = host.trim().toLowerCase();
    for (final prefix in const ['imap.', 'in.', 'mail.']) {
      if (normalized.startsWith(prefix)) {
        return 'smtp.${normalized.substring(prefix.length)}';
      }
    }
    if (normalized.startsWith('smtp.')) return normalized;
    return normalized;
  }

  @override
  Future<List<MailMessageSummary>> listRecent({
    required String? query,
    required int limit,
  }) async {
    final imap = _requireImap();
    final trimmed = query?.trim();
    FetchImapResult result;
    if (trimmed == null || trimmed.isEmpty) {
      result = await imap.fetchRecentMessages(
        messageCount: limit,
        criteria: _listCriteria,
      );
    } else {
      final matching = await imap.searchMessages(
        searchCriteria: _searchCriteria(trimmed),
      );
      var ids = matching.matchingSequence?.toList() ?? const <int>[];
      if (ids.length > _searchRowCap) ids = ids.sublist(_searchRowCap * -1);
      if (ids.length > limit) ids = ids.sublist(ids.length - limit);
      if (ids.isEmpty) return const [];
      result = await imap.fetchMessages(
        MessageSequence.fromIds(ids),
        _listCriteria,
      );
    }
    return [for (final message in result.messages) _summaryFrom(message)];
  }

  @override
  Future<MailMessage> fetchBody(String id) async {
    final imap = _requireImap();
    final uid = _uidOf(id);
    if (uid == null) {
      throw MailConnectorException(
        mailInvalidArgsCode,
        "not an IMAP message id: '$id' — use ids from mail.list_messages",
      );
    }
    final result = await imap.uidFetchMessage(uid, _fullCriteria);
    if (result.messages.isEmpty) {
      throw MailConnectorException(
        mailRequestFailedCode,
        'message $id not found in the inbox',
      );
    }
    return _messageFrom(id, result.messages.first);
  }

  @override
  Future<String> smtpSend(String to, String subject, String body) async {
    // Asserts the inbox session is still alive before touching SMTP.
    _requireImap();
    final user = _user;
    final password = _password;
    final smtpHost = _smtpHost;
    if (user == null || password == null || smtpHost == null) {
      throw MailConnectorException(
        mailNotAuthenticatedCode,
        'the IMAP session ended — retry the request to reconnect',
      );
    }
    try {
      await _smtp.connectToServer(
        smtpHost,
        _smtpPort,
        isSecure: _smtpPort != 587,
      );
      await _smtp.ehlo();
      if (_smtp.serverInfo.supportsAuth(AuthMechanism.plain)) {
        await _smtp.authenticate(user, password, AuthMechanism.plain);
      } else {
        await _smtp.authenticate(user, password, AuthMechanism.login);
      }
      final recipient = MailAddress(to.trim(), to.trim());
      final message = MessageBuilder.buildSimpleTextMessage(
        MailAddress(user, user),
        [recipient],
        body,
        subject: subject,
      );
      final report = await _smtp.sendMessage(message);
      if (!report.isOkStatus) {
        throw MailConnectorException(
          mailRequestFailedCode,
          'SMTP send failed (${report.message})',
        );
      }
      return 'imap-${DateTime.now().millisecondsSinceEpoch}';
    } on SmtpException catch (error) {
      throw MailConnectorException(
        mailRequestFailedCode,
        'SMTP send to $smtpHost failed (${error.message})',
      );
    } finally {
      try {
        await _smtp.disconnect();
      } catch (_) {}
      // The SmtpClient instance is not re-usable across sends safely;
      // rebuild it for the next one while the inbox session keeps running.
      _smtp = SmtpClient(_heloDomain, isLogEnabled: false);
    }
  }

  @override
  Future<void> release() async {
    try {
      final imap = _imap;
      if (imap != null && imap.isLoggedIn) {
        await imap.logout();
      }
    } catch (_) {
    } finally {
      try {
        await _imap?.disconnect();
      } catch (_) {}
      _imap = null;
      _user = null;
      _password = null;
      _smtpHost = null;
    }
  }

  ImapClient _requireImap() {
    final imap = _imap;
    if (imap == null || !imap.isLoggedIn) {
      throw MailConnectorException(
        mailNotAuthenticatedCode,
        'the IMAP session ended — retry the request to reconnect',
      );
    }
    return imap;
  }

  static int? _uidOf(String id) {
    final raw = id.startsWith('imap:') ? id.substring(5) : id;
    final uid = int.tryParse(raw.trim());
    return uid == null || uid <= 0 ? null : uid;
  }

  /// Renders the official-ish IMAP SEARCH criteria out of the plain query:
  /// `from:carol subject:invoice` becomes `FROM "carol" SUBJECT "invoice"`,
  /// every remaining word searches TEXT (headers + body). Quoted fragments
  /// stay multi-word needles.
  static String _searchCriteria(String query) {
    final segments = <String>[];
    final operators = RegExp(
      r'(from|subject|to|text):(?:"([^"]+)"|(\S+))',
      caseSensitive: false,
    );
    var rest = query;
    for (final match in operators.allMatches(query)) {
      final field = match.group(1)!.toUpperCase();
      final value = match.group(2) ?? match.group(3) ?? '';
      if (value.trim().isNotEmpty) {
        segments.add('$field "${value.trim().replaceAll('"', '')}"');
      }
      rest = rest.replaceFirst(match.group(0)!, ' ');
    }
    for (final word in rest.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      segments.add('TEXT "${word.replaceAll('"', '')}"');
    }
    return segments.isEmpty ? 'ALL' : segments.join(' ');
  }

  static MailMessageSummary _summaryFrom(MimeMessage message) {
    final identifier = 'imap:${message.uid ?? message.sequenceId ?? 0}';
    final snippet = message.decodeTextPlainPart() ?? '';
    return MailMessageSummary(
      id: identifier,
      threadId: identifier,
      snippet: _clip(snippet.trim().replaceAll(RegExp(r'\s+'), ' ')),
      from: message.decodeHeaderValue('from'),
      subject: message.decodeSubject(),
      dateMs: message.decodeDate()?.toUtc().millisecondsSinceEpoch,
    );
  }

  static MailMessage _messageFrom(String id, MimeMessage message) {
    final identifier = 'imap:${message.uid ?? message.sequenceId ?? 0}';
    final snippet = message.decodeTextPlainPart() ?? '';
    return MailMessage(
      id: message.uid != null ? identifier : id,
      threadId: identifier,
      snippet: _clip(snippet.trim().replaceAll(RegExp(r'\s+'), ' ')),
      body: snippet,
      from: message.decodeHeaderValue('from'),
      subject: message.decodeSubject(),
      dateMs: message.decodeDate()?.toUtc().millisecondsSinceEpoch,
    );
  }

  static String _clip(String text) {
    if (text.length <= _snippetMax) return text;
    return '${text.substring(0, _snippetMax)}…';
  }
}
