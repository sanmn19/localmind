import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/routes/app_routes.dart';
import 'package:localmind/core/routes/desktop_workspace.dart';
import 'package:localmind/features/desktop/data/models/desktop_window.dart';
import 'package:localmind/features/desktop/providers/desktop_window_providers.dart';
import 'package:localmind/features/desktop/views/components/desktop_command_palette.dart';
import 'package:localmind/features/desktop/views/desktop_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    return container;
  }

  void useDesktopViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Pumps the host under a router, so the host can follow its route.
  Future<GoRouter> pumpHost(
    WidgetTester tester,
    ProviderContainer container, {
    String initialLocation = AppRoutes.home,
    Widget? sidebar,
    List<DesktopCommand> Function()? conversationCommands,
  }) async {
    useDesktopViewport(tester);
    final router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        ShellRoute(
          builder: (context, state, child) => DesktopHost(
            sidebar: sidebar ?? const SizedBox(width: 240),
            screenBuilder: (window) => Text('screen:${window.title}'),
            conversationCommands: conversationCommands,
          ),
          routes: [
            for (final route in [
              AppRoutes.home,
              AppRoutes.settings,
              AppRoutes.skills,
              AppRoutes.savedMessages,
            ])
              GoRoute(
                path: route,
                builder: (context, state) => const SizedBox.shrink(),
              ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  /// Pumps the host outside a router, where it falls back to [initialRoute].
  Future<void> pumpHostWithoutRouter(
    WidgetTester tester,
    ProviderContainer container, {
    String? initialRoute,
  }) async {
    useDesktopViewport(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DesktopHost(
            sidebar: const SizedBox(width: 240),
            screenBuilder: (window) => Text('screen:${window.title}'),
            initialRoute: initialRoute,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pressMeta(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
  }

  Future<void> pressMetaAlt(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
  }

  DesktopLayout layoutOf(ProviderContainer container) =>
      container.read(desktopWindowControllerProvider);

  /// Lets the controller's debounced layout write run before the test ends.
  Future<void> flushSaves(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets('the desktop host opens the router location as a window', (
    tester,
  ) async {
    final container = createContainer();
    await pumpHost(tester, container, initialLocation: AppRoutes.settings);

    expect(find.text('screen:Settings'), findsOneWidget);
    final layout = layoutOf(container);
    expect(layout.windows.single.kind, DesktopWindowKind.settings);
    expect(layout.windows.single.route, AppRoutes.settings);
    await flushSaves(tester);
  });

  testWidgets('the desktop host opens its initial route without a router', (
    tester,
  ) async {
    final container = createContainer();
    await pumpHostWithoutRouter(
      tester,
      container,
      initialRoute: AppRoutes.settings,
    );

    expect(find.text('screen:Settings'), findsOneWidget);
    final layout = layoutOf(container);
    expect(layout.windows.single.kind, DesktopWindowKind.settings);
    expect(layout.windows.single.route, AppRoutes.settings);
    await flushSaves(tester);
  });

  testWidgets('the desktop host opens nothing without a route', (tester) async {
    final container = createContainer();
    await pumpHostWithoutRouter(tester, container);

    expect(layoutOf(container).windows, isEmpty);
  });

  testWidgets('the desktop host opens a window when the router changes route', (
    tester,
  ) async {
    final container = createContainer();
    final router = await pumpHost(tester, container);
    expect(layoutOf(container).windows.single.kind, DesktopWindowKind.chat);

    router.go(AppRoutes.settings);
    await tester.pumpAndSettle();

    final layout = layoutOf(container);
    expect(
      layout.windows.map((window) => window.kind),
      contains(DesktopWindowKind.settings),
    );
    expect(
      layout.windows
          .firstWhere((window) => window.kind == DesktopWindowKind.settings)
          .route,
      AppRoutes.settings,
    );
    expect(find.text('screen:Settings'), findsOneWidget);
    await flushSaves(tester);
  });

  testWidgets('the sidebar workspace opens routes as windows', (tester) async {
    final container = createContainer();
    await pumpHost(
      tester,
      container,
      sidebar: const _WorkspaceProbe(key: ValueKey('workspace-probe')),
    );

    await tester.tap(find.byKey(const ValueKey('workspace-probe')));
    await tester.pumpAndSettle();

    final layout = layoutOf(container);
    expect(
      layout.windows.map((window) => window.kind),
      contains(DesktopWindowKind.settings),
    );
    expect(find.text('screen:Settings'), findsOneWidget);
    await flushSaves(tester);
  });

  testWidgets('command N opens a fresh chat window each time', (tester) async {
    final container = createContainer();
    await pumpHost(tester, container, initialLocation: AppRoutes.settings);

    await pressMeta(tester, LogicalKeyboardKey.keyN);
    await pressMeta(tester, LogicalKeyboardKey.keyN);

    final drafts = [
      for (final window in layoutOf(container).windows)
        if (window.conversationId?.startsWith('draft-') ?? false) window,
    ];
    expect(drafts, hasLength(2));
    expect(drafts[0].conversationId, isNot(drafts[1].conversationId));
    await flushSaves(tester);
  });

  testWidgets('command M minimises and command W closes the focused window', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    await pumpHost(tester, container, initialLocation: AppRoutes.settings);
    final skills = controller.open(
      kind: DesktopWindowKind.skills,
      title: 'Skills',
    );
    await tester.pumpAndSettle();

    await pressMetaAlt(tester, LogicalKeyboardKey.keyM);
    expect(
      layoutOf(
        container,
      ).windows.singleWhere((w) => w.id == skills).isMinimized,
      isTrue,
    );
    expect(
      layoutOf(
        container,
      ).windows.singleWhere((w) => w.kind == DesktopWindowKind.settings).id,
      layoutOf(container).focusedWindowId,
    );

    await pressMeta(tester, LogicalKeyboardKey.keyW);
    expect(layoutOf(container).windows.single.id, skills);

    await flushSaves(tester);
  });

  testWidgets('command comma opens the settings window', (tester) async {
    final container = createContainer();
    await pumpHost(tester, container);

    await pressMeta(tester, LogicalKeyboardKey.comma);

    expect(
      layoutOf(container).windows.map((window) => window.kind),
      contains(DesktopWindowKind.settings),
    );
    expect(find.text('screen:Settings'), findsOneWidget);
    await flushSaves(tester);
  });

  testWidgets('the palette opens with command K and searches the route map', (
    tester,
  ) async {
    final container = createContainer();
    await pumpHost(tester, container);

    await pressMeta(tester, LogicalKeyboardKey.keyK);
    expect(
      find.byKey(const ValueKey('desktop-command-palette')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('desktop-command-field')),
      'saved',
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('desktop-command-route:/saved-messages')),
    );
    await tester.pumpAndSettle();

    final layout = layoutOf(container);
    expect(
      layout.windows.map((window) => window.kind),
      contains(DesktopWindowKind.savedMessages),
    );
    expect(
      layout.windows
          .firstWhere(
            (window) => window.kind == DesktopWindowKind.savedMessages,
          )
          .route,
      AppRoutes.savedMessages,
    );
    expect(find.byKey(const ValueKey('desktop-command-palette')), findsNothing);
    await flushSaves(tester);
  });

  testWidgets('escape closes the palette', (tester) async {
    final container = createContainer();
    await pumpHost(tester, container);

    await pressMeta(tester, LogicalKeyboardKey.keyK);
    expect(
      find.byKey(const ValueKey('desktop-command-palette')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('desktop-command-palette')), findsNothing);
    await flushSaves(tester);
  });

  testWidgets('the palette focuses an open window', (tester) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    await pumpHost(tester, container, initialLocation: AppRoutes.settings);
    final settings = layoutOf(container).windows.single.id;
    final skills = controller.open(
      kind: DesktopWindowKind.skills,
      title: 'Skills',
    );
    await tester.pumpAndSettle();

    await pressMeta(tester, LogicalKeyboardKey.keyK);
    await tester.enterText(
      find.byKey(const ValueKey('desktop-command-field')),
      'Settings',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('desktop-command-window:$settings')));
    await tester.pumpAndSettle();

    expect(layoutOf(container).focusedWindowId, settings);
    expect(layoutOf(container).windows, hasLength(2));
    expect(layoutOf(container).windows.any((w) => w.id == skills), isTrue);
    await flushSaves(tester);
  });

  testWidgets('the palette opens a supplied conversation command', (
    tester,
  ) async {
    final container = createContainer();
    await pumpHost(
      tester,
      container,
      initialLocation: AppRoutes.settings,
      conversationCommands: () => const [
        DesktopCommand(
          id: 'conversation:c1',
          label: 'Trip planning',
          kind: DesktopWindowKind.chat,
        ),
      ],
    );

    await pressMeta(tester, LogicalKeyboardKey.keyK);
    await tester.enterText(
      find.byKey(const ValueKey('desktop-command-field')),
      'trip',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('desktop-command-conversation:c1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('desktop-command-conversation:c1')),
    );
    await tester.pumpAndSettle();

    final chat = layoutOf(
      container,
    ).windows.singleWhere((window) => window.conversationId == 'c1');
    expect(chat.kind, DesktopWindowKind.chat);
    expect(chat.title, 'Trip planning');
    expect(layoutOf(container).focusedWindowId, chat.id);
    expect(find.text('screen:Trip planning'), findsOneWidget);
    await flushSaves(tester);
  });
}

class _WorkspaceProbe extends ConsumerWidget {
  const _WorkspaceProbe({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: 240,
      child: TextButton(
        onPressed: () => ref
            .read(desktopWorkspaceProvider)!
            .openRoute(context, AppRoutes.settings),
        child: const Text('open settings'),
      ),
    );
  }
}
