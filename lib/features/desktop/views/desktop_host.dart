import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/routes/desktop_workspace.dart';
import '../providers/desktop_window_providers.dart';
import '../utils/desktop_routes.dart';
import 'components/desktop_command_palette.dart';
import 'components/desktop_window_frame.dart';
import 'desktop_shell.dart';

/// Mounts the desktop shell and makes it the target of sidebar navigation.
///
/// The host overrides [desktopWorkspaceProvider] for its subtree, so the existing
/// sidebar opens routes as windows on the desktop while every other platform keeps
/// navigating with the router.
class DesktopHost extends ConsumerStatefulWidget {
  const DesktopHost({
    super.key,
    required this.sidebar,
    required this.screenBuilder,
    this.initialRoute,
    this.conversationCommands,
  });

  /// The navigation sidebar shown left of the workspace.
  final Widget sidebar;

  /// Builds the screen hosted by one window.
  final DesktopScreenBuilder screenBuilder;

  /// The route to open when the host runs outside a router.
  final String? initialRoute;

  /// Builds the recent-conversation commands listed by the palette.
  ///
  /// The app builds them because it owns conversation knowledge.
  final List<DesktopCommand> Function()? conversationCommands;

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
        screenBuilder: widget.screenBuilder,
        fallbackRoute: widget.initialRoute,
        conversationCommands: widget.conversationCommands,
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
}

/// Renders the shell and opens a window whenever the router path changes.
///
/// A screen inside a window still calls `context.go`; the router changes, the host
/// sees the new path and opens or focuses the matching window, so no screen needs
/// to know about the desktop.
class _DesktopHostBody extends ConsumerStatefulWidget {
  const _DesktopHostBody({
    required this.sidebar,
    required this.screenBuilder,
    required this.fallbackRoute,
    required this.conversationCommands,
  });

  final Widget sidebar;
  final DesktopScreenBuilder screenBuilder;
  final String? fallbackRoute;
  final List<DesktopCommand> Function()? conversationCommands;

  @override
  ConsumerState<_DesktopHostBody> createState() => _DesktopHostBodyState();
}

class _DesktopHostBodyState extends ConsumerState<_DesktopHostBody> {
  /// The last path whose window was opened, so a rebuild does not duplicate it.
  String? _openedPath;

  @override
  Widget build(BuildContext context) {
    _openPath(_currentPath(context));
    return DesktopShell(
      sidebar: widget.sidebar,
      screenBuilder: widget.screenBuilder,
      conversationCommands: widget.conversationCommands,
    );
  }

  /// Opens [path] after this frame when it differs from the last opened path.
  ///
  /// Opening a window mutates a provider, which Riverpod forbids while the tree is
  /// building, so the window appears on the next frame.
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
