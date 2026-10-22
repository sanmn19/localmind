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

  static const double _minTabWidth = 140;
  static const double _maxTabWidth = 240;
  static const double _newChatWidth = 44;

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
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Every tab gets the same width, and the width shrinks as tabs are
          // added so the strip only scrolls once the tabs reach their minimum.
          final available = constraints.maxWidth - _newChatWidth;
          final count = layout.windows.length;
          final tabWidth = count == 0
              ? 0.0
              : (available / count).clamp(_minTabWidth, _maxTabWidth);
          return Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (
                        var index = 0;
                        index < layout.windows.length;
                        index++
                      )
                        _DesktopTabWithSeparator(
                          window: layout.windows[index],
                          width: tabWidth,
                          isActive:
                              layout.focusedWindowId ==
                              layout.windows[index].id,
                          showSeparator: index > 0,
                          onActivate: () =>
                              controller.focus(layout.windows[index].id),
                          onClose: () =>
                              controller.close(layout.windows[index].id),
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
          );
        },
      ),
    );
  }
}

/// A tab plus the divider that separates it from the tab on its left.
class _DesktopTabWithSeparator extends StatelessWidget {
  const _DesktopTabWithSeparator({
    required this.window,
    required this.width,
    required this.isActive,
    required this.showSeparator,
    required this.onActivate,
    required this.onClose,
  });

  final DesktopWindowState window;
  final double width;
  final bool isActive;
  final bool showSeparator;
  final VoidCallback onActivate;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showSeparator)
          SizedBox(
            height: 18,
            child: VerticalDivider(
              width: 1,
              thickness: 1,
              color: colorScheme.outlineVariant,
            ),
          ),
        SizedBox(
          width: width,
          child: _DesktopTab(
            key: ValueKey('desktop-tab-${window.id}'),
            window: window,
            isActive: isActive,
            onActivate: onActivate,
            onClose: onClose,
          ),
        ),
      ],
    );
  }
}

class _DesktopTab extends StatefulWidget {
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
  State<_DesktopTab> createState() => _DesktopTabState();
}

class _DesktopTabState extends State<_DesktopTab> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isActive = widget.isActive;
    final background = isActive
        ? colorScheme.primary.withValues(alpha: 0.12)
        : Colors.transparent;
    final indicator = isActive ? colorScheme.primary : Colors.transparent;
    final foreground = isActive
        ? colorScheme.onSurface
        : colorScheme.onSurfaceVariant;
    // The close button is revealed on hover; the selected tab keeps it visible.
    final showClose = isActive || _isHovered;
    const radius = BorderRadius.vertical(
      top: Radius.circular(AppSizes.radiusMd),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Semantics(
        selected: isActive,
        button: true,
        label: widget.window.title,
        child: Padding(
          padding: const EdgeInsets.only(top: AppSizes.xs),
          child: Column(
            children: [
              Expanded(
                child: Material(
                  color: background,
                  borderRadius: radius,
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: widget.onActivate,
                    child: Padding(
                      padding: const EdgeInsets.only(left: AppSizes.md),
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              widget.window.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: foreground,
                                fontWeight: isActive
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                          AnimatedOpacity(
                            duration: const Duration(milliseconds: 120),
                            opacity: showClose ? 1 : 0,
                            child: IgnorePointer(
                              ignoring: !showClose,
                              child: IconButton(
                                key: ValueKey(
                                  'desktop-tab-close-${widget.window.id}',
                                ),
                                tooltip: 'Close tab',
                                onPressed: widget.onClose,
                                iconSize: AppSizes.iconSm,
                                visualDensity: VisualDensity.compact,
                                icon: HugeIcon(
                                  icon: HugeIcons.strokeRoundedCancel01,
                                  size: AppSizes.iconSm,
                                  color: foreground,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // The accent bar sits below the tab's body, so the body's own
              // background cannot cover it.
              ColoredBox(
                color: indicator,
                child: const SizedBox(height: 2, width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
