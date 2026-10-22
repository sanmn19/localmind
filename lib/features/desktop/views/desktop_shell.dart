import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/desktop_window_providers.dart';
import 'components/desktop_dock.dart';
import 'components/desktop_window_frame.dart';

/// The desktop canvas: a sidebar, a workspace of floating windows and a dock.
///
/// The shell owns the workspace rectangle and hands it to
/// [DesktopWindowController.setWorkspace] so restored layouts are clamped before
/// their frames are painted. It renders no platform-specific window chrome, which
/// keeps it usable in widget tests.
class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({
    super.key,
    required this.sidebar,
    required this.screenBuilder,
  });

  /// The navigation sidebar shown left of the workspace.
  final Widget sidebar;

  /// Builds the screen hosted by one window.
  final DesktopScreenBuilder screenBuilder;

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  Rect? _workspace;

  @override
  Widget build(BuildContext context) {
    ref.watch(desktopWindowControllerProvider);
    final theme = Theme.of(context);

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: Row(
        children: [
          widget.sidebar,
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      if (!constraints.hasBoundedWidth ||
                          !constraints.hasBoundedHeight) {
                        return const SizedBox.shrink();
                      }
                      final workspace = Rect.fromLTWH(
                        0,
                        0,
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      _syncWorkspace(workspace);
                      final layout = ref.read(desktopWindowControllerProvider);
                      final windows = [...layout.windows]
                        ..sort((a, b) => a.zIndex.compareTo(b.zIndex));
                      return Stack(
                        key: const ValueKey('desktop-workspace'),
                        clipBehavior: Clip.hardEdge,
                        children: [
                          for (final window in windows)
                            if (!window.isMinimized)
                              DesktopWindowFrame(
                                key: ValueKey('desktop-window-${window.id}'),
                                window: window,
                                workspace: workspace,
                                isFocused: layout.focusedWindowId == window.id,
                                screenBuilder: widget.screenBuilder,
                              ),
                        ],
                      );
                    },
                  ),
                ),
                const DesktopDock(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Hands the workspace to the controller after the frame.
  ///
  /// Riverpod forbids changing a provider while the widget tree is building, and
  /// a [LayoutBuilder] runs during layout. Frames already render with the
  /// workspace passed to them, so this only persists the clamped layout; the first
  /// painted frame is never unclamped.
  void _syncWorkspace(Rect workspace) {
    if (_workspace == workspace) return;
    _workspace = workspace;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(desktopWindowControllerProvider.notifier)
          .setWorkspace(workspace);
    });
  }
}
