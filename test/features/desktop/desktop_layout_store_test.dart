import 'dart:ui';

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
          rect: Rect.fromLTWH(10, 20, 600, 400),
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

  test('persists under the versioned key', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = DesktopLayoutStore(prefs);

    await store.save(const DesktopLayout());

    expect(prefs.getString(DesktopLayoutStore.key), isNotNull);
  });
}
