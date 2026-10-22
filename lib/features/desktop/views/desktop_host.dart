import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/routes/desktop_workspace.dart';
import '../providers/desktop_window_providers.dart';
import '../utils/desktop_routes.dart';
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
  });

  /// The navigation sidebar shown left of the workspace.
  final Widget sidebar;

  /// Builds the screen hosted by one window.
  final DesktopScreenBuilder screenBuilder;

  /// The route the app was launched on, opened as a window on the first frame.
  final String? initialRoute;

  @override
  ConsumerState<DesktopHost> createState() => _DesktopHostState();
}

class _DesktopHostState extends ConsumerState<DesktopHost>
    implements DesktopWorkspace {
  /// Built once so rebuilding the host does not churn the workspace override.
  late final _overrides = [desktopWorkspaceProvider.overrideWithValue(this)];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _openInitialRoute());
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: _overrides,
      child: DesktopShell(
        sidebar: widget.sidebar,
        screenBuilder: widget.screenBuilder,
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

  /// Opens the launch route once, after the first frame.
  ///
  /// Opening a window mutates a provider, which Riverpod forbids while the tree is
  /// building; a deep link is still visible on the first settled frame.
  void _openInitialRoute() {
    final route = widget.initialRoute;
    if (!mounted || route == null || route.isEmpty) return;
    openRoute(context, route);
  }
}
