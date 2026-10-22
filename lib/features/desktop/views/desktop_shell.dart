import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/routes/app_routes.dart';
import '../data/models/desktop_window.dart';
import '../providers/desktop_window_providers.dart';
import '../utils/desktop_routes.dart';
import 'components/desktop_command_palette.dart';
import 'components/desktop_dock.dart';
import 'components/desktop_window_frame.dart';

/// The desktop canvas: a sidebar, a workspace of floating windows and a dock.
///
/// The shell owns the workspace rectangle and hands it to
/// [DesktopWindowController.setWorkspace] so restored layouts are clamped before
/// their frames are painted. It renders no platform-specific window chrome, which
/// keeps it usable in widget tests.
///
/// It also owns the keyboard shortcuts and the command palette. The palette is an
/// overlay inside the workspace, so it is part of the same focus scope as the
/// windows it searches. Minimise is ⌥⌘M because macOS keeps ⌘M for the native
/// window.
class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({
    super.key,
    required this.sidebar,
    required this.screenBuilder,
    this.conversationCommands,
  });

  /// The navigation sidebar shown left of the workspace.
  final Widget sidebar;

  /// Builds the screen hosted by one window.
  final DesktopScreenBuilder screenBuilder;

  /// Builds the recent-conversation commands listed by the palette.
  final List<DesktopCommand> Function()? conversationCommands;

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  final _focusNode = FocusNode(debugLabel: 'desktop-shell');
  Rect? _workspace;
  bool _isPaletteOpen = false;

  DesktopWindowController get _controller =>
      ref.read(desktopWindowControllerProvider.notifier);

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(desktopWindowControllerProvider);
    final theme = Theme.of(context);

    final canvas = Material(
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

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _newChat,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _togglePalette,
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
            _closeFocused,
        const SingleActivator(LogicalKeyboardKey.keyM, meta: true, alt: true):
            _minimizeFocused,
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            _openSettings,
        if (_isPaletteOpen)
          const SingleActivator(LogicalKeyboardKey.escape): _closePalette,
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        child: Stack(
          children: [
            Positioned.fill(child: canvas),
            if (_isPaletteOpen) ...[
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('desktop-palette-scrim'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _closePalette,
                  child: ColoredBox(color: Colors.black.withValues(alpha: 0.3)),
                ),
              ),
              Positioned.fill(
                child: DesktopCommandPalette(
                  onSelected: _selectCommand,
                  conversationCommands: widget.conversationCommands,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Opens a fresh draft chat window.
  ///
  /// A new draft id per press keeps the controller from deduping the window into
  /// the chat window that is already open.
  void _newChat() {
    _controller.open(
      kind: DesktopWindowKind.chat,
      conversationId: 'draft-${DateTime.now().microsecondsSinceEpoch}',
      title: DesktopWindowKind.chat.defaultTitle,
    );
  }

  void _togglePalette() {
    if (_isPaletteOpen) {
      _closePalette();
      return;
    }
    setState(() => _isPaletteOpen = true);
  }

  void _closePalette() {
    if (!_isPaletteOpen) return;
    setState(() => _isPaletteOpen = false);
    _focusNode.requestFocus();
  }

  void _closeFocused() {
    final id = ref.read(desktopWindowControllerProvider).focusedWindowId;
    if (id != null) _controller.close(id);
  }

  void _minimizeFocused() {
    final id = ref.read(desktopWindowControllerProvider).focusedWindowId;
    if (id != null) _controller.minimize(id);
  }

  void _openSettings() {
    _controller.open(
      kind: DesktopWindowKind.settings,
      route: AppRoutes.settings,
      title: desktopTitleForRoute(AppRoutes.settings),
    );
  }

  /// Runs one palette command: focus an open window or open its route.
  void _selectCommand(DesktopCommand command) {
    _closePalette();
    if (command.id.startsWith(DesktopCommand.windowPrefix)) {
      _controller.focus(
        command.id.substring(DesktopCommand.windowPrefix.length),
      );
      return;
    }
    if (command.id.startsWith(DesktopCommand.conversationPrefix)) {
      _controller.open(
        kind: DesktopWindowKind.chat,
        conversationId: command.id.substring(
          DesktopCommand.conversationPrefix.length,
        ),
        title: command.label,
      );
      return;
    }
    _controller.open(
      kind: command.kind,
      route: command.route,
      title: command.label,
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
