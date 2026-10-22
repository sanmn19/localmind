import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/routes/app_routes.dart';
import 'package:localmind/core/routes/desktop_workspace.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/desktop/data/models/desktop_window.dart';
import 'package:localmind/features/desktop/providers/desktop_window_providers.dart';
import 'package:localmind/features/desktop/views/desktop_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ProviderContainer createContainer({
    List<Conversation> conversations = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        conv.conversationsProvider.overrideWith(
          () => _StubConversations(conversations),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pumpHost(
    WidgetTester tester,
    ProviderContainer container, {
    String? initialRoute,
    Widget? sidebar,
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DesktopHost(
            sidebar: sidebar ?? const SizedBox(width: 240),
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

  DesktopLayout layoutOf(ProviderContainer container) =>
      container.read(desktopWindowControllerProvider);

  /// Lets the controller's debounced layout write run before the test ends.
  Future<void> flushSaves(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets('the desktop host opens the route as a window', (tester) async {
    final container = createContainer();
    await pumpHost(tester, container, initialRoute: AppRoutes.settings);

    expect(find.text('screen:Settings'), findsOneWidget);
    final layout = layoutOf(container);
    expect(layout.windows.single.kind, DesktopWindowKind.settings);
    expect(layout.windows.single.route, AppRoutes.settings);
    await flushSaves(tester);
  });

  testWidgets('the desktop host opens nothing without an initial route', (
    tester,
  ) async {
    final container = createContainer();
    await pumpHost(tester, container);

    expect(layoutOf(container).windows, isEmpty);
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
    expect(layout.windows.single.kind, DesktopWindowKind.settings);
    expect(layout.windows.single.route, AppRoutes.settings);
    expect(find.text('screen:Settings'), findsOneWidget);
    await flushSaves(tester);
  });

  testWidgets('command N opens a fresh chat window each time', (tester) async {
    final container = createContainer();
    await pumpHost(tester, container);

    await pressMeta(tester, LogicalKeyboardKey.keyN);
    await pressMeta(tester, LogicalKeyboardKey.keyN);

    final chats = [
      for (final window in layoutOf(container).windows)
        if (window.kind == DesktopWindowKind.chat) window,
    ];
    expect(chats, hasLength(2));
    expect(chats[0].conversationId, isNot(chats[1].conversationId));
    expect(chats.first.conversationId, startsWith('draft-'));
    await flushSaves(tester);
  });

  testWidgets('command M minimises and command W closes the focused window', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final settings = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    final skills = controller.open(
      kind: DesktopWindowKind.skills,
      title: 'Skills',
    );
    await pumpHost(tester, container);

    await pressMeta(tester, LogicalKeyboardKey.keyM);
    expect(
      layoutOf(
        container,
      ).windows.singleWhere((w) => w.id == skills).isMinimized,
      isTrue,
    );
    expect(layoutOf(container).focusedWindowId, settings);

    await pressMeta(tester, LogicalKeyboardKey.keyW);
    expect(layoutOf(container).windows.single.id, skills);

    await flushSaves(tester);
  });

  testWidgets('command comma opens the settings window', (tester) async {
    final container = createContainer();
    await pumpHost(tester, container);

    await pressMeta(tester, LogicalKeyboardKey.comma);

    expect(layoutOf(container).windows.single.kind, DesktopWindowKind.settings);
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
    expect(layout.windows.single.kind, DesktopWindowKind.savedMessages);
    expect(layout.windows.single.route, AppRoutes.savedMessages);
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
    final first = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    controller.open(kind: DesktopWindowKind.skills, title: 'Skills');
    await pumpHost(tester, container);

    await pressMeta(tester, LogicalKeyboardKey.keyK);
    await tester.enterText(
      find.byKey(const ValueKey('desktop-command-field')),
      'Settings',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('desktop-command-window:$first')));
    await tester.pumpAndSettle();

    expect(layoutOf(container).focusedWindowId, first);
    expect(layoutOf(container).windows, hasLength(2));
    await flushSaves(tester);
  });

  testWidgets('the palette opens a recent conversation as a chat window', (
    tester,
  ) async {
    final container = createContainer(
      conversations: [
        Conversation(
          id: 'c1',
          title: 'Trip planning',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ],
    );
    await pumpHost(tester, container);

    await pressMeta(tester, LogicalKeyboardKey.keyK);
    await tester.enterText(
      find.byKey(const ValueKey('desktop-command-field')),
      'trip',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('desktop-command-conversation:c1')),
    );
    await tester.pumpAndSettle();

    final window = layoutOf(container).windows.single;
    expect(window.kind, DesktopWindowKind.chat);
    expect(window.conversationId, 'c1');
    expect(window.title, 'Trip planning');
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

class _StubConversations extends conv.ConversationsNotifier {
  _StubConversations(this.rows);

  final List<Conversation> rows;

  @override
  Future<List<Conversation>> build() async => rows;
}
