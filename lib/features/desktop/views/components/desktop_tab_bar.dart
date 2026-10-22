import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hugeicons/hugeicons.dart';

import '../../../../core/components/app_sizes.dart';
import '../../data/models/desktop_window.dart';
import '../../providers/desktop_window_providers.dart';

/// The tab strip above the desktop workspace.
///
/// One tab per open window, in the order they were opened. The active tab is
/// highlighted; the strip scrolls horizontally when the tabs overflow, and the
/// trailing button starts a new chat.
class DesktopTabBar extends ConsumerWidget {
  const DesktopTabBar({super.key, required this.onNewChat});

  /// The height reserved for the tab strip above the workspace.
  static const double height = 44;

  /// Starts a new chat tab.
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final layout = ref.watch(desktopWindowControllerProvider);
    final controller = ref.read(desktopWindowControllerProvider.notifier);

    return Container(
      key: const ValueKey('desktop-tab-bar'),
      height: height,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(bottom: BorderSide(color: colorScheme.outline)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final window in layout.windows)
                    _DesktopTab(
                      key: ValueKey('desktop-tab-${window.id}'),
                      window: window,
                      isActive: layout.focusedWindowId == window.id,
                      onActivate: () => controller.focus(window.id),
                      onClose: () => controller.close(window.id),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('desktop-new-chat'),
            tooltip: 'New chat',
            onPressed: onNewChat,
            icon: const HugeIcon(
              icon: HugeIcons.strokeRoundedAdd01,
              size: AppSizes.iconSm,
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopTab extends StatelessWidget {
  const _DesktopTab({
    super.key,
    required this.window,
    required this.isActive,
    required this.onActivate,
    required this.onClose,
  });

  final DesktopWindowState window;
  final bool isActive;
  final VoidCallback onActivate;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final background = isActive
        ? colorScheme.surfaceContainerHighest
        : Colors.transparent;
    final foreground = isActive
        ? colorScheme.onSurface
        : colorScheme.onSurfaceVariant;
    const radius = BorderRadius.vertical(
      top: Radius.circular(AppSizes.radiusMd),
    );

    return Padding(
      padding: const EdgeInsets.only(top: AppSizes.xs),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 120, maxWidth: 220),
        child: Material(
          color: background,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onActivate,
            child: Padding(
              padding: const EdgeInsets.only(left: AppSizes.md),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      window.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: isActive
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  IconButton(
                    key: ValueKey('desktop-tab-close-${window.id}'),
                    tooltip: 'Close tab',
                    onPressed: onClose,
                    iconSize: AppSizes.iconSm,
                    visualDensity: VisualDensity.compact,
                    icon: HugeIcon(
                      icon: HugeIcons.strokeRoundedCancel01,
                      size: AppSizes.iconSm,
                      color: foreground,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
