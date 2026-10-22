import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hugeicons/hugeicons.dart';

import '../../../../core/components/app_sizes.dart';
import '../../data/models/desktop_window.dart';
import '../../providers/desktop_window_providers.dart';

/// The bar under the workspace that brings minimised windows back and starts a
/// new chat.
class DesktopDock extends ConsumerWidget {
  const DesktopDock({super.key});

  /// The height reserved for the dock under the workspace.
  static const double height = 64;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final layout = ref.watch(desktopWindowControllerProvider);
    final controller = ref.read(desktopWindowControllerProvider.notifier);
    final minimised = [
      for (final window in layout.windows)
        if (window.isMinimized) window,
    ];

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(top: BorderSide(color: colorScheme.outline)),
      ),
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final window in minimised) ...[
                _DockEntry(
                  key: ValueKey('desktop-dock-entry-${window.title}'),
                  label: window.title,
                  icon: HugeIcons.strokeRoundedSquare,
                  onPressed: () => controller.restore(window.id),
                ),
                const SizedBox(width: AppSizes.sm),
              ],
              IconButton(
                key: const ValueKey('desktop-dock-new-chat'),
                onPressed: () => controller.open(kind: DesktopWindowKind.chat),
                icon: const HugeIcon(
                  icon: HugeIcons.strokeRoundedChatAdd01,
                  size: AppSizes.iconMd,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DockEntry extends StatelessWidget {
  const _DockEntry({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final List<List<dynamic>> icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: TextButton.icon(
        onPressed: onPressed,
        icon: HugeIcon(icon: icon, size: AppSizes.iconSm),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
