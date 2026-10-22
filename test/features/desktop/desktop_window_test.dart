import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/desktop/data/models/desktop_window.dart';

void main() {
  const window = DesktopWindowState(
    id: 'w1',
    kind: DesktopWindowKind.chat,
    title: 'Trip planning',
    rect: Rect.fromLTWH(10, 20, 600, 400),
    route: '/chat/c1',
    conversationId: 'c1',
    isMinimized: true,
    isMaximized: true,
    zIndex: 4,
  );

  group('DesktopWindowState', () {
    test('round-trips through JSON', () {
      final restored = DesktopWindowState.fromJson(window.toJson());

      expect(restored, window);
    });

    test('writes the rect as four numbers', () {
      final json = window.toJson();

      expect(json['left'], 10);
      expect(json['top'], 20);
      expect(json['width'], 600);
      expect(json['height'], 400);
      expect(json['kind'], 'chat');
      expect(json['conversationId'], 'c1');
    });

    test('returns null for an unknown kind', () {
      final json = window.toJson()..['kind'] = 'spaceship';

      expect(DesktopWindowState.fromJson(json), isNull);
    });

    test('returns null for a non-finite rect', () {
      for (final broken in ['left', 'top', 'width', 'height']) {
        final json = window.toJson()..[broken] = double.infinity;

        expect(
          DesktopWindowState.fromJson(json),
          isNull,
          reason: 'expected a non-finite $broken to be rejected',
        );
      }
    });

    test('returns null when required fields are missing', () {
      expect(DesktopWindowState.fromJson(<String, Object?>{}), isNull);
      expect(DesktopWindowState.fromJson('nope'), isNull);
    });
  });

  group('DesktopLayout', () {
    test('focusedWindow returns the focused window or null', () {
      const layout = DesktopLayout(
        windows: [
          DesktopWindowState(
            id: 'w1',
            kind: DesktopWindowKind.settings,
            title: 'Settings',
            rect: Rect.fromLTWH(0, 0, 600, 400),
          ),
          DesktopWindowState(
            id: 'w2',
            kind: DesktopWindowKind.chat,
            title: 'One',
            rect: Rect.fromLTWH(40, 40, 600, 400),
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
            rect: Rect.fromLTWH(0, 0, 600, 400),
            zIndex: 1,
          ),
        ],
        focusedWindowId: 'w1',
      );

      expect(DesktopLayout.fromJson(layout.toJson()), layout);
    });

    test('skips windows with a corrupt kind or rect', () {
      final json = {
        'windows': [
          window.toJson(),
          (window.toJson()..['kind'] = 'spaceship'),
          (window.toJson()..['left'] = double.nan),
        ],
        'focusedWindowId': 'w1',
      };

      final layout = DesktopLayout.fromJson(json);

      expect(layout!.windows, hasLength(1));
      expect(layout.focusedWindowId, 'w1');
    });

    test('drops a focused id that no longer has a window', () {
      final layout = DesktopLayout.fromJson({
        'windows': [(window.toJson()..['kind'] = 'spaceship')],
        'focusedWindowId': 'w1',
      });

      expect(layout!.windows, isEmpty);
      expect(layout.focusedWindowId, isNull);
    });

    test('returns null for corrupt JSON', () {
      expect(DesktopLayout.fromJson('{not json'), isNull);
      expect(DesktopLayout.fromJson({'windows': 'nope'}), isNull);
      expect(DesktopLayout.fromJson(const <String, Object?>{}), isNull);
    });
  });
}
