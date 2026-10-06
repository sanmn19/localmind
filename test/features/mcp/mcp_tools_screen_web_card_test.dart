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

  Future<(ProviderContainer, _SpySettingsNotifier)> pumpWebCardHarness(
    WidgetTester tester, {
    bool enabled = false,
  }) async {
    // The test font draws every glyph a full em wide; give rows room.
    tester.view.physicalSize = const Size(700, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final spy = _SpySettingsNotifier(initialEnabled: enabled);
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

  testWidgets('web browser card toggle enables web tools and registers '
      'the web mcp server', (tester) async {
    final (container, spy) = await pumpWebCardHarness(tester);
    await tester.pumpAndSettle();

    expect(find.text('Web Browser'), findsOneWidget);
    expect(spy.setWebToolsEnabledCalls, isEmpty);
    expect(container.read(mcpServerManagerProvider).hasWebServer(), isFalse);

    await tester.tap(find.byKey(const Key('web_tools_toggle')));
    await tester.pumpAndSettle();

    expect(spy.setWebToolsEnabledCalls, contains(true));
    expect(
      container.read(settingsProvider).webToolsEnabled,
      isTrue,
      reason: 'spy settings notifier must hold webToolsEnabled: true',
    );
    expect(
      container.read(mcpServerManagerProvider).hasWebServer(),
      isTrue,
      reason: 'web server must be registered when web tools are enabled',
    );
  });

  testWidgets('changing the search provider updates settings and '
      're-registers the web mcp server with fresh services', (tester) async {
    final (container, spy) = await pumpWebCardHarness(tester, enabled: true);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('web_search_provider_select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tavily').last);
    await tester.pumpAndSettle();

    expect(spy.setWebSearchProviderCalls, contains('tavily'));
    expect(container.read(settingsProvider).webSearchProvider, 'tavily');
    expect(container.read(mcpServerManagerProvider).hasWebServer(), isTrue);
  });

  testWidgets('saving the provider key sets and clears webSearchApiKey', (
    tester,
  ) async {
    final (container, spy) = await pumpWebCardHarness(tester, enabled: true);
    await tester.pumpAndSettle();
    expect(
      container.read(mcpServerManagerProvider).hasWebServer(),
      isTrue,
      reason: 'web server should be registered when the toggle starts on',
    );

    final keyField = find.byKey(const Key('web_search_api_key'));
    await tester.enterText(keyField, 'tavily-secret');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(spy.setWebSearchApiKeyCalls, contains('tavily-secret'));
    expect(container.read(settingsProvider).webSearchApiKey, 'tavily-secret');
    expect(container.read(mcpServerManagerProvider).hasWebServer(), isTrue);

    await tester.enterText(keyField, '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(spy.setWebSearchApiKeyCalls, contains(null));
    expect(container.read(settingsProvider).webSearchApiKey, isNull);
  });
}

class _SpySettingsNotifier extends SettingsNotifier {
  _SpySettingsNotifier({this.initialEnabled = false});

  final bool initialEnabled;
  final setWebToolsEnabledCalls = <bool>[];
  final setWebSearchProviderCalls = <String>[];
  final setWebSearchApiKeyCalls = <String?>[];

  @override
  AppSettings build() => AppSettings(
    mcpEnabled: true,
    newChatMcpEnabled: true,
    webToolsEnabled: initialEnabled,
  );

  @override
  void setWebToolsEnabled(bool value) {
    setWebToolsEnabledCalls.add(value);
    super.setWebToolsEnabled(value);
  }

  @override
  void setWebSearchProvider(String value) {
    setWebSearchProviderCalls.add(value);
    super.setWebSearchProvider(value);
  }

  @override
  void setWebSearchApiKey(String? value) {
    setWebSearchApiKeyCalls.add(value);
    super.setWebSearchApiKey(value);
  }
}
