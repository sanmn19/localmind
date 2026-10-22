import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

import '../../../../core/components/app_sizes.dart';
import '../../data/models/desktop_window.dart';

/// The title strip at the top of a floating window.
///
/// It only renders the title and the window controls; the owning
/// [DesktopWindowFrame] supplies the controller callbacks and owns the drag
/// state behind the move gestures.
class DesktopWindowTitleBar extends StatelessWidget {
  const DesktopWindowTitleBar({
    super.key,
    required this.window,
    required this.isFocused,
    required this.onClose,
    required this.onMinimize,
    required this.onMaximize,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    required this.onDoubleTap,
  });

  /// The window this bar belongs to.
  final DesktopWindowState window;

  /// Whether the window currently has focus.
  final bool isFocused;

  final VoidCallback onClose;
  final VoidCallback onMinimize;
  final VoidCallback onMaximize;

  /// Called when a move gesture starts on the bar.
  final GestureDragStartCallback onDragStart;

  /// Called with the movement since the last drag update.
  final GestureDragUpdateCallback onDragUpdate;

  /// Called when the move gesture ends.
  final GestureDragEndCallback onDragEnd;

  /// Called when the move gesture is cancelled by a competing gesture.
  final GestureDragCancelCallback onDragCancel;

  /// Called when the bar is double-tapped.
  final VoidCallback onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final titleColor = isFocused
        ? colorScheme.onSurface
        : colorScheme.onSurface.withValues(alpha: 0.7);

    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: AppSizes.md, right: AppSizes.xs),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(bottom: BorderSide(color: colorScheme.outline)),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppSizes.radiusLg),
        ),
      ),
      child: Row(
        children: [
          // Only the title area moves the window: a double tap here must not
          // delay the window controls by holding their gesture arena.
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: onDragStart,
              onPanUpdate: onDragUpdate,
              onPanEnd: onDragEnd,
              onPanCancel: onDragCancel,
              onDoubleTap: onDoubleTap,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  window.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: titleColor,
                  ),
                ),
              ),
            ),
          ),
          _WindowButton(
            key: ValueKey('desktop-minimize-${window.id}'),
            icon: HugeIcons.strokeRoundedMinusSign,
            onPressed: onMinimize,
          ),
          _WindowButton(
            key: ValueKey('desktop-maximize-${window.id}'),
            icon: HugeIcons.strokeRoundedMaximize01,
            onPressed: onMaximize,
          ),
          _WindowButton(
            key: ValueKey('desktop-close-${window.id}'),
            icon: HugeIcons.strokeRoundedCancel01,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({super.key, required this.icon, required this.onPressed});

  final List<List<dynamic>> icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      iconSize: AppSizes.iconSm,
      visualDensity: VisualDensity.compact,
      icon: HugeIcon(icon: icon, size: AppSizes.iconSm),
    );
  }
}
