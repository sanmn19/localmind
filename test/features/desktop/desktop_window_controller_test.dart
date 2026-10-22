import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/features/desktop/data/desktop_layout_store.dart';
import 'package:localmind/features/desktop/data/models/desktop_window.dart';
import 'package:localmind/features/desktop/providers/desktop_window_providers.dart';
import 'package:localmind/features/desktop/utils/window_geometry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Counts saves so the debounce can be observed without inspecting internals.
class _RecordingStore extends DesktopLayoutStore {
  _RecordingStore(super.preferences);

  int saveCount = 0;

  @override
  Future<void> save(DesktopLayout layout) {
    saveCount++;
    return super.save(layout);
  }
}

/// Fails every write; the controller must keep working regardless.
class _FailingStore extends DesktopLayoutStore {
  _FailingStore(super.preferences);

  @override
  Future<void> save(DesktopLayout layout) async {
    throw StateError('disk full');
  }
}

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ProviderContainer createContainer({DesktopLayoutStore? store}) {
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (store != null) desktopLayoutStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('opens one window per conversation and focuses the newest', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);

    final first = controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'One',
    );
    final second = controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c2',
      title: 'Two',
    );

    final layout = container.read(desktopWindowControllerProvider);
    expect(layout.windows, hasLength(2));
    expect(layout.focusedWindowId, second);
    expect(layout.windows.map((w) => w.id), containsAll([first, second]));

    controller.close(second);
    expect(
      container.read(desktopWindowControllerProvider).windows,
      hasLength(1),
    );
    expect(
      container.read(desktopWindowControllerProvider).focusedWindowId,
      first,
    );
  });

  test('reopening the same conversation focuses the existing window', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'One',
    );
    controller.minimize(id);
    final again = controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'One',
    );
    expect(again, id);
    expect(
      container
          .read(desktopWindowControllerProvider)
          .windows
          .single
          .isMinimized,
      isFalse,
    );
    expect(container.read(desktopWindowControllerProvider).focusedWindowId, id);
  });

  test('opens one utility window per kind and brings it to the front', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);

    final settings = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    final chat = controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'One',
    );
    final again = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );

    final layout = container.read(desktopWindowControllerProvider);
    expect(again, settings);
    expect(layout.windows, hasLength(2));
    expect(layout.focusedWindowId, settings);
    expect(
      layout.windows.firstWhere((w) => w.id == settings).zIndex,
      greaterThan(layout.windows.firstWhere((w) => w.id == chat).zIndex),
    );
  });

  test('move and resize keep the raw rect until a workspace is known', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );

    controller.move(id, const Rect.fromLTWH(5000, -400, 900, 700));
    controller.resize(id, const Rect.fromLTWH(5000, -400, 100, 100));

    final window = container
        .read(desktopWindowControllerProvider)
        .windows
        .single;
    expect(window.rect, const Rect.fromLTWH(5000, -400, 100, 100));
  });

  test('move and resize clamp inside the workspace once it is known', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    controller.setWorkspace(const Rect.fromLTWH(0, 0, 1200, 800));
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );

    controller.move(id, const Rect.fromLTWH(5000, -400, 900, 700));
    var window = container.read(desktopWindowControllerProvider).windows.single;
    expect(window.rect, const Rect.fromLTWH(840, 0, 900, 700));

    controller.resize(id, const Rect.fromLTWH(10, 10, 100, 100));
    window = container.read(desktopWindowControllerProvider).windows.single;
    expect(window.rect, const Rect.fromLTWH(10, 10, 360, 320));
  });

  test('snap fills a workspace edge and clears the maximised flag', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    controller.setWorkspace(const Rect.fromLTWH(0, 0, 1200, 800));
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    controller.toggleMaximize(id);

    controller.snap(id, DesktopSnapEdge.rightHalf);

    final window = container
        .read(desktopWindowControllerProvider)
        .windows
        .single;
    expect(window.rect, const Rect.fromLTWH(600, 0, 600, 800));
    expect(window.isMaximized, isFalse);
  });

  test('snap without a workspace is a no-op', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    final before = container
        .read(desktopWindowControllerProvider)
        .windows
        .single;

    controller.snap(id, DesktopSnapEdge.full);

    expect(
      container.read(desktopWindowControllerProvider).windows.single,
      before,
    );
  });

  test('setWorkspace pulls every saved window back on screen', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
      rect: const Rect.fromLTWH(4000, 3000, 700, 500),
    );
    controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'One',
      rect: const Rect.fromLTWH(-800, -800, 700, 500),
    );

    controller.setWorkspace(const Rect.fromLTWH(0, 0, 1200, 800));

    final rects = container
        .read(desktopWindowControllerProvider)
        .windows
        .map((w) => w.rect);
    expect(rects, contains(const Rect.fromLTWH(840, 480, 700, 500)));
    expect(rects, contains(const Rect.fromLTWH(0, 0, 700, 500)));
  });

  test(
    'minimize focuses the next topmost window and clears focus when empty',
    () {
      final container = createContainer();
      final controller = container.read(
        desktopWindowControllerProvider.notifier,
      );
      final settings = controller.open(
        kind: DesktopWindowKind.settings,
        title: 'Settings',
      );
      final chat = controller.open(
        kind: DesktopWindowKind.chat,
        conversationId: 'c1',
        title: 'One',
      );

      controller.minimize(chat);
      var layout = container.read(desktopWindowControllerProvider);
      expect(layout.focusedWindowId, settings);
      expect(
        layout.windows.firstWhere((w) => w.id == chat).isMinimized,
        isTrue,
      );

      controller.minimize(settings);
      layout = container.read(desktopWindowControllerProvider);
      expect(layout.focusedWindowId, isNull);
    },
  );

  test('restore un-minimises and focuses the window', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final settings = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    final chat = controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'One',
    );
    controller.minimize(chat);

    controller.restore(chat);

    final layout = container.read(desktopWindowControllerProvider);
    expect(layout.focusedWindowId, chat);
    expect(layout.windows.firstWhere((w) => w.id == chat).isMinimized, isFalse);
    expect(
      layout.windows.firstWhere((w) => w.id == chat).zIndex,
      greaterThan(layout.windows.firstWhere((w) => w.id == settings).zIndex),
    );
  });

  test('toggleMaximize flips the flag and leaves the rect untouched', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
      rect: const Rect.fromLTWH(40, 50, 600, 400),
    );

    controller.toggleMaximize(id);
    var window = container.read(desktopWindowControllerProvider).windows.single;
    expect(window.isMaximized, isTrue);
    expect(window.rect, const Rect.fromLTWH(40, 50, 600, 400));

    controller.toggleMaximize(id);
    window = container.read(desktopWindowControllerProvider).windows.single;
    expect(window.isMaximized, isFalse);
  });

  test('updateTitle renames an existing window and ignores unknown ids', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'New chat',
    );

    controller.updateTitle(id, 'Trip planning');
    controller.updateTitle('missing', 'Ignored');

    final layout = container.read(desktopWindowControllerProvider);
    expect(layout.windows.single.title, 'Trip planning');
    expect(layout.focusedWindowId, id);
  });

  test('unknown ids are ignored by every mutation', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    controller.open(kind: DesktopWindowKind.settings, title: 'Settings');
    final before = container.read(desktopWindowControllerProvider);

    controller.close('missing');
    controller.focus('missing');
    controller.minimize('missing');
    controller.restore('missing');
    controller.toggleMaximize('missing');
    controller.move('missing', const Rect.fromLTWH(0, 0, 500, 500));
    controller.resize('missing', const Rect.fromLTWH(0, 0, 500, 500));

    expect(container.read(desktopWindowControllerProvider), before);
  });

  test('restores the saved layout on the next build', () async {
    final store = DesktopLayoutStore(prefs);
    await store.save(
      DesktopLayout(
        windows: [
          const DesktopWindowState(
            id: 'w1',
            kind: DesktopWindowKind.settings,
            title: 'Settings',
            rect: Rect.fromLTWH(10, 20, 600, 400),
            zIndex: 3,
          ),
        ],
        focusedWindowId: 'w1',
      ),
    );

    final container = createContainer(store: store);
    final layout = container.read(desktopWindowControllerProvider);

    expect(layout.windows.single.id, 'w1');
    expect(layout.windows.single.title, 'Settings');
    expect(layout.focusedWindowId, 'w1');
  });

  test(
    'a new window gets an id that does not collide with restored ones',
    () async {
      await DesktopLayoutStore(prefs).save(
        DesktopLayout(
          windows: [
            const DesktopWindowState(
              id: 'w1',
              kind: DesktopWindowKind.settings,
              title: 'Settings',
              rect: Rect.fromLTWH(10, 20, 600, 400),
            ),
          ],
          focusedWindowId: 'w1',
        ),
      );

      final container = createContainer();
      final controller = container.read(
        desktopWindowControllerProvider.notifier,
      );
      final opened = controller.open(
        kind: DesktopWindowKind.chat,
        conversationId: 'c1',
        title: 'One',
      );

      expect(opened, isNot('w1'));
      expect(
        container.read(desktopWindowControllerProvider).windows,
        hasLength(2),
      );
    },
  );

  test('persists once after the debounce window', () async {
    final store = _RecordingStore(prefs);
    final container = createContainer(store: store);
    final controller = container.read(desktopWindowControllerProvider.notifier);

    controller.open(kind: DesktopWindowKind.settings, title: 'Settings');
    controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'One',
    );

    // Nothing is written while the burst is still in flight.
    expect(store.saveCount, 0);
    // Longer than the controller's 300 ms debounce.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(store.saveCount, 1);
    expect(DesktopLayoutStore(prefs).load()!.windows, hasLength(2));
  });

  test('a failing save never breaks interaction', () async {
    final container = createContainer(store: _FailingStore(prefs));
    final controller = container.read(desktopWindowControllerProvider.notifier);

    final id = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    // Let the failing debounced write run; an unhandled error fails the test.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    controller.close(id);

    expect(container.read(desktopWindowControllerProvider).windows, isEmpty);
  });
}
