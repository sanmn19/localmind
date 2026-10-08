import 'data/mail_common.dart';

const mailMcpServerLabel = 'Mail';
const mailMcpServerUrl = 'local://mail';

/// All outputs from mail tools truncate at this length to keep tool
/// results inside reasonable context budgets.
const mailMaxChars = 6000;

class MailServices {
  const MailServices({required this.gmail, this.outlook});

  /// The connected Gmail account's repository (mail.* tools dispatch here
  /// when the account is a gmail one).
  final MailMessageApi gmail;

  /// The connected Outlook account's repository, or null until that
  /// connector lands (Task 6).
  final MailMessageApi? outlook;
}

/// Formats a truncated tool-output string; the [truncatedMarker] tail is
/// what the model sees when it asked for too much.
String mailToolOutput(String body) {
  final trimmed = body.trimRight();
  if (trimmed.length <= mailMaxChars) return trimmed;
  return '${trimmed.substring(0, mailMaxChars)}\n[truncated]';
}

String mailIsoDate(int? dateMs) {
  if (dateMs == null || dateMs <= 0) return '';
  return DateTime.fromMillisecondsSinceEpoch(
    dateMs,
    isUtc: true,
  ).toIso8601String().split('.').first;
}

/// Numbered summary rows for list/search results.
String mailListRender(List<MailMessageSummary> summaries) {
  if (summaries.isEmpty) return 'No matching messages found.';
  final rows = StringBuffer();
  for (final (index, summary) in summaries.indexed) {
    final date = mailIsoDate(summary.dateMs);
    rows
      ..write(
        '${index + 1}. ${summary.from ?? '(unknown sender)'}'
        ' — ${summary.subject ?? '(no subject)'}',
      )
      ..write('\n   ${summary.snippet}');
    if (date.isNotEmpty) rows.write('\n   $date');
    rows.write('\n');
  }
  return rows.toString().trimRight();
}

String mailReadRender(MailMessage message) {
  final header = StringBuffer();
  final date = mailIsoDate(message.dateMs);
  if (message.subject != null) header.write('Subject: ${message.subject}\n');
  if (message.from != null) header.write('From: ${message.from}\n');
  if (date.isNotEmpty) header.write('Date: $date\n');
  return mailToolOutput('${header.toString()}\n${message.body}');
}
