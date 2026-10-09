import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/theme/app_theme.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/mail/data/imap_connection_test.dart';
import 'package:localmind/features/mail/data/mail_common.dart';
import 'package:localmind/features/mail/data/mail_token_store.dart';
import 'package:localmind/features/mcp/views/mcp_tools_screen.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/l10n/app_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<(ProviderContainer, _SpySettingsNotifier)> pumpCardsHarness(
    WidgetTester tester, {
    bool deviceToolsEnabled = false,
    bool shareTargetEnabled = true,
    List<Map<String, dynamic>> mailConnectorAccounts = const [],
    _RecordingProbe? probe,
    InMemoryMailTokenStore? tokens,
  }) async {
    // The test font draws every glyph a full em wide; give rows room.
    tester.view.physicalSize = const Size(700, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final spy = _SpySettingsNotifier(
      initialDeviceTools: deviceToolsEnabled,
      initialShareTarget: shareTargetEnabled,
      mailAccounts: mailConnectorAccounts,
    );
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        packageInfoProvider.overrideWith(
          (ref) async => PackageInfo(
            appName: 'LocalMind',
            packageName: 'test',
            version: '1.0.0',
            buildNumber: '1',
          ),
        ),
        settingsProvider.overrideWith(() => spy),
        availableToolsProvider.overrideWith((ref) => Future.value(const [])),
        if (probe != null) imapConnectProbeProvider.overrideWithValue(probe),
        if (tokens != null) mailTokenStoreProvider.overrideWithValue(tokens),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadTheme(
          data: AppTheme.lightShadTheme,
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: McpToolsScreen()),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return (container, spy);
  }

  testWidgets('device card toggle flips deviceToolsEnabled via the settings '
      'notifier and gates the share sub-toggle', (tester) async {
    final (container, spy) = await pumpCardsHarness(tester);
    await tester.pumpAndSettle();

    expect(find.text('Device'), findsOneWidget);
    expect(spy.setDeviceToolsEnabledCalls, isEmpty);

    // Share sub-toggle sits behind the disabled main toggle: tap ignored.
    await tester.tap(
      find.byKey(const Key('share_target_toggle')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(spy.setShareTargetEnabledCalls, isEmpty);

    await tester.tap(find.byKey(const Key('device_tools_toggle')));
    await tester.pumpAndSettle();

    expect(spy.setDeviceToolsEnabledCalls, contains(true));
    expect(
      container.read(settingsProvider).deviceToolsEnabled,
      isTrue,
      reason: 'spy settings notifier must hold deviceToolsEnabled: true',
    );

    // Main toggle on → the share sub-toggle becomes interactive.
    await tester.tap(find.byKey(const Key('share_target_toggle')));
    await tester.pumpAndSettle();

    expect(spy.setShareTargetEnabledCalls, contains(false));
    expect(
      container.read(settingsProvider).shareTargetEnabled,
      isFalse,
      reason: 'spy settings notifier must hold shareTargetEnabled: false',
    );
  });

  testWidgets('mail connector rows render connect actions without accounts '
      'and the connected email with one', (tester) async {
    final (_, spy) = await pumpCardsHarness(
      tester,
      mailConnectorAccounts: const [
        {'provider': 'gmail', 'email': 'x@y.z'},
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('Mail connectors'), findsOneWidget);

    // Gmail row shows the connected account, not a connect action…
    expect(find.text('Connected: x@y.z'), findsOneWidget);
    expect(find.text('Connect Gmail'), findsNothing);

    // …Outlook has no account yet, so it still offers connecting…
    expect(find.text('Connect Outlook'), findsOneWidget);

    // …and exactly one disconnect action exists behind the connected row.
    expect(find.text('Disconnect'), findsOneWidget);
    expect(spy.setMailConnectorAccountsCalls, isEmpty);
  });

  testWidgets('the imap connect form validates empty input without probing', (
    tester,
  ) async {
    final probe = _RecordingProbe();
    final (_, spy) = await pumpCardsHarness(tester, probe: probe);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('imap_email_input')), findsOneWidget);
    expect(find.byKey(const Key('imap_password_input')), findsOneWidget);
    expect(find.byKey(const Key('imap_host_input')), findsOneWidget);
    expect(find.text('Connect IMAP account'), findsOneWidget);

    await tester.tap(find.byKey(const Key('imap_connect_button')));
    await tester.pumpAndSettle();

    expect(
      probe.calls,
      isEmpty,
      reason: 'an empty form must not trigger any connection attempt',
    );
    expect(spy.setMailConnectorAccountsCalls, isEmpty);
  });

  testWidgets('a failing validation toasts the error and saves no row', (
    tester,
  ) async {
    final probe = _RecordingProbe(
      failure: 'sign-in failed — check or re-enter the app password',
    );
    final (_, spy) = await pumpCardsHarness(tester, probe: probe);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('imap_email_input')),
      'bob@example.org',
    );
    await tester.enterText(
      find.byKey(const Key('imap_password_input')),
      'app-password-abc',
    );
    await tester.enterText(
      find.byKey(const Key('imap_host_input')),
      'imap.example.org',
    );
    await tester.tap(find.byKey(const Key('imap_connect_button')));
    await tester.pumpAndSettle();

    expect(probe.calls.single.email, 'bob@example.org');
    expect(probe.calls.single.password, 'app-password-abc');
    expect(probe.calls.single.host, 'imap.example.org');
    expect(find.textContaining('re-enter the app password'), findsOneWidget);
    expect(spy.setMailConnectorAccountsCalls, isEmpty);
  });

  testWidgets('a successful validation stores the row and the app password', (
    tester,
  ) async {
    final probe = _RecordingProbe();
    final tokens = InMemoryMailTokenStore();
    final (container, spy) = await pumpCardsHarness(
      tester,
      probe: probe,
      tokens: tokens,
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('imap_email_input')),
      'bob@example.org',
    );
    await tester.enterText(
      find.byKey(const Key('imap_password_input')),
      'app-password-abc',
    );
    await tester.tap(find.byKey(const Key('imap_connect_button')));
    await tester.pumpAndSettle();

    expect(
      probe.calls.single.host,
      isNull,
      reason: 'the host field is optional — auto-resolution applies',
    );
    final calls = spy.setMailConnectorAccountsCalls;
    expect(calls, hasLength(1));
    final savedRow = calls.single.single;
    expect(savedRow['provider'], 'imap');
    expect(savedRow['email'], 'bob@example.org');
    expect(
      await tokens.accessToken(MailProvider.imap, 'bob@example.org'),
      'app-password-abc',
      reason: 'the app password must land in the token store, not settings',
    );
    expect(
      container.read(settingsProvider).mailConnectorAccounts.last['host'],
      isNull,
    );
  });

  testWidgets('a connected imap account shows its row and disconnect '
      'removes it and clears the password', (tester) async {
    final tokens = InMemoryMailTokenStore();
    await tokens.updateToken(
      MailProvider.imap,
      'bob@example.org',
      'app-password-abc',
      DateTime.parse('9999-01-01T00:00:00Z'),
    );
    final (_, spy) = await pumpCardsHarness(
      tester,
      tokens: tokens,
      mailConnectorAccounts: const [
        {'provider': 'imap', 'email': 'bob@example.org'},
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('Connected: bob@example.org'), findsOneWidget);
    expect(find.byKey(const Key('imap_connect_button')), findsNothing);

    await tester.tap(find.text('Disconnect').first);
    await tester.pumpAndSettle();

    final calls = spy.setMailConnectorAccountsCalls;
    expect(calls.last, isEmpty, reason: 'the imap row must be gone');
    expect(
      await tokens.accessToken(MailProvider.imap, 'bob@example.org'),
      isNull,
      reason: 'disconnect must clear the stored app password',
    );
  });
}

