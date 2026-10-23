import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/desktop/data/desktop_layout_store.dart';
import 'package:localmind/features/desktop/data/models/desktop_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('round-trips a layout and ignores corrupt JSON', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = DesktopLayoutStore(prefs);
    expect(store.load(), isNull);
    final layout = DesktopLayout(
      windows: [
        const DesktopWindowState(
          id: 'w1',
          kind: DesktopWindowKind.settings,
          title: 'Settings',
        ),
      ],
      focusedWindowId: 'w1',
    );
    await store.save(layout);
    expect(store.load()!.windows.single.title, 'Settings');
    await prefs.setString(DesktopLayoutStore.key, '{not json');
    expect(store.load(), isNull);
  });

  test('returns null when the stored value is not a JSON object', () async {
    SharedPreferences.setMockInitialValues({
      DesktopLayoutStore.key: '[1, 2, 3]',
    });
    final prefs = await SharedPreferences.getInstance();

    expect(DesktopLayoutStore(prefs).load(), isNull);
  });

  test('reads a layout written by the floating-window build', () async {
    SharedPreferences.setMockInitialValues({
      DesktopLayoutStore.key:
          '{"windows":[{"id":"w1","kind":"settings","title":"Settings",'
          '"left":120.0,"top":96.0,"width":720.0,"height":520.0,'
          '"zIndex":2,"isMinimized":false,"isMaximized":true}],'
          '"focusedWindowId":"w1"}',
    });
    final prefs = await SharedPreferences.getInstance();

    final layout = DesktopLayoutStore(prefs).load();

    expect(layout!.windows.single.id, 'w1');
    expect(layout.windows.single.kind, DesktopWindowKind.settings);
    expect(layout.windows.single.title, 'Settings');
    expect(layout.focusedWindowId, 'w1');
  });

  test('persists under the versioned key', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = DesktopLayoutStore(prefs);

    await store.save(const DesktopLayout());

    expect(prefs.getString(DesktopLayoutStore.key), isNotNull);
  });
}
