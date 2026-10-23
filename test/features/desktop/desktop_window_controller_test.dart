import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/features/desktop/data/desktop_layout_store.dart';
import 'package:localmind/features/desktop/data/models/desktop_window.dart';
import 'package:localmind/features/desktop/providers/desktop_window_providers.dart';
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

  test('opens one tab per conversation and focuses the newest', () {
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

  test('reopening the same conversation focuses the existing tab', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final id = controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'One',
    );
    controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c2',
      title: 'Two',
    );

    final again = controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'c1',
      title: 'One',
    );

    final layout = container.read(desktopWindowControllerProvider);
    expect(again, id);
    expect(layout.windows, hasLength(2));
    expect(layout.focusedWindowId, id);
  });

  test('opens one utility tab per kind and focuses it', () {
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
    expect(layout.windows.map((w) => w.id), contains(chat));
  });

  test('closing a tab activates the next one, then the previous', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final first = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    final second = controller.open(
      kind: DesktopWindowKind.skills,
      title: 'Skills',
    );
    final third = controller.open(
      kind: DesktopWindowKind.servers,
      title: 'Servers',
    );
    controller.focus(second);

    controller.close(second);
    expect(
      container.read(desktopWindowControllerProvider).focusedWindowId,
      third,
    );

    controller.close(third);
    expect(
      container.read(desktopWindowControllerProvider).focusedWindowId,
      first,
    );

    controller.close(first);
    final layout = container.read(desktopWindowControllerProvider);
    expect(layout.windows, isEmpty);
    expect(layout.focusedWindowId, isNull);
  });

  test('closing an inactive tab keeps the current focus', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final first = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    final second = controller.open(
      kind: DesktopWindowKind.skills,
      title: 'Skills',
    );
    controller.focus(second);

    controller.close(first);

    expect(
      container.read(desktopWindowControllerProvider).focusedWindowId,
      second,
    );
  });

  test('focus activates an open tab and ignores unknown ids', () {
    final container = createContainer();
    final controller = container.read(desktopWindowControllerProvider.notifier);
    final first = controller.open(
      kind: DesktopWindowKind.settings,
      title: 'Settings',
    );
    controller.open(kind: DesktopWindowKind.skills, title: 'Skills');

    controller.focus(first);
    expect(
      container.read(desktopWindowControllerProvider).focusedWindowId,
      first,
    );

    controller.focus('missing');
    expect(
      container.read(desktopWindowControllerProvider).focusedWindowId,
      first,
    );
  });

  test('updateTitle renames an existing tab and ignores unknown ids', () {
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
    controller.updateTitle('missing', 'Ignored');

    expect(container.read(desktopWindowControllerProvider), before);
  });

  test('restores the saved layout on the next build', () async {
    final store = DesktopLayoutStore(prefs);
    await store.save(
      const DesktopLayout(
        windows: [
          DesktopWindowState(
            id: 'w1',
            kind: DesktopWindowKind.settings,
            title: 'Settings',
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
    'a new tab gets an id that does not collide with restored ones',
    () async {
      await DesktopLayoutStore(prefs).save(
        const DesktopLayout(
          windows: [
            DesktopWindowState(
              id: 'w1',
              kind: DesktopWindowKind.settings,
              title: 'Settings',
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