class _RecordingProbe implements ImapConnectProbe {
  final String? failure;
  final List<({String email, String password, String? host})> calls = [];

  _RecordingProbe({this.failure});

  @override
  Future<String?> verify({
    required String email,
    required String password,
    String? host,
  }) async {
    calls.add((email: email, password: password, host: host));
    return failure;
  }
}

class _SpySettingsNotifier extends SettingsNotifier {
  _SpySettingsNotifier({
    this.initialDeviceTools = false,
    this.initialShareTarget = true,
    this.mailAccounts = const [],
  });

  final bool initialDeviceTools;
  final bool initialShareTarget;
  final List<Map<String, dynamic>> mailAccounts;

  final setDeviceToolsEnabledCalls = <bool>[];
  final setShareTargetEnabledCalls = <bool>[];
  final setMailConnectorAccountsCalls = <List<Map<String, dynamic>>>[];

  @override
  AppSettings build() => AppSettings(
    mcpEnabled: true,
    newChatMcpEnabled: true,
    deviceToolsEnabled: initialDeviceTools,
    shareTargetEnabled: initialShareTarget,
    mailConnectorAccounts: mailAccounts,
  );

  @override
  void setDeviceToolsEnabled(bool value) {
    setDeviceToolsEnabledCalls.add(value);
    super.setDeviceToolsEnabled(value);
  }

  @override
  void setShareTargetEnabled(bool value) {
    setShareTargetEnabledCalls.add(value);
    super.setShareTargetEnabled(value);
  }

  @override
  void setMailConnectorAccounts(List<Map<String, dynamic>> value) {
    setMailConnectorAccountsCalls.add(value);
    super.setMailConnectorAccounts(value);
  }
}
