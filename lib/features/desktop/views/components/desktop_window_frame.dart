import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/components/app_sizes.dart';
import '../../data/models/desktop_window.dart';
import '../../providers/desktop_window_providers.dart';
import '../../utils/window_geometry.dart';
import 'desktop_window_title_bar.dart';

/// Builds the screen hosted by one desktop window.
typedef DesktopScreenBuilder = Widget Function(DesktopWindowState window);

/// One floating window on the desktop workspace.
///
/// The frame renders its window at a rect clamped to the current [workspace] so a
/// restored off-screen layout is never painted outside the canvas. It does not own
/// its geometry: every mutation is delegated to [DesktopWindowController]. The
/// drag and resize gestures only keep the rect a gesture started from; the
/// controller stays the source of truth between gestures.
class DesktopWindowFrame extends ConsumerStatefulWidget {
  const DesktopWindowFrame({
    super.key,
    required this.window,
    required this.workspace,
    required this.isFocused,
    required this.screenBuilder,
  });

  final DesktopWindowState window;
  final Rect workspace;
  final bool isFocused;
  final DesktopScreenBuilder screenBuilder;

  @override
  ConsumerState<DesktopWindowFrame> createState() => _DesktopWindowFrameState();
}

class _DesktopWindowFrameState extends ConsumerState<DesktopWindowFrame> {
  /// How close a dropped window must end to a workspace edge to snap there.
  static const double _snapDistance = 24;

  /// The thickness of an edge resize handle.
  static const double _edgeThickness = 8;

  /// The side of a corner resize handle.
  static const double _cornerSize = 12;

  /// The rect the active gesture started from, or `null` when none is active.
  Rect? _startRect;

  /// The movement applied since [_startRect] was captured.
  Offset _dragDelta = Offset.zero;

  /// The handle of the active resize, or `null` while moving.
  _ResizeHandle? _resizeHandle;

  DesktopWindowController get _controller =>
      ref.read(desktopWindowControllerProvider.notifier);

  Rect get _renderedRect =>
      WindowGeometry.clamp(widget.window.rect, widget.workspace);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final window = widget.window;

    final body = Listener(
      // Focus on the press, not only on taps the screen does not consume: a
      // control inside a background window must raise it too. This also keeps a
      // tap recognizer out of the arena, so a tap on the title never waits for
      // its double tap.
      onPointerDown: (_) => _focus(),
      child: Material(
        color: colorScheme.surface,
        elevation: widget.isFocused ? 16 : 6,
        shadowColor: Colors.black.withValues(alpha: 0.3),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizes.radiusLg),
          side: BorderSide(
            color: widget.isFocused ? colorScheme.primary : colorScheme.outline,
            width: widget.isFocused ? 1.5 : 1,
          ),
        ),
        child: Column(
          children: [
            DesktopWindowTitleBar(
              key: ValueKey('desktop-title-${window.id}'),
              window: window,
              isFocused: widget.isFocused,
              onClose: () => _controller.close(window.id),
              onMinimize: () => _controller.minimize(window.id),
              onMaximize: () => _controller.toggleMaximize(window.id),
              onDragStart: (_) => _startMove(),
              onDragUpdate: (details) => _applyDelta(details.delta),
              onDragEnd: (_) => _endMove(),
              onDragCancel: _resetGesture,
              onDoubleTap: () => _controller.toggleMaximize(window.id),
            ),
            Expanded(child: widget.screenBuilder(window)),
          ],
        ),
      ),
    );

    if (window.isMaximized) {
      return Positioned.fill(child: body);
    }
    return Positioned.fromRect(
      rect: _renderedRect,
      child: Stack(
        children: [
          Positioned.fill(child: body),
          for (final handle in _ResizeHandle.values) _buildHandle(handle),
        ],
      ),
    );
  }

  Widget _buildHandle(_ResizeHandle handle) {
    const inset = _cornerSize;
    final area = MouseRegion(
      key: ValueKey('desktop-resize-${handle.keyName}-${widget.window.id}'),
      cursor: handle.cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => _startResize(handle),
        onPanUpdate: (details) => _applyDelta(details.delta),
        onPanEnd: (_) => _resetGesture(),
        onPanCancel: _resetGesture,
        child: const SizedBox.expand(),
      ),
    );

    return switch (handle) {
      _ResizeHandle.left => Positioned(
        left: 0,
        top: inset,
        bottom: inset,
        width: _edgeThickness,
        child: area,
      ),
      _ResizeHandle.right => Positioned(
        right: 0,
        top: inset,
        bottom: inset,
        width: _edgeThickness,
        child: area,
      ),
      _ResizeHandle.top => Positioned(
        top: 0,
        left: inset,
        right: inset,
        height: _edgeThickness,
        child: area,
      ),
      _ResizeHandle.bottom => Positioned(
        bottom: 0,
        left: inset,
        right: inset,
        height: _edgeThickness,
        child: area,
      ),
      _ResizeHandle.topLeft => Positioned(
        left: 0,
        top: 0,
        width: _cornerSize,
        height: _cornerSize,
        child: area,
      ),
      _ResizeHandle.topRight => Positioned(
        right: 0,
        top: 0,
        width: _cornerSize,
        height: _cornerSize,
        child: area,
      ),
      _ResizeHandle.bottomLeft => Positioned(
        left: 0,
        bottom: 0,
        width: _cornerSize,
        height: _cornerSize,
        child: area,
      ),
      _ResizeHandle.bottomRight => Positioned(
        right: 0,
        bottom: 0,
        width: _cornerSize,
        height: _cornerSize,
        child: area,
      ),
    };
  }

  void _focus() => _controller.focus(widget.window.id);

  void _startMove() {
    // A maximised window has no free rect to move: dragging it must not shift
    // the rect it would restore to, nor un-maximise it on an edge drop.
    if (widget.window.isMaximized) return;
    _startGesture(null);
    _focus();
  }

  void _startResize(_ResizeHandle handle) {
    _startGesture(handle);
    _focus();
  }

  void _startGesture(_ResizeHandle? handle) {
    _startRect = _renderedRect;
    _dragDelta = Offset.zero;
    _resizeHandle = handle;
  }

  void _applyDelta(Offset delta) {
    final start = _startRect;
    if (start == null) return;
    _dragDelta += delta;
    final handle = _resizeHandle;
    if (handle == null) {
      _controller.move(
        widget.window.id,
        start.translate(_dragDelta.dx, _dragDelta.dy),
      );
    } else {
      _controller.resize(
        widget.window.id,
        handle.resize(start, _dragDelta, widget.workspace),
      );
    }
  }

  /// Snaps a dropped window to the workspace edge it was pushed onto.
  void _endMove() {
    final start = _startRect;
    final delta = _dragDelta;
    final resizing = _resizeHandle != null;
    _resetGesture();
    if (start == null || resizing) return;
    final edge = _snapEdgeFor(start.translate(delta.dx, delta.dy), delta);
    if (edge != null) _controller.snap(widget.window.id, edge);
  }

  void _resetGesture() {
    _startRect = null;
    _dragDelta = Offset.zero;
    _resizeHandle = null;
  }

  /// The workspace edge a drag released at [rect] snaps to, or `null`.
  ///
  /// Only an edge the drag moved towards counts, so a window that is already
  /// flush with the top of the workspace stays free when it is dragged sideways.
  DesktopSnapEdge? _snapEdgeFor(Rect rect, Offset delta) {
    final workspace = widget.workspace;
    final target = WindowGeometry.clamp(rect, workspace);
    if (delta.dx < 0 && target.left <= workspace.left + _snapDistance) {
      return DesktopSnapEdge.leftHalf;
    }
    if (delta.dx > 0 && target.right >= workspace.right - _snapDistance) {
      return DesktopSnapEdge.rightHalf;
    }
    if (delta.dy < 0 && target.top <= workspace.top + _snapDistance) {
      return DesktopSnapEdge.full;
    }
    return null;
  }
}

