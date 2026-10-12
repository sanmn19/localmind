import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/theme/app_theme.dart';
import 'package:localmind/features/chat/data/background_task_service.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/mcp/views/mcp_tools_screen.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/l10n/app_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The Notifications card: toggle persistence + the Notification access
// grant row (live granted state read through the method channel, mock
// returns here) + the settings deep-link button re-checking the state.

const _notificationsChannel = MethodChannel('localmind/notifications');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<(ProviderContainer, _SpySettingsNotifier)> pumpCardHarness(
    WidgetTester tester, {
    bool notificationToolsEnabled = false,
    _GrantMock? mock,
    bool forceGrantError = false,
  }) async {
    tester.view.physicalSize = const Size(700, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    if (mock != null) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_notificationsChannel, mock.call);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_notificationsChannel, null));
    }

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final spy = _SpySettingsNotifier(
      initialNotifications: notificationToolsEnabled,
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
        conv.conversationsProvider.overrideWith(
          () => _CardConversations(const []),
        ),
        backgroundTasksServiceProvider.overrideWith(
          (ref) => _EmptyBgService(),
        ),
        if (forceGrantError)
          notificationsListenerGrantProvider.overrideWithValue(
            AsyncError(StateError('grant probe failed'), StackTrace.empty),
          ),
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

  testWidgets(
    'toggle flips notificationToolsEnabled via the settings notifier',
    (tester) async {
      final (container, spy) = await pumpCardHarness(tester);
      await tester.pumpAndSettle();

      expect(find.text('Notifications'), findsOneWidget);
      expect(spy.setNotificationToolsEnabledCalls, isEmpty);
      expect(
        container.read(settingsProvider).notificationToolsEnabled,
        isFalse,
      );

      await tester.tap(find.byKey(const Key('notifications_tools_toggle')));
      await tester.pumpAndSettle();

      expect(spy.setNotificationToolsEnabledCalls, contains(true));
      expect(
        container.read(settingsProvider).notificationToolsEnabled,
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets('grant row reads the LIVE granted state via the channel',
      (tester) async {
    await pumpCardHarness(tester, mock: (_GrantMock()..granted = true));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('notifications_grant_row_on')),
      findsOneWidget,
    );
    expect(find.text('Notification access granted'), findsOneWidget);
    expect(
      find.byKey(const Key('notifications_grant_access')),
      findsOneWidget,
    );
  });

  testWidgets('a missing channel plugin reads as OFF (not granted) without '
      'throwing', (tester) async {
    await pumpCardHarness(tester);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('notifications_grant_row_off')),
      findsOneWidget,
    );
    expect(find.text('Notification access is off'), findsOneWidget);
  });

  testWidgets('the grant button deep-links and re-checks the grant',
      (tester) async {
    final mock = _GrantMock();
    await pumpCardHarness(tester, mock: mock);
    await tester.pumpAndSettle();
    expect(find.text('Notification access is off'), findsOneWidget);

    mock.granted = true;
    await tester.tap(find.byKey(const Key('notifications_grant_access')));
    await tester.pumpAndSettle();

    expect(mock.settingsOpens, 1);
    expect(find.text('Notification access granted'), findsOneWidget);
  });

  testWidgets('a resume lifecycle event re-checks the grant without a tap',
      (tester) async {
    final mock = _GrantMock();
    await pumpCardHarness(tester, mock: mock);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notifications_grant_row_off')), findsOneWidget);
    final probesBefore = mock.isListenerEnabledCalls;

    // The user grants Notification access in the system settings while the
    // app is away; the Kotlin side already answered, so returning to the
    // app must re-probe without waiting for the next button press.
    mock.granted = true;
    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(
      mock.isListenerEnabledCalls,
      greaterThan(probesBefore),
      reason: 'resume must invalidate and re-run the grant probe',
    );
    expect(
      find.byKey(const Key('notifications_grant_row_on')),
      findsOneWidget,
    );
    expect(find.text('Notification access granted'), findsOneWidget);
    expect(mock.settingsOpens, 0, reason: 'no button tap involved');
  });

  testWidgets('an errored capability probe still offers the grant button',
      (tester) async {
    await pumpCardHarness(tester, forceGrantError: true);
    await tester.pumpAndSettle();

    expect(find.text('Notification access is off'), findsOneWidget);
    expect(
      find.byKey(const Key('notifications_grant_access')),
      findsOneWidget,
      reason: 'a hidden button blocks recovery; the error row keeps it',
    );
  });
}

/// Channel mock: isListenerEnabled answers [granted];
/// openNotificationAccessSettings counts into [settingsOpens].
class _GrantMock {
  bool granted = false;
  int settingsOpens = 0;
  int isListenerEnabledCalls = 0;

  Future<Object?> call(MethodCall call) async {
    switch (call.method) {
      case 'isListenerEnabled':
        isListenerEnabledCalls++;
        return granted;
      case 'openNotificationAccessSettings':
        settingsOpens++;
        return null;
      default:
        return null;
    }
  }
}

class _EmptyBgService extends Fake implements BackgroundTasksService {}

class _CardConversations extends conv.ConversationsNotifier {
  _CardConversations(this.rows);

  final List<Conversation> rows;

  @override
  Future<List<Conversation>> build() async => rows;
}

class _SpySettingsNotifier extends SettingsNotifier {
  _SpySettingsNotifier({this.initialNotifications = false});

  final bool initialNotifications;

  final setNotificationToolsEnabledCalls = <bool>[];

  @override
  AppSettings build() =>
      AppSettings(notificationToolsEnabled: initialNotifications);

  @override
  void setNotificationToolsEnabled(bool value) {
    setNotificationToolsEnabledCalls.add(value);
    super.setNotificationToolsEnabled(value);
  }
}
