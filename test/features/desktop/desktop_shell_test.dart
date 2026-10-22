import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/features/desktop/data/models/desktop_window.dart';
import 'package:localmind/features/desktop/providers/desktop_window_providers.dart';
import 'package:localmind/features/desktop/views/desktop_shell.dart';
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

  Future<void> pumpShell(
    WidgetTester tester,
    ProviderContainer container, {
    Future<String?> Function()? startNewChat,
    Size size = const Size(1440, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DesktopShell(
            sidebar: const SizedBox(width: 240),
            screenBuilder: (window) => SizedBox.expand(
              key: ValueKey('screen-${window.id}'),
              child: Text('screen:${window.title}'),
            ),
            startNewChat: startNewChat,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> flushSaves(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
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

  testWidgets('renders one tab per window and only the active screen', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final settings = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    final chat = controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'Chat',
    );

    await pumpShell(tester, container);

    expect(find.byKey(ValueKey('desktop-tab-$settings')), findsOneWidget);
    expect(find.byKey(ValueKey('desktop-tab-$chat')), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('screen:Chat'), findsOneWidget);
    expect(find.text('screen:Settings'), findsNothing);

    await flushSaves(tester);
  });

  testWidgets('the active screen fills the workspace beside the sidebar', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    controller.open(kind: DesktopWindowKind.settings, title: 'Settings');

    await pumpShell(tester, container);

    final tabBar = tester.getRect(
      find.byKey(const ValueKey('desktop-tab-bar')),
    );
    final screen = tester.getRect(
      find.byKey(ValueKey('screen-${layoutOf(container).focusedWindowId}')),
    );
    expect(screen.left, 240);
    expect(screen.top, tabBar.bottom);
    expect(screen.width, 1440 - 240);

    await flushSaves(tester);
  });

  testWidgets('the tab strip scrolls horizontally when tabs overflow', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    for (var index = 0; index < 12; index++) {
      controller.open(
        kind: DesktopWindowKind.chat,
        conversationId: 'c$index',
        title: 'Conversation $index',
      );
    }

    await pumpShell(tester, container, size: const Size(800, 600));

    final scroller = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: find.byKey(const ValueKey('desktop-tab-bar')),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    expect(scroller.scrollDirection, Axis.horizontal);

    await flushSaves(tester);
  });

  testWidgets('the focused tab is highlighted', (tester) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final settings = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    final chat = controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'Chat',
    );

    await pumpShell(tester, container);

    Color? tabColor(String id) {
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(ValueKey('desktop-tab-$id')),
              matching: find.byType(Material),
            )
            .first,
      );
      return material.color;
    }

    final colorScheme = Theme.of(
      tester.element(find.byKey(const ValueKey('desktop-tab-bar'))),
    ).colorScheme;
    expect(tabColor(chat), colorScheme.surfaceContainerHighest);
    expect(tabColor(settings), isNot(colorScheme.surfaceContainerHighest));

    await flushSaves(tester);
  });

  testWidgets('a tab activates its screen when tapped', (tester) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final settings = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'Chat',
    );

    await pumpShell(tester, container);
    expect(find.text('screen:Chat'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('desktop-tab-$settings')));
    await tester.pumpAndSettle();

    expect(layoutOf(container).focusedWindowId, settings);
    expect(find.text('screen:Settings'), findsOneWidget);
    expect(find.text('screen:Chat'), findsNothing);

    await flushSaves(tester);
  });

  testWidgets('the tab close button closes it and activates the neighbour', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final settings = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    final chat = controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'Chat',
    );

    await pumpShell(tester, container);

    await tester.tap(find.byKey(ValueKey('desktop-tab-close-$chat')));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('desktop-tab-$chat')), findsNothing);
    expect(layoutOf(container).windows.single.id, settings);
    expect(layoutOf(container).focusedWindowId, settings);
    expect(find.text('screen:Settings'), findsOneWidget);

    await flushSaves(tester);
  });

  testWidgets('the tab bar button opens a new chat tab', (tester) async {
    final container = createContainer();
    var newChats = 0;

    await pumpShell(tester, container, startNewChat: () async => 'c${newChats++}');

    await tester.tap(find.byKey(const ValueKey('desktop-new-chat')));
    await tester.pumpAndSettle();

    final layout = layoutOf(container);
    expect(newChats, 1);
    expect(layout.windows, hasLength(1));
    expect(layout.windows.single.kind, DesktopWindowKind.chat);
    expect(layout.windows.single.conversationId, 'c0');
    expect(find.text('screen:Chat'), findsOneWidget);

    await flushSaves(tester);
  });

  testWidgets('command 1 to 9 activates the nth tab', (tester) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final settings = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    final chat = controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'Chat',
    );

    await pumpShell(tester, container);
    expect(layoutOf(container).focusedWindowId, chat);

    await pressMeta(tester, LogicalKeyboardKey.digit1);
    expect(layoutOf(container).focusedWindowId, settings);

    await pressMeta(tester, LogicalKeyboardKey.digit2);
    expect(layoutOf(container).focusedWindowId, chat);

    // A digit past the last tab is a no-op.
    await pressMeta(tester, LogicalKeyboardKey.digit9);
    expect(layoutOf(container).focusedWindowId, chat);

    await flushSaves(tester);
  });

  testWidgets('closing every tab shows the empty workspace', (tester) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final settings = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );

    await pumpShell(tester, container);
    expect(find.byKey(const ValueKey('desktop-empty-workspace')), findsNothing);

    await tester.tap(find.byKey(ValueKey('desktop-tab-close-$settings')));
    await tester.pumpAndSettle();

    expect(layoutOf(container).windows, isEmpty);
    expect(
      find.byKey(const ValueKey('desktop-empty-workspace')),
      findsOneWidget,
    );

    await flushSaves(tester);
  });
}
