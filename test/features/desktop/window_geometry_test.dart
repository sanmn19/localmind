import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/desktop/utils/window_geometry.dart';

void main() {
  const workspace = Rect.fromLTWH(0, 0, 1200, 800);

  group('WindowGeometry.clamp', () {
    test('clamps a window saved off-screen back into the workspace', () {
      const saved = Rect.fromLTWH(2000, -400, 900, 700);
      final rect = WindowGeometry.clamp(saved, workspace);
      expect(rect.left, 1200 - 360);
      expect(rect.top, 0);
      expect(rect.width, 900);
      expect(rect.height, 700);
    });

    test('leaves a window already inside the workspace untouched', () {
      const saved = Rect.fromLTWH(120, 80, 900, 700);
      final rect = WindowGeometry.clamp(saved, workspace);
      expect(rect, saved);
    });

    test('pulls a window saved off the top-left back into the workspace', () {
      const saved = Rect.fromLTWH(-500, -300, 800, 600);
      final rect = WindowGeometry.clamp(saved, workspace);
      expect(rect.left, 0);
      expect(rect.top, 0);
      expect(rect.width, 800);
      expect(rect.height, 600);
    });

    test('raises an undersized window to the minimum size', () {
      const saved = Rect.fromLTWH(10, 10, 100, 100);
      final rect = WindowGeometry.clamp(saved, workspace);
      expect(rect.left, 10);
      expect(rect.top, 10);
      expect(rect.width, WindowGeometry.minWidth);
      expect(rect.height, WindowGeometry.minHeight);
    });

    test('respects a workspace that does not start at the origin', () {
      const secondary = Rect.fromLTWH(1200, 0, 800, 600);
      const saved = Rect.fromLTWH(-2000, -900, 600, 500);
      final rect = WindowGeometry.clamp(saved, secondary);
      expect(rect.left, 1200);
      expect(rect.top, 0);
      expect(rect.width, 600);
      expect(rect.height, 500);
    });
  });

  group('WindowGeometry.snapped', () {
    test('snaps to the left half of the workspace', () {
      final rect = WindowGeometry.snapped(DesktopSnapEdge.leftHalf, workspace);
      expect(rect.left, 0);
      expect(rect.width, 600);
      expect(rect.height, 800);
    });

    test('snaps to the right half of the workspace', () {
      final rect = WindowGeometry.snapped(DesktopSnapEdge.rightHalf, workspace);
      expect(rect.left, 600);
      expect(rect.top, 0);
      expect(rect.width, 600);
      expect(rect.height, 800);
    });

    test('snaps to the full workspace', () {
      final rect = WindowGeometry.snapped(DesktopSnapEdge.full, workspace);
      expect(rect, workspace);
    });

    test('snaps to the top half of the workspace', () {
      final rect = WindowGeometry.snapped(DesktopSnapEdge.topHalf, workspace);
      expect(rect.left, 0);
      expect(rect.top, 0);
      expect(rect.width, 1200);
      expect(rect.height, 400);
    });

    test('snaps to the bottom half of the workspace', () {
      final rect = WindowGeometry.snapped(
        DesktopSnapEdge.bottomHalf,
        workspace,
      );
      expect(rect.left, 0);
      expect(rect.top, 400);
      expect(rect.width, 1200);
      expect(rect.height, 400);
    });

    test('uses the workspace origin rather than the screen origin', () {
      const secondary = Rect.fromLTWH(1200, 100, 800, 600);
      final rect = WindowGeometry.snapped(DesktopSnapEdge.rightHalf, secondary);
      expect(rect.left, 1600);
      expect(rect.top, 100);
      expect(rect.width, 400);
      expect(rect.height, 600);
    });
  });

  group('WindowGeometry.centered', () {
    test('centres the requested size in the workspace', () {
      final rect = WindowGeometry.centered(
        width: 800,
        height: 600,
        workspace: workspace,
      );
      expect(rect.left, 200);
      expect(rect.top, 100);
      expect(rect.width, 800);
      expect(rect.height, 600);
    });

    test('raises an undersized request to the minimum before centring', () {
      final rect = WindowGeometry.centered(
        width: 100,
        height: 100,
        workspace: workspace,
      );
      expect(rect.width, WindowGeometry.minWidth);
      expect(rect.height, WindowGeometry.minHeight);
      expect(rect.left, (1200 - WindowGeometry.minWidth) / 2);
      expect(rect.top, (800 - WindowGeometry.minHeight) / 2);
    });

    test('centres within a workspace that does not start at the origin', () {
      const secondary = Rect.fromLTWH(1200, 100, 800, 600);
      final rect = WindowGeometry.centered(
        width: 400,
        height: 400,
        workspace: secondary,
      );
      expect(rect.left, 1400);
      expect(rect.top, 200);
    });
  });
}
