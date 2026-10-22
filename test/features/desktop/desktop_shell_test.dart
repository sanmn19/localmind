import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/features/desktop/data/models/desktop_window.dart';
import 'package:localmind/features/desktop/providers/desktop_window_providers.dart';
import 'package:localmind/features/desktop/views/components/desktop_window_frame.dart';
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

  Future<void> pumpShellFrame(
    WidgetTester tester,
    ProviderContainer container, {
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
            screenBuilder: (window) => Text('screen:${window.title}'),
          ),
        ),
      ),
    );
  }

  Future<void> pumpShell(
    WidgetTester tester,
    ProviderContainer container, {
    Size size = const Size(1440, 900),
  }) async {
    await pumpShellFrame(tester, container, size: size);
    await tester.pumpAndSettle();
  }

  Future<void> flushSaves(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'renders one frame per window and a dock entry per minimised window',
    (tester) async {
      final container = createContainer();
      final controller = container.read(
        desktopWindowControllerProvider.notifier,
      );
      controller.open(kind: DesktopWindowKind.settings, title: 'Settings');
      controller.open(
        kind: DesktopWindowKind.chat,
        conversationId: 'c1',
        title: 'Chat',
      );

      await pumpShell(tester, container);

      expect(find.text('screen:Settings'), findsOneWidget);
      expect(find.text('screen:Chat'), findsOneWidget);

      controller.minimize(controller.state.windows.first.id);
      await tester.pumpAndSettle();
      expect(find.text('screen:Settings'), findsNothing);
      expect(
        find.byKey(const ValueKey('desktop-dock-entry-Settings')),
        findsOneWidget,
      );

      await flushSaves(tester);
    },
  );

  testWidgets('the title bar closes, minimises and maximises a window', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);

    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    await pumpShell(tester, container);

    await tester.tap(find.byKey(ValueKey('desktop-maximize-$id')));
    await tester.pumpAndSettle();
    expect(
      container
          .read(desktopWindowControllerProvider)
          .windows
          .single
          .isMaximized,
      isTrue,
    );

    await tester.tap(find.byKey(ValueKey('desktop-minimize-$id')));
    await tester.pumpAndSettle();
    expect(find.text('screen:Settings'), findsNothing);
    expect(
      find.byKey(const ValueKey('desktop-dock-entry-Settings')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('desktop-dock-entry-Settings')));
    await tester.pumpAndSettle();
    expect(find.text('screen:Settings'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('desktop-close-$id')));
    await tester.pumpAndSettle();
    expect(container.read(desktopWindowControllerProvider).windows, isEmpty);
    expect(
      find.byKey(const ValueKey('desktop-dock-entry-Settings')),
      findsNothing,
    );

    await flushSaves(tester);
  });

  testWidgets('a maximised window fills the workspace', (tester) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    await pumpShell(tester, container);

    final workspace = tester.getRect(
      find.byKey(const ValueKey('desktop-workspace')),
    );
    controller.toggleMaximize(id);
    await tester.pumpAndSettle();

    expect(tester.getRect(find.byType(DesktopWindowFrame)), workspace);

    await flushSaves(tester);
  });

  testWidgets('the dock restores a minimised window and focuses it', (
    tester,
  ) async {
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

    controller.minimize(settings);
    await tester.pumpAndSettle();
    expect(find.text('screen:Settings'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('desktop-dock-entry-Settings')));
    await tester.pumpAndSettle();

    final layout = container.read(desktopWindowControllerProvider);
    expect(find.text('screen:Settings'), findsOneWidget);
    expect(layout.focusedWindowId, settings);
    expect(
      layout.windows.firstWhere((window) => window.id == settings).isMinimized,
      isFalse,
    );

    await flushSaves(tester);
  });

  testWidgets('tapping a window focuses it', (tester) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final settings = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
      rect: const Rect.fromLTWH(0, 0, 500, 500),
    );
    final chat = controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'Chat',
      rect: const Rect.fromLTWH(700, 400, 500, 500),
    );
    await pumpShell(tester, container);
    expect(
      container.read(desktopWindowControllerProvider).focusedWindowId,
      chat,
    );

    await tester.tap(find.text('screen:Settings'));
    await tester.pumpAndSettle();

    expect(
      container.read(desktopWindowControllerProvider).focusedWindowId,
      settings,
    );

    await flushSaves(tester);
  });

  testWidgets('the dock opens a new chat window', (tester) async {
    final container = createContainer();
    await pumpShell(tester, container);

    await tester.tap(find.byKey(const ValueKey('desktop-dock-new-chat')));
    await tester.pumpAndSettle();

    final layout = container.read(desktopWindowControllerProvider);
    expect(layout.windows, hasLength(1));
    expect(layout.windows.single.kind, DesktopWindowKind.chat);
    expect(find.text('screen:Chat'), findsOneWidget);

    await flushSaves(tester);
  });

  testWidgets('a restored off-screen layout is clamped into the workspace', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
      rect: const Rect.fromLTWH(4000, 4000, 720, 520),
    );
    await pumpShell(tester, container);

    final layout = container.read(desktopWindowControllerProvider);
    expect(layout.windows.single.rect, const Rect.fromLTWH(840, 516, 720, 520));
    expect(
      tester.getRect(find.byKey(ValueKey('desktop-title-$id'))).left,
      240 + 840,
    );

    await flushSaves(tester);
  });

  testWidgets('clamps an off-screen restored window on the first frame', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
      rect: const Rect.fromLTWH(4000, 4000, 720, 520),
    );

    await pumpShellFrame(tester, container);

    expect(
      tester.getRect(find.byType(DesktopWindowFrame)),
      const Rect.fromLTWH(240 + 840, 516, 720, 520),
    );
    expect(
      container.read(desktopWindowControllerProvider).windows.single.rect,
      const Rect.fromLTWH(840, 516, 720, 520),
    );

    await flushSaves(tester);
  });
}
