import 'dart:math' as math;
import 'dart:ui';

/// A region of a workspace a window can be snapped to.
enum DesktopSnapEdge { leftHalf, rightHalf, full, topHalf, bottomHalf }

/// Pure geometry helpers for placing the desktop window inside a workspace.
///
/// A workspace is the usable area of one display in global screen
/// coordinates, so none of these helpers assume an origin of (0, 0).
class WindowGeometry {
  const WindowGeometry._();

  /// The smallest width a window may be clamped to.
  static const double minWidth = 360;

  /// The smallest height a window may be clamped to.
  static const double minHeight = 320;

  /// Returns [rect] resized to at least the minimums and moved so that at
  /// least [minWidth] x [minHeight] of it stays inside [workspace].
  ///
  /// The width and height are kept as requested unless they are smaller than
  /// the minimums, so a window saved on a larger display is never shrunk.
  static Rect clamp(Rect rect, Rect workspace) {
    final width = math.max(rect.width, minWidth);
    final height = math.max(rect.height, minHeight);
    return Rect.fromLTWH(
      _clampAxis(rect.left, workspace.left, workspace.right - minWidth),
      _clampAxis(rect.top, workspace.top, workspace.bottom - minHeight),
      width,
      height,
    );
  }

  /// Returns the rectangle covering [edge] of [workspace].
  static Rect snapped(DesktopSnapEdge edge, Rect workspace) {
    final halfWidth = workspace.width / 2;
    final halfHeight = workspace.height / 2;
    return switch (edge) {
      DesktopSnapEdge.leftHalf => Rect.fromLTWH(
        workspace.left,
        workspace.top,
        halfWidth,
        workspace.height,
      ),
      DesktopSnapEdge.rightHalf => Rect.fromLTWH(
        workspace.left + halfWidth,
        workspace.top,
        halfWidth,
        workspace.height,
      ),
      DesktopSnapEdge.full => Rect.fromLTWH(
        workspace.left,
        workspace.top,
        workspace.width,
        workspace.height,
      ),
      DesktopSnapEdge.topHalf => Rect.fromLTWH(
        workspace.left,
        workspace.top,
        workspace.width,
        halfHeight,
      ),
      DesktopSnapEdge.bottomHalf => Rect.fromLTWH(
        workspace.left,
        workspace.top + halfHeight,
        workspace.width,
        halfHeight,
      ),
    };
  }

  /// Returns a [width] x [height] rectangle centred in [workspace].
  ///
  /// Requests smaller than the minimums are raised to them before centring.
  static Rect centered({
    required double width,
    required double height,
    required Rect workspace,
  }) {
    final safeWidth = math.max(width, minWidth);
    final safeHeight = math.max(height, minHeight);
    return Rect.fromLTWH(
      workspace.left + (workspace.width - safeWidth) / 2,
      workspace.top + (workspace.height - safeHeight) / 2,
      safeWidth,
      safeHeight,
    );
  }

  /// Clamps [value] to `[min, max]`, falling back to [min] when the
  /// workspace is too small to hold the minimum size at all.
  static double _clampAxis(double value, double min, double max) {
    if (max < min) return min;
    return value.clamp(min, max).toDouble();
  }
}
