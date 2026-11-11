import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hugeicons/hugeicons.dart';

import '../../../core/components/app_sizes.dart';
import '../../../core/routes/app_routes.dart';
import '../data/models/desktop_window.dart';
import '../providers/desktop_window_providers.dart';
import '../utils/desktop_routes.dart';
import 'components/desktop_command_palette.dart';
import 'components/desktop_tab_bar.dart';

/// Builds the screen hosted by the active desktop tab.
typedef DesktopScreenBuilder = Widget Function(DesktopWindowState window);

/// The desktop workspace: a sidebar, a tab strip and the active screen.
///
/// The active screen fills the workspace with no frame of its own: tabs are the
/// only window chrome. The shell renders no platform-specific window chrome,
/// which keeps it usable in widget tests.
///
/// It also owns the keyboard shortcuts and the command palette. The palette is an
/// overlay inside the workspace, so it is part of the same focus scope as the
/// screen it searches.
class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({
    super.key,
    required this.sidebar,
    required this.screenBuilder,
    this.conversationCommands,
    this.startNewChat,
  });

  /// The navigation sidebar shown left of the workspace.
  final Widget sidebar;

  /// Builds the screen hosted by the active tab.
  final DesktopScreenBuilder screenBuilder;

  /// Builds the recent-conversation commands listed by the palette.
  final List<DesktopCommand> Function()? conversationCommands;

  /// Resets the app-wide chat before the shell opens a new chat tab.
  ///
  /// Chat state belongs to the chat feature, so the app supplies this callback
  /// and the desktop feature never imports a sibling feature.
  final Future<String?> Function()? startNewChat;

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  /// The number keys that activate the first nine tabs.
  static const List<LogicalKeyboardKey> _tabKeys = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];

  final _focusNode = FocusNode(debugLabel: 'desktop-shell');
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
    final layout = ref.watch(desktopWindowControllerProvider);
    final activeWindow = layout.focusedWindow;
    final theme = Theme.of(context);

    // Screens hosted by tabs show snackbars and dialogs; the desktop shell
    // has no Scaffold of its own, so the messenger needs one registered here.
    final canvas = Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Row(
        children: [
          widget.sidebar,
          Expanded(
            child: Column(
              children: [
                DesktopTabBar(onNewChat: _newChat),
                Expanded(
                  child: activeWindow == null
                      ? const _DesktopEmptyState()
                      : KeyedSubtree(
                          key: ValueKey('desktop-screen-${activeWindow.id}'),
                          child: widget.screenBuilder(activeWindow),
                        ),
                ),
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
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            _openSettings,
        for (var index = 0; index < _tabKeys.length; index++)
          SingleActivator(_tabKeys[index], meta: true): () =>
              _activateTab(index),
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

  /// Resets the app-wide chat and opens the home chat tab.
  ///
  /// The home tab has no conversation id, so it renders the app-scope chat rather
  /// than a window bound to a conversation that does not exist yet.
  void _newChat() {
    // A new chat tab starts empty and owns its own chat state; the app-wide chat
    // is reset by the sidebar's New Chat, not by every draft tab.
    _controller.open(
      kind: DesktopWindowKind.chat,
      isDraft: true,
      title: DesktopWindowKind.chat.defaultTitle,
    );
  }

  /// Activates the tab at [index], if there is one.
  void _activateTab(int index) {
    final windows = ref.read(desktopWindowControllerProvider).windows;
    if (index < 0 || index >= windows.length) return;
    _controller.focus(windows[index].id);
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
    // Closing the last tab removes the widget that owned focus, so the shell
    // takes it back for the next shortcut.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _openSettings() {
    _controller.open(
      kind: DesktopWindowKind.settings,
      route: AppRoutes.settings,
      title: desktopTitleForRoute(AppRoutes.settings),
    );
  }

  /// Runs one palette command: focus an open tab or open its route.
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
}

/// The workspace shown when every tab is closed.
class _DesktopEmptyState extends StatelessWidget {
  const _DesktopEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;

    return Center(
      key: const ValueKey('desktop-empty-workspace'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HugeIcon(
            icon: HugeIcons.strokeRoundedDashboardSquare01,
            size: AppSizes.iconXl,
            color: color.withValues(alpha: 0.5),
          ),
          const SizedBox(height: AppSizes.sm),
          Text(
            'No open tabs',
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
