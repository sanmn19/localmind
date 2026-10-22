import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/desktop/data/models/desktop_window.dart';

void main() {
  const window = DesktopWindowState(
    id: 'w1',
    kind: DesktopWindowKind.chat,
    title: 'Trip planning',
    route: '/chat/c1',
    conversationId: 'c1',
  );

  group('DesktopWindowState', () {
    test('round-trips through JSON', () {
      final restored = DesktopWindowState.fromJson(window.toJson());

      expect(restored, window);
    });

    test('writes the tab fields', () {
      final json = window.toJson();

      expect(json['id'], 'w1');
      expect(json['kind'], 'chat');
      expect(json['title'], 'Trip planning');
      expect(json['route'], '/chat/c1');
      expect(json['conversationId'], 'c1');
    });

    test('ignores the fields of the old floating layout', () {
      final json = window.toJson()
        ..['left'] = 10.0
        ..['top'] = 20.0
        ..['width'] = 600.0
        ..['height'] = 400.0
        ..['zIndex'] = 3
        ..['isMinimized'] = true
        ..['isMaximized'] = true;

      expect(DesktopWindowState.fromJson(json), window);
    });

    test('defaults a missing title and optional fields', () {
      final restored = DesktopWindowState.fromJson({
        'id': 'w2',
        'kind': 'settings',
      });

      expect(restored!.title, 'Settings');
      expect(restored.route, isNull);
      expect(restored.conversationId, isNull);
    });

    test('returns null for an unknown kind', () {
      final json = window.toJson()..['kind'] = 'spaceship';

      expect(DesktopWindowState.fromJson(json), isNull);
    });

    test('returns null when the id is missing', () {
      expect(DesktopWindowState.fromJson({'kind': 'chat'}), isNull);
      expect(DesktopWindowState.fromJson('nope'), isNull);
    });

    test('copyWith clears the optional fields', () {
      final cleared = window.copyWith(
        clearRoute: true,
        clearConversationId: true,
        title: 'Renamed',
      );

      expect(cleared.route, isNull);
      expect(cleared.conversationId, isNull);
      expect(cleared.title, 'Renamed');
    });
  });

  group('DesktopLayout', () {
    test('focusedWindow returns the focused tab or null', () {
      const layout = DesktopLayout(
        windows: [
          DesktopWindowState(
            id: 'w1',
            kind: DesktopWindowKind.settings,
            title: 'Settings',
          ),
          DesktopWindowState(
            id: 'w2',
            kind: DesktopWindowKind.chat,
            title: 'One',
            conversationId: 'c1',
          ),
        ],
        focusedWindowId: 'w2',
      );

      expect(layout.focusedWindow?.id, 'w2');
      expect(layout.copyWith(clearFocusedWindow: true).focusedWindow, isNull);
    });

    test('round-trips through JSON', () {
      const layout = DesktopLayout(
        windows: [
          DesktopWindowState(
            id: 'w1',
            kind: DesktopWindowKind.settings,
            title: 'Settings',
          ),
        ],
        focusedWindowId: 'w1',
      );

      expect(DesktopLayout.fromJson(layout.toJson()), layout);
    });

    test('skips tabs with an unknown kind', () {
      final json = {
        'windows': [window.toJson(), (window.toJson()..['kind'] = 'spaceship')],
        'focusedWindowId': 'w1',
      };

      final layout = DesktopLayout.fromJson(json);

      expect(layout!.windows, hasLength(1));
      expect(layout.focusedWindowId, 'w1');
    });

    test('drops a focused id that no longer has a tab', () {
      final layout = DesktopLayout.fromJson({
        'windows': [(window.toJson()..['kind'] = 'spaceship')],
        'focusedWindowId': 'w1',
      });

      expect(layout!.windows, isEmpty);
      expect(layout.focusedWindowId, isNull);
    });

    test('reads a layout without a window list as empty', () {
      expect(
        DesktopLayout.fromJson(const <String, Object?>{})!.windows,
        isEmpty,
      );
    });

    test('returns null for corrupt JSON', () {
      expect(DesktopLayout.fromJson('{not json'), isNull);
      expect(DesktopLayout.fromJson({'windows': 'nope'}), isNull);
    });
  });
}
