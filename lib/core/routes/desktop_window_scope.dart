import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Identifies the desktop tab that hosts the current screen.
///
/// The desktop shell wraps the active screen in this scope, so a screen can close
/// its own tab instead of popping the router when it is hosted. Screens that run
/// outside the desktop shell never find a scope and keep navigating with the
/// router.
class DesktopWindowScope extends InheritedWidget {
  const DesktopWindowScope({
    super.key,
    required this.windowId,
    required this.onClose,
    required super.child,
  });

  /// The id of the tab hosting the current screen.
  final String windowId;

  /// Closes the hosting tab.
  final VoidCallback onClose;

  /// Closes the hosting tab.
  void close() => onClose();

  /// The scope above [context], or `null` when the screen is not hosted.
  ///
  /// Looks the scope up without registering a dependency so screens can call it
  /// from event handlers and after an `await`.
  static DesktopWindowScope? maybeOf(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<DesktopWindowScope>();
    return element?.widget as DesktopWindowScope?;
  }

  /// Closes the hosting tab, or pops the current router page.
  ///
  /// Screens that used `context.pop()` (or a `canPop` check followed by a
  /// `go(parent)`) use this so the same Back control closes a tab on the
  /// desktop and pops the router page everywhere else. When the router has
  /// nothing to pop, [fallbackRoute] is opened instead.
  static void popOrClose(BuildContext context, String fallbackRoute) {
    final scope = maybeOf(context);
    if (scope != null) {
      scope.close();
      return;
    }
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go(fallbackRoute);
  }

  @override
  bool updateShouldNotify(DesktopWindowScope oldWidget) =>
      windowId != oldWidget.windowId || onClose != oldWidget.onClose;
}
