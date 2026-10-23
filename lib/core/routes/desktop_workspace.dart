import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opens an app route inside the desktop workspace.
///
/// The desktop host overrides [desktopWorkspaceProvider] with an implementation
/// that turns a route into a workspace tab. Every other platform leaves the
/// provider `null`, so navigation keeps using the router.
abstract class DesktopWorkspace {
  /// Opens [route] in its tab, focusing it when it is already open.
  void openRoute(BuildContext context, String route);

  /// Closes the tab that hosts the calling [context].
  ///
  /// Screens use this instead of popping the router, which would replace the
  /// shell with the page below the current one.
  void closeCurrent(BuildContext context);
}

/// The desktop workspace, or `null` when the app is not running as a desktop
/// shell.
final desktopWorkspaceProvider = Provider<DesktopWorkspace?>((ref) => null);