/// One of the eight edges or corners a window can be resized from.
enum _ResizeHandle {
  left,
  right,
  top,
  bottom,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight;

  bool get _movesLeft => this == left || this == topLeft || this == bottomLeft;

  bool get _movesRight =>
      this == right || this == topRight || this == bottomRight;

  bool get _movesTop => this == top || this == topLeft || this == topRight;

  bool get _movesBottom =>
      this == bottom || this == bottomLeft || this == bottomRight;

  /// The suffix of this handle's widget key.
  String get keyName => switch (this) {
    left => 'left',
    right => 'right',
    top => 'top',
    bottom => 'bottom',
    topLeft => 'top-left',
    topRight => 'top-right',
    bottomLeft => 'bottom-left',
    bottomRight => 'bottom-right',
  };

  /// The cursor shown while hovering this handle.
  MouseCursor get cursor => switch (this) {
    left || right => SystemMouseCursors.resizeLeftRight,
    top || bottom => SystemMouseCursors.resizeUpDown,
    topLeft || bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
    topRight || bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
  };

  /// Returns [start] resized by [delta] from this handle.
  ///
  /// The moving edges stop at the [workspace] boundary so the anchored edge can
  /// never shift: the controller clamps the whole rect afterwards by moving its
  /// left/top only, which would drag an anchored edge with it.
  ///
  /// The dragged edge also stops once the window reaches
  /// [WindowGeometry.minWidth] / [WindowGeometry.minHeight] so a resize never
  /// flips the rect inside out.
  Rect resize(Rect start, Offset delta, Rect workspace) {
    var left = start.left;
    var top = start.top;
    var right = start.right;
    var bottom = start.bottom;
    if (_movesLeft) left = math.max(workspace.left, left + delta.dx);
    if (_movesRight) right = math.min(workspace.right, right + delta.dx);
    if (_movesTop) top = math.max(workspace.top, top + delta.dy);
    if (_movesBottom) bottom = math.min(workspace.bottom, bottom + delta.dy);
    if (right - left < WindowGeometry.minWidth) {
      if (_movesLeft) {
        left = right - WindowGeometry.minWidth;
      } else {
        right = left + WindowGeometry.minWidth;
      }
    }
    if (bottom - top < WindowGeometry.minHeight) {
      if (_movesTop) {
        top = bottom - WindowGeometry.minHeight;
      } else {
        bottom = top + WindowGeometry.minHeight;
      }
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }
}
