import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/theme/app_theme.dart';
import 'package:localmind/features/ask_local/data/ask_local_overlay_access.dart';
import 'package:localmind/features/chat/data/background_task_service.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/mcp/views/mcp_tools_screen.dart';
import 'package:localmind/l10n/app_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The Ask Local card: status-only surface (title/desc + the display-over-
// apps grant row) with a live granted read through the method channel
// (mocked here), settings deep-link recovery and a resume re-check. The
// wrapper's open/close/permission semantics round-trip through the same
// mock.

const _askLocalChannel = MethodChannel('localmind/ask_local');
const _notificationsChannel = MethodChannel('localmind/notifications');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The MCP Tools screen also mounts the notifications card whose grant
    // probe hits its own channel; without a mock its 3s-bounded read
    // leaves a pending Timer at test end.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_notificationsChannel, (call) async {
      switch (call.method) {
        case 'isListenerEnabled':
          return false;
        default:
          return null;
      }
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_notificationsChannel, null));
  });

  Future<ProviderContainer> pumpCardHarness(
    WidgetTester tester, {
    _OverlayGrantedMock? mock,
    bool forceGrantError = false,
  }) async {
    tester.view.physicalSize = const Size(700, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    if (mock != null) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_askLocalChannel, mock.call);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_askLocalChannel, null),
      );
    }

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
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
        availableToolsProvider.overrideWith((ref) => Future.value(const [])),
        conv.conversationsProvider.overrideWith(
          () => _CardConversations(const []),
        ),
        backgroundTasksServiceProvider.overrideWith((ref) => _EmptyBgService()),
        if (forceGrantError)
          askLocalOverlayGrantProvider.overrideWithValue(
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
    return container;
  }

  testWidgets('the Ask Local card renders status-only (no tool toggle)', (
    tester,
  ) async {
    await pumpCardHarness(tester, mock: _OverlayGrantedMock());
    await tester.pumpAndSettle();

    expect(find.text('Ask Local'), findsOneWidget);
    expect(
      find.text(
        'Ask about a selected text from any app: the screen is '
        'captured locally and answered in a floating card.',
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('ask_local_card')),
        matching: find.byType(ShadSwitch),
      ),
      findsNothing,
      reason: 'v1 has NO card toggle: the section is pure grant + status',
    );
  });

  testWidgets('grant row reads the LIVE overlay state via the channel', (
    tester,
  ) async {
    await pumpCardHarness(
      tester,
      mock: (_OverlayGrantedMock()..permitted = true),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ask_local_grant_row_on')), findsOneWidget);
    expect(find.text('Overlay access granted'), findsOneWidget);
  });

  testWidgets('a missing channel plugin reads as OFF (not granted) without '
      'throwing', (tester) async {
    await pumpCardHarness(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ask_local_grant_row_off')), findsOneWidget);
    expect(find.text('Overlay access is off'), findsOneWidget);
  });

  testWidgets('the grant button deep-links and re-checks the grant', (
    tester,
  ) async {
    final mock = _OverlayGrantedMock();
    await pumpCardHarness(tester, mock: mock);
    await tester.pumpAndSettle();
    expect(find.text('Overlay access is off'), findsOneWidget);

    mock.permitted = true;
    await tester.tap(find.byKey(const Key('ask_local_grant_access')));
    await tester.pumpAndSettle();

    expect(mock.settingsOpens, 1);
    expect(find.text('Overlay access granted'), findsOneWidget);
  });

  testWidgets('a resume lifecycle event re-checks the grant without a tap', (
    tester,
  ) async {
    final mock = _OverlayGrantedMock();
    await pumpCardHarness(tester, mock: mock);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ask_local_grant_row_off')), findsOneWidget);
    final probesBefore = mock.isPermittedCalls;

    // The user grants display-over-apps in the system settings while the
    // app is away; the Kotlin side already answered, so returning to the
    // app must re-probe without waiting for the next button press.
    mock.permitted = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(
      mock.isPermittedCalls,
      greaterThan(probesBefore),
      reason: 'resume must invalidate and re-run the grant probe',
    );
    expect(find.byKey(const Key('ask_local_grant_row_on')), findsOneWidget);
    expect(find.text('Overlay access granted'), findsOneWidget);
    expect(mock.settingsOpens, 0, reason: 'no button tap involved');
  });

  testWidgets('an errored capability probe still offers the grant button', (
    tester,
  ) async {
    await pumpCardHarness(tester, forceGrantError: true);
    await tester.pumpAndSettle();

    expect(find.text('Overlay access is off'), findsOneWidget);
    expect(
      find.byKey(const Key('ask_local_grant_access')),
      findsOneWidget,
      reason: 'a hidden button blocks recovery; the error row keeps it',
    );
  });

  test('openOverlayNow returns the platform answer and surfaces the '
      'permission miss as a typed error', () async {
    final mock = _OverlayGrantedMock()..permitted = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_askLocalChannel, mock.call);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_askLocalChannel, null),
    );

    const access = AskLocalOverlayAccess();
    expect(await access.openOverlayNow(selectedText: 'local mint'), isTrue);
    expect(mock.openOverlayCalls, 1);

    // Kotlin result.error('overlay_permission_missing') → typed exception.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_askLocalChannel, (call) async {
          throw PlatformException(code: 'overlay_permission_missing');
        });
    expect(
      () => access.openOverlayNow(selectedText: 'x'),
      throwsA(isA<AskLocalOverlayPermissionException>()),
    );
  });

  test('closeCard/isCardShown degrade to false without a plugin', () async {
    // No mock registered: the channel answers MissingPluginException.
    const access = AskLocalOverlayAccess();
    expect(await access.closeCard(), isFalse);
    expect(await access.isCardShown(), isFalse);
    expect(await access.isOverlayPermitted(), isFalse);
  });
}

/// Channel mock: isOverlayPermitted answers [permitted];
/// openOverlaySettings counts into [settingsOpens]; openOverlayNow counts
/// into [openOverlayCalls].
class _OverlayGrantedMock {
  bool permitted = false;
  int settingsOpens = 0;
  int isPermittedCalls = 0;
  int openOverlayCalls = 0;

  Future<Object?> call(MethodCall call) async {
    switch (call.method) {
      case 'isOverlayPermitted':
        isPermittedCalls++;
        return permitted;
      case 'openOverlaySettings':
        settingsOpens++;
        return null;
      case 'openOverlayNow':
        openOverlayCalls++;
        return true;
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
