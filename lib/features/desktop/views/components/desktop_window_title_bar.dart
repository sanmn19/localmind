import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

import '../../../../core/components/app_sizes.dart';
import '../../data/models/desktop_window.dart';

/// The title strip at the top of a floating window.
///
/// It only renders the title and the window controls; the owning
/// [DesktopWindowFrame] supplies the controller callbacks.
class DesktopWindowTitleBar extends StatelessWidget {
  const DesktopWindowTitleBar({
    super.key,
    required this.window,
    required this.isFocused,
    required this.onClose,
    required this.onMinimize,
    required this.onMaximize,
  });

  /// The window this bar belongs to.
  final DesktopWindowState window;

  /// Whether the window currently has focus.
  final bool isFocused;

  final VoidCallback onClose;
  final VoidCallback onMinimize;
  final VoidCallback onMaximize;

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
          Expanded(
            child: Text(
              window.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(color: titleColor),
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
