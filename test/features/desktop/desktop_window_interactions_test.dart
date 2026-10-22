import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/features/desktop/data/models/desktop_window.dart';
import 'package:localmind/features/desktop/providers/desktop_window_providers.dart';
import 'package:localmind/features/desktop/utils/window_geometry.dart';
import 'package:localmind/features/desktop/views/components/desktop_window_frame.dart';
import 'package:localmind/features/desktop/views/desktop_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The workspace left of the dock under a 1440x900 view with a 240 px sidebar.
const Rect _workspace = Rect.fromLTWH(0, 0, 1200, 836);

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
    DesktopScreenBuilder? screenBuilder,
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DesktopShell(
            sidebar: const SizedBox(width: 240),
            screenBuilder:
                screenBuilder ?? (window) => Text('screen:${window.title}'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Starts a drag on [target] and returns the gesture positioned past the
  /// touch slop, so the caller's next moves are applied in full.
  ///
  /// A title bar competes with the frame's tap and the bar's double tap, so its
  /// pan only starts once the slop is exceeded and the slop move itself is
  /// absorbed by the start position. A resize handle has the arena to itself and
  /// starts on the press, so its moves apply in full from the first one.
  Future<TestGesture> beginTitleDrag(WidgetTester tester, Finder target) async {
    final gesture = await tester.startGesture(tester.getCenter(target));
    await tester.pump();
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump();
    return gesture;
  }

  Future<void> flushSaves(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  DesktopWindowState windowOf(ProviderContainer container, String id) {
    return container
        .read(desktopWindowControllerProvider)
        .windows
        .firstWhere((window) => window.id == id);
  }

  testWidgets(
    'dragging the title bar moves the window and clicking focuses it',
    (tester) async {
      final container = createContainer();
      final controller = container.read(
        desktopWindowControllerProvider.notifier,
      );
      final first = controller.open(
        kind: DesktopWindowKind.settings,
        title: 'Settings',
      );
      controller.open(
        kind: DesktopWindowKind.chat,
        conversationId: 'c1',
        title: 'Chat',
      );

      await pumpShell(tester, container);

      final before = windowOf(container, first).rect.left;
      await tester.drag(
        find.byKey(ValueKey('desktop-title-$first')),
        const Offset(40, 30),
      );
      await tester.pumpAndSettle();

      expect(windowOf(container, first).rect.left, greaterThan(before));
      expect(
        container.read(desktopWindowControllerProvider).focusedWindowId,
        first,
      );

      await flushSaves(tester);
    },
  );

  testWidgets('dropping a window at the left edge snaps it to the left half', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
      rect: const Rect.fromLTWH(300, 100, 400, 300),
    );
    await pumpShell(tester, container);

    final gesture = await beginTitleDrag(
      tester,
      find.byKey(ValueKey('desktop-title-$id')),
    );
    await gesture.moveBy(const Offset(-424, 0));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      windowOf(container, id).rect,
      WindowGeometry.snapped(DesktopSnapEdge.leftHalf, _workspace),
    );

    await flushSaves(tester);
  });

  testWidgets('dropping a window at the top edge fills the workspace', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
      rect: const Rect.fromLTWH(300, 100, 400, 300),
    );
    await pumpShell(tester, container);

    final gesture = await beginTitleDrag(
      tester,
      find.byKey(ValueKey('desktop-title-$id')),
    );
    await gesture.moveBy(const Offset(0, -124));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      windowOf(container, id).rect,
      WindowGeometry.snapped(DesktopSnapEdge.full, _workspace),
    );

    await flushSaves(tester);
  });

  testWidgets('dragging away from a snapped edge leaves the free rect', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    controller.setWorkspace(_workspace);
    controller.snap(id, DesktopSnapEdge.leftHalf);
    await pumpShell(tester, container);

    final gesture = await beginTitleDrag(
      tester,
      find.byKey(ValueKey('desktop-title-$id')),
    );
    await gesture.moveBy(const Offset(200, 0));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(windowOf(container, id).rect.left, 200);
    expect(windowOf(container, id).rect.width, _workspace.width / 2);

    await flushSaves(tester);
  });

  testWidgets('dragging a resize handle resizes the window', (tester) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
      rect: const Rect.fromLTWH(100, 100, 400, 340),
    );
    await pumpShell(tester, container);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey('desktop-resize-right-$id'))),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(76, 0));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      windowOf(container, id).rect,
      const Rect.fromLTWH(100, 100, 476, 340),
    );

    await flushSaves(tester);
  });

  testWidgets('resizing never shrinks a window below its minimum width', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
      rect: const Rect.fromLTWH(300, 100, 400, 340),
    );
    await pumpShell(tester, container);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey('desktop-resize-left-$id'))),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(400, 0));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      windowOf(container, id).rect,
      const Rect.fromLTWH(340, 100, WindowGeometry.minWidth, 340),
    );

    await flushSaves(tester);
  });

  testWidgets('resizing at the workspace edges keeps the anchored edge', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
      rect: const Rect.fromLTWH(100, 100, 400, 340),
    );
    await pumpShell(tester, container);

    /// Drags [handle] by [delta] and returns the resulting rect.
    Future<Rect> resizeBy(String handle, Offset delta) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('desktop-resize-$handle-$id'))),
      );
      await tester.pump();
      await gesture.moveBy(delta);
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();
      return windowOf(container, id).rect;
    }

    // Left edge pushed past the workspace edge: the right edge stays at 500.
    expect(
      await resizeBy('left', const Offset(-200, 0)),
      const Rect.fromLTWH(0, 100, 500, 340),
    );
    // Top edge pushed past the workspace edge: the bottom edge stays at 440.
    expect(
      await resizeBy('top', const Offset(0, -200)),
      const Rect.fromLTWH(0, 0, 500, 440),
    );

    // Right edge pushed past the workspace edge: the left edge stays at 700.
    controller.move(id, const Rect.fromLTWH(700, 100, 400, 340));
    await tester.pumpAndSettle();
    expect(
      await resizeBy('right', const Offset(200, 0)),
      const Rect.fromLTWH(700, 100, 500, 340),
    );
    // Bottom edge pushed past the workspace edge: the top edge stays at 400.
    controller.move(id, const Rect.fromLTWH(700, 400, 400, 340));
    await tester.pumpAndSettle();
    expect(
      await resizeBy('bottom', const Offset(0, 200)),
      const Rect.fromLTWH(700, 400, 400, 436),
    );

    await flushSaves(tester);
  });

  testWidgets('dragging a maximised window leaves it maximised and unmoved', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
      rect: const Rect.fromLTWH(300, 100, 400, 340),
    );
    controller.toggleMaximize(id);
    await pumpShell(tester, container);

    final gesture = await beginTitleDrag(
      tester,
      find.byKey(ValueKey('desktop-title-$id')),
    );
    await gesture.moveBy(const Offset(-500, 0));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    final window = windowOf(container, id);
    expect(window.isMaximized, isTrue);
    expect(window.rect, const Rect.fromLTWH(300, 100, 400, 340));

    await flushSaves(tester);
  });

  testWidgets('every resize handle shows its resize cursor', (tester) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
      rect: const Rect.fromLTWH(100, 100, 400, 340),
    );
    await pumpShell(tester, container);

    const cursors = {
      'left': SystemMouseCursors.resizeLeftRight,
      'right': SystemMouseCursors.resizeLeftRight,
      'top': SystemMouseCursors.resizeUpDown,
      'bottom': SystemMouseCursors.resizeUpDown,
      'top-left': SystemMouseCursors.resizeUpLeftDownRight,
      'bottom-right': SystemMouseCursors.resizeUpLeftDownRight,
      'top-right': SystemMouseCursors.resizeUpRightDownLeft,
      'bottom-left': SystemMouseCursors.resizeUpRightDownLeft,
    };
    for (final entry in cursors.entries) {
      final region = tester.widget<MouseRegion>(
        find.byKey(ValueKey('desktop-resize-${entry.key}-$id')),
      );
      expect(region.cursor, entry.value, reason: entry.key);
    }

    await flushSaves(tester);
  });

  testWidgets('a maximised window shows no resize handles', (tester) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    await pumpShell(tester, container);
    expect(find.byKey(ValueKey('desktop-resize-right-$id')), findsOneWidget);

    controller.toggleMaximize(id);
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('desktop-resize-right-$id')), findsNothing);

    await flushSaves(tester);
  });

  testWidgets('double-tapping the title bar toggles maximise', (tester) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    await pumpShell(tester, container);

    final title = find.byKey(ValueKey('desktop-title-$id'));
    await tester.tap(title);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(title);
    await tester.pumpAndSettle();

    expect(windowOf(container, id).isMaximized, isTrue);

    await tester.tap(title);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(title);
    await tester.pumpAndSettle();

    expect(windowOf(container, id).isMaximized, isFalse);

    await flushSaves(tester);
  });

  testWidgets('pressing a control in a background window focuses it', (
    tester,
  ) async {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final settings = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
      rect: const Rect.fromLTWH(0, 0, 500, 500),
    );
    controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'Chat',
      rect: const Rect.fromLTWH(700, 400, 500, 500),
    );
    await pumpShell(
      tester,
      container,
      screenBuilder: (window) => Center(
        child: FilledButton(
          onPressed: () {},
          child: Text('action:${window.title}'),
        ),
      ),
    );

    await tester.tap(find.text('action:Settings'));
    await tester.pumpAndSettle();

    expect(
      container.read(desktopWindowControllerProvider).focusedWindowId,
      settings,
    );

    await flushSaves(tester);
  });
}
