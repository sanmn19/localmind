import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:localmind/app.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/routes/app_routes.dart';
import 'package:localmind/core/routes/desktop_workspace.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/core/theme/app_theme.dart';
import 'package:localmind/features/chat/providers/chat_providers.dart';
import 'package:localmind/features/chat/views/chat_screen.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/desktop/data/models/desktop_window.dart';
import 'package:localmind/features/desktop/providers/desktop_window_providers.dart';
import 'package:localmind/features/desktop/views/components/desktop_command_palette.dart';
import 'package:localmind/features/desktop/views/desktop_host.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/servers/providers/server_providers.dart';
import 'package:localmind/features/servers/views/add_server_screen.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/features/stt/providers/stt_providers.dart';
import 'package:localmind/features/tts/providers/tts_providers.dart';
import 'package:localmind/l10n/app_localizations.dart';
import 'package:localmind/objectbox.g.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ProviderContainer createContainer({
    ServersNotifier Function()? serversNotifier,
  }) {
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (serversNotifier != null)
          serversProvider.overrideWith(serversNotifier),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// A container with the providers the real [ChatScreen] needs.
  ProviderContainer createChatContainer() {
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(
          _FakeObjectBoxStore(_FakeServerBox()),
        ),
        conv.conversationsProvider.overrideWith(
          _EmptyConversationsNotifier.new,
        ),
        settingsProvider.overrideWith(_TestSettingsNotifier.new),
        activeServerProvider.overrideWith(_NoServerNotifier.new),
        activeChatTargetProvider.overrideWithValue(
          const ActiveChatTarget(
            server: null,
            selectedModel: null,
            effectiveModelId: null,
            modelLabel: 'No model',
          ),
        ),
        smartRepliesProvider.overrideWith((ref) async => const <String>[]),
        sttProvider.overrideWith(_StubSttNotifier.new),
        ttsProvider.overrideWith(_StubTtsNotifier.new),
      ],
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

  Future<void> pumpHost(
    WidgetTester tester,
    ProviderContainer container, {
    String initialLocation = AppRoutes.home,
    Widget? sidebar,
    List<DesktopCommand> Function()? conversationCommands,
    Future<void> Function()? startNewChat,
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
            startNewChat: startNewChat,
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

  /// Pumps the host with the app's real screen builder.
  Future<void> pumpHostWithRealScreens(
    WidgetTester tester,
    ProviderContainer container, {
    String initialLocation = AppRoutes.home,
    Future<void> Function()? startNewChat,
    Size size = const Size(1440, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        ShellRoute(
          builder: (context, state, child) => DesktopHost(
            sidebar: const SizedBox(width: 240),
            screenBuilder: buildDesktopScreen,
            startNewChat: startNewChat,
          ),
          routes: [
            for (final route in [
              AppRoutes.home,
              AppRoutes.addServer,
              AppRoutes.settings,
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
        child: ShadTheme(
          data: AppTheme.lightShadTheme,
          child: MaterialApp.router(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
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

  DesktopLayout layoutOf(ProviderContainer container) =>
      container.read(desktopWindowControllerProvider);

  /// Lets the controller's debounced layout write run before the test ends.
  Future<void> flushSaves(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets('the desktop host opens the router location as a tab', (
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

  testWidgets('the desktop host opens a tab when the router changes route', (
    tester,
  ) async {
    final container = createContainer();
    final router = await pumpHostRouter(tester, container);
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

  testWidgets('the sidebar workspace opens routes as tabs', (tester) async {
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

  testWidgets('command N opens a usable chat tab', (tester) async {
    final container = createChatContainer();
    await pumpHostWithRealScreens(
      tester,
      container,
      initialLocation: AppRoutes.addServer,
      startNewChat: () =>
          container.read(chatProvider.notifier).startNewConversation(),
    );
    expect(find.byType(ChatScreen), findsNothing);

    await pressMeta(tester, LogicalKeyboardKey.keyN);

    final chat = layoutOf(
      container,
    ).windows.singleWhere((window) => window.kind == DesktopWindowKind.chat);
    expect(chat.conversationId, isNull);
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('chat_input')), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-chat-missing')), findsNothing);
    await flushSaves(tester);
  });

  testWidgets('hosting AddServerScreen closes its tab when saving', (
    tester,
  ) async {
    final container = createContainer(
      serversNotifier: _FakeServersNotifier.new,
    );
    await pumpHostWithRealScreens(
      tester,
      container,
      initialLocation: AppRoutes.addServer,
      size: const Size(1440, 4000),
    );
    expect(find.byType(AddServerScreen), findsOneWidget);
    expect(layoutOf(container).windows, hasLength(1));

    await tester.enterText(find.byType(TextFormField).at(0), 'Desk server');
    await tester.enterText(find.byType(TextFormField).at(1), '127.0.0.1');
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(layoutOf(container).windows, isEmpty);
    expect(find.byType(AddServerScreen), findsNothing);
    expect(find.byKey(const ValueKey('desktop-tab-bar')), findsOneWidget);
    await flushSaves(tester);
  });

  testWidgets('command W closes the active tab', (tester) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    await pumpHost(tester, container, initialLocation: AppRoutes.settings);
    final settings = layoutOf(container).windows.single.id;
    controller.open(kind: DesktopWindowKind.skills, title: 'Skills');
    await tester.pumpAndSettle();

    await pressMeta(tester, LogicalKeyboardKey.keyW);
    expect(layoutOf(container).windows.single.id, settings);

    await flushSaves(tester);
  });

  testWidgets('command comma opens the settings tab', (tester) async {
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

  testWidgets('the palette focuses an open tab', (tester) async {
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

/// Pumps the host under a router and returns that router.
Future<GoRouter> pumpHostRouter(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final router = GoRouter(
    initialLocation: AppRoutes.home,
    routes: [
      ShellRoute(
        builder: (context, state, child) => DesktopHost(
          sidebar: const SizedBox(width: 240),
          screenBuilder: (window) => Text('screen:${window.title}'),
        ),
        routes: [
          for (final route in [AppRoutes.home, AppRoutes.settings])
            GoRoute(
              path: route,
              builder: (context, state) => const SizedBox.shrink(),
            ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
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

class _EmptyConversationsNotifier extends conv.ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => const [];
}

class _TestSettingsNotifier extends SettingsNotifier {
  @override
  AppSettings build() => AppSettings(hasAskedForNotifications: true);
}

class _NoServerNotifier extends ActiveServerNotifier {
  @override
  Server? build() => null;
}

class _StubSttNotifier extends SttNotifier {
  @override
  SttState build() => const SttState();
}

class _StubTtsNotifier extends TtsNotifier {
  @override
  TtsState build() => const TtsState();
}

class _FakeServersNotifier extends ServersNotifier {
  @override
  Future<List<Server>> build() async => const [];

  @override
  Future<void> addServer(Server server) async {}

  @override
  Future<ConnectionStatus> testConnection(
    String serverId,
    dynamic apiService,
  ) async => ConnectionStatus.connected;
}

class _FakeObjectBoxStore extends Fake implements ObjectBoxStore {
  _FakeObjectBoxStore(this.serverBox);

  @override
  final Box<ServerEntity> serverBox;
}

class _FakeServerBox extends Fake implements Box<ServerEntity> {
  final List<ServerEntity> _entities = [];
  int _nextId = 1;

  @override
  List<ServerEntity> getAll() => List<ServerEntity>.from(_entities);

  @override
  int put(ServerEntity entity, {PutMode mode = PutMode.put}) {
    if (entity.internalId == 0) {
      entity.internalId = _nextId++;
      _entities.add(entity);
    } else {
      final index = _entities.indexWhere(
        (candidate) => candidate.internalId == entity.internalId,
      );
      if (index >= 0) {
        _entities[index] = entity;
      } else {
        _entities.add(entity);
      }
    }
    return entity.internalId;
  }

  @override
  bool remove(int id) {
    final before = _entities.length;
    _entities.removeWhere((entity) => entity.internalId == id);
    return _entities.length < before;
  }

  @override
  int count({int limit = 0}) => _entities.length;
}
