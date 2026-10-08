import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/theme/app_theme.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
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
