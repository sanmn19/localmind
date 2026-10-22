import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/components/app_sizes.dart';
import '../../data/models/desktop_window.dart';
import '../../providers/desktop_window_providers.dart';
import 'desktop_window_title_bar.dart';

/// Builds the screen hosted by one desktop window.
typedef DesktopScreenBuilder = Widget Function(DesktopWindowState window);

/// One floating window on the desktop workspace.
///
/// The frame is responsible for its position, chrome and window controls. It does
/// not own its geometry: every interaction is delegated to
/// [DesktopWindowController].
class DesktopWindowFrame extends ConsumerWidget {
  const DesktopWindowFrame({
    super.key,
    required this.window,
    required this.isFocused,
    required this.screenBuilder,
  });

  final DesktopWindowState window;
  final bool isFocused;
  final DesktopScreenBuilder screenBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(desktopWindowControllerProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;

    final frame = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => controller.focus(window.id),
      child: Material(
        color: colorScheme.surface,
        elevation: isFocused ? 16 : 6,
        shadowColor: Colors.black.withValues(alpha: 0.3),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizes.radiusLg),
          side: BorderSide(
            color: isFocused ? colorScheme.primary : colorScheme.outline,
            width: isFocused ? 1.5 : 1,
          ),
        ),
        child: Column(
          children: [
            DesktopWindowTitleBar(
              key: ValueKey('desktop-title-${window.id}'),
              window: window,
              isFocused: isFocused,
              onClose: () => controller.close(window.id),
              onMinimize: () => controller.minimize(window.id),
              onMaximize: () => controller.toggleMaximize(window.id),
            ),
            Expanded(child: screenBuilder(window)),
          ],
        ),
      ),
    );

    if (window.isMaximized) {
      return Positioned.fill(child: frame);
    }
    return Positioned.fromRect(rect: window.rect, child: frame);
  }
}
