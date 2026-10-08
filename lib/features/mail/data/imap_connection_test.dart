import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'imap_repository.dart';
import 'mail_common.dart';
import 'mail_token_store.dart';

/// One-shot connect validation backing the mail-connect form: verifies the
/// e-mail + app-password pair against the real server before anything is
/// persisted. Returns null when a live read proves the credentials; a
/// model-readable failure message otherwise.
abstract class ImapConnectProbe {
  Future<String?> verify({
    required String email,
    required String password,
    String? host,
  });
}

/// The real probe: a throw-away [ImapRepository] pinning the candidate
/// password in a probe-local store, then attempting `listMessages(limit: 1)`
/// through the genuine enough_mail worker.
class EnoughMailConnectProbe implements ImapConnectProbe {
  const EnoughMailConnectProbe();

  @override
  Future<String?> verify({
    required String email,
    required String password,
    String? host,
  }) async {
    final pins = InMemoryMailTokenStore();
    await pins.updateToken(
      MailProvider.imap,
      email,
      password,
      DateTime.now().add(const Duration(minutes: 2)),
    );
    final override = host?.trim();
    final repo = ImapRepository(
      accountEmail: email,
      tokens: pins,
      hostOverride: (override == null || override.isEmpty) ? null : override,
    );
    try {
      await repo.listMessages(limit: 1);
      return null;
    } on MailConnectorException catch (error) {
      return error.message;
    } finally {
      await repo.release();
    }
  }
}

/// Overridable so widget tests never touch a real IMAP server.
final imapConnectProbeProvider = Provider<ImapConnectProbe>((ref) {
  return const EnoughMailConnectProbe();
});
