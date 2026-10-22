import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opens an app route inside the desktop workspace.
///
/// The desktop host overrides [desktopWorkspaceProvider] with an implementation
/// that turns a route into a floating window. Every other platform leaves the
/// provider `null`, so navigation keeps using the router.
abstract class DesktopWorkspace {
  void openRoute(BuildContext context, String route);
}

/// The desktop workspace, or `null` when the app is not running as a desktop
/// shell.
final desktopWorkspaceProvider = Provider<DesktopWorkspace?>((ref) => null);
