import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/mail/data/imap_repository.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';

class _MutableSettings extends SettingsNotifier {
  _MutableSettings(this._initial);
  final AppSettings _initial;

  @override
  AppSettings build() => _initial;

  void setSettings(AppSettings next) => state = next;
}

void main() {
  group('webServerRegistrationProvider — the imap mail connector', () {
    test('an imap account row registers the imap repository and leaves the '
        'oauth repos out', () async {
      final manager = McpServerManager();
      final settings = _MutableSettings(
        AppSettings(
          mailConnectorAccounts: [
            {'provider': 'imap', 'email': 'bob@example.org'},
          ],
        ),
      );
      final container = ProviderContainer(
        overrides: [
          mcpServerManagerProvider.overrideWithValue(manager),
          settingsProvider.overrideWith(() => settings),
        ],
      );
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      expect(manager.hasMailServer(), isTrue);
      expect(manager.getServerUrl('Mail'), 'local://mail');
      final services = manager.getMailServices();
      expect(services?.imap, isA<ImapRepository>());
      expect(services?.gmail, isNull);
      expect(services?.outlook, isNull);
      final imapRepo = services!.imap! as ImapRepository;
      expect(imapRepo.accountEmail, 'bob@example.org');
      expect(
        imapRepo.hostOverride,
        isNull,
        reason: 'a row without a host key must auto-resolve',
      );
    });

    test('the row-level host override reaches the repository', () async {
      final manager = McpServerManager();
      final settings = _MutableSettings(
        AppSettings(
          mailConnectorAccounts: [
            {
              'provider': 'imap',
              'email': 'bob@example.org',
              'host': 'imap.custom.dev',
            },
          ],
        ),
      );
      final container = ProviderContainer(
        overrides: [
          mcpServerManagerProvider.overrideWithValue(manager),
          settingsProvider.overrideWith(() => settings),
        ],
      );
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      final imapRepo = manager.getMailServices()?.imap! as ImapRepository;
      expect(imapRepo.hostOverride, 'imap.custom.dev');
    });

    test('gmail and imap accounts register side by side', () async {
      final manager = McpServerManager();
      final settings = _MutableSettings(
        AppSettings(
          mailConnectorAccounts: [
            {'provider': 'gmail', 'email': 'g@gmail.com'},
            {'provider': 'imap', 'email': 'i@example.org'},
          ],
        ),
      );
      final container = ProviderContainer(
        overrides: [
          mcpServerManagerProvider.overrideWithValue(manager),
          settingsProvider.overrideWith(() => settings),
        ],
      );
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      final services = manager.getMailServices();
      expect(services?.gmail, isNotNull);
      expect(services?.imap, isNotNull);
      expect(services?.outlook, isNull);
    });

    test('removing the imap row unregisters the mail server again', () async {
      final manager = McpServerManager();
      final settings = _MutableSettings(
        AppSettings(
          mailConnectorAccounts: [
            {'provider': 'imap', 'email': 'bob@example.org'},
          ],
        ),
      );
      final container = ProviderContainer(
        overrides: [
          mcpServerManagerProvider.overrideWithValue(manager),
          settingsProvider.overrideWith(() => settings),
        ],
      );
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();
      expect(manager.hasMailServer(), isTrue);

      settings.setSettings(AppSettings());
      await pumpEventQueue();
      expect(manager.hasMailServer(), isFalse);
    });
  });
}
