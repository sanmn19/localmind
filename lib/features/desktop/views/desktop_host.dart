import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/routes/desktop_window_scope.dart';
import '../../../core/routes/desktop_workspace.dart';
import '../data/models/desktop_window.dart';
import '../providers/desktop_window_providers.dart';
import '../utils/desktop_routes.dart';
import 'components/desktop_command_palette.dart';
import 'desktop_shell.dart';

/// Mounts the desktop shell and makes it the target of sidebar navigation.
///
/// The host overrides [desktopWorkspaceProvider] for its subtree, so the existing
/// sidebar opens routes as workspace tabs while every other platform keeps
/// navigating with the router. It also gives every hosted screen a
/// [DesktopWindowScope], so a screen's Back and Save controls close their own tab
/// instead of popping the router.
class DesktopHost extends ConsumerStatefulWidget {
  const DesktopHost({
    super.key,
    required this.sidebar,
    required this.screenBuilder,
    this.initialRoute,
    this.conversationCommands,
    this.startNewChat,
  });

  /// The navigation sidebar shown left of the workspace.
  final Widget sidebar;

  /// Builds the screen hosted by one tab.
  final DesktopScreenBuilder screenBuilder;

  /// The route to open when the host runs outside a router.
  final String? initialRoute;

  /// Builds the recent-conversation commands listed by the palette.
  ///
  /// The app builds them because it owns conversation knowledge.
  final List<DesktopCommand> Function()? conversationCommands;

  /// Resets the app-wide chat before the shell opens a new chat tab.
  ///
  /// The app supplies it because chat state belongs to a sibling feature.
  final Future<String?> Function()? startNewChat;

  @override
  ConsumerState<DesktopHost> createState() => _DesktopHostState();
}

class _DesktopHostState extends ConsumerState<DesktopHost>
    implements DesktopWorkspace {
  /// Built once so rebuilding the host does not churn the workspace override.
  late final _overrides = [desktopWorkspaceProvider.overrideWithValue(this)];

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: _overrides,
      child: _DesktopHostBody(
        sidebar: widget.sidebar,
        screenBuilder: _buildScreen,
        fallbackRoute: widget.initialRoute,
        conversationCommands: widget.conversationCommands,
        startNewChat: widget.startNewChat,
      ),
    );
  }

  @override
  void openRoute(BuildContext context, String route) {
    ref
        .read(desktopWindowControllerProvider.notifier)
        .open(
          kind: desktopWindowKindForRoute(route),
          route: route,
          title: desktopTitleForRoute(route),
        );
  }

  @override
  void closeCurrent(BuildContext context) {
    final scope = DesktopWindowScope.maybeOf(context);
    if (scope != null) _close(scope.windowId);
  }

  /// Wraps the screen of [window] so it can close its own tab.
  Widget _buildScreen(DesktopWindowState window) {
    return DesktopWindowScope(
      windowId: window.id,
      onClose: () => _close(window.id),
      child: widget.screenBuilder(window),
    );
  }

  void _close(String id) {
    ref.read(desktopWindowControllerProvider.notifier).close(id);
  }
}

/// Renders the shell and opens a tab whenever the router path changes.
///
/// A screen inside a tab still calls `context.go`; the router changes, the host
/// sees the new path and opens or focuses the matching tab, so no screen needs to
/// know about the desktop.
class _DesktopHostBody extends ConsumerStatefulWidget {
  const _DesktopHostBody({
    required this.sidebar,
    required this.screenBuilder,
    required this.fallbackRoute,
    required this.conversationCommands,
    required this.startNewChat,
  });

  final Widget sidebar;
  final DesktopScreenBuilder screenBuilder;
  final String? fallbackRoute;
  final List<DesktopCommand> Function()? conversationCommands;
  final Future<String?> Function()? startNewChat;

  @override
  ConsumerState<_DesktopHostBody> createState() => _DesktopHostBodyState();
}

class _DesktopHostBodyState extends ConsumerState<_DesktopHostBody> {
  /// The last path whose tab was opened, so a rebuild does not duplicate it.
  String? _openedPath;

  @override
  Widget build(BuildContext context) {
    _openPath(_currentPath(context));
    return DesktopShell(
      sidebar: widget.sidebar,
      screenBuilder: widget.screenBuilder,
      conversationCommands: widget.conversationCommands,
      startNewChat: widget.startNewChat,
    );
  }

  /// Opens [path] after this frame when it differs from the last opened path.
  ///
  /// Opening a tab mutates a provider, which Riverpod forbids while the tree is
  /// building, so the tab appears on the next frame.
  void _openPath(String? path) {
    if (path == null || path == _openedPath) return;
    _openedPath = path;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(desktopWorkspaceProvider)?.openRoute(context, path);
    });
  }

  /// The router's current path, or [widget.fallbackRoute] without a router.
  String? _currentPath(BuildContext context) {
    try {
      return GoRouterState.of(context).uri.path;
    } on GoError {
      return widget.fallbackRoute;
    }
  }
}
