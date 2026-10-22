import '../../../core/routes/app_routes.dart';
import '../data/models/desktop_window.dart';

/// Every shell route that can be opened as a desktop window, in the order the
/// command palette lists them.
///
/// Onboarding is excluded: it runs before the shell exists.
const List<String> desktopRoutes = [
  AppRoutes.home,
  AppRoutes.chatHistory,
  AppRoutes.savedMessages,
  AppRoutes.personas,
  AppRoutes.createPersona,
  AppRoutes.servers,
  AppRoutes.addServer,
  AppRoutes.lmStudioModelBrowser,
  AppRoutes.onDeviceModels,
  AppRoutes.ttsModels,
  AppRoutes.mcpTools,
  AppRoutes.skills,
  AppRoutes.skillEditor,
  AppRoutes.background,
  AppRoutes.cloudSync,
  AppRoutes.settings,
];

/// The window kind a route opens.
///
/// More specific routes are matched before their parents (`/servers/add` before
/// `/servers`). An unknown route still opens a window: it falls back to a chat
/// window and the caller keeps the route on the window.
DesktopWindowKind desktopWindowKindForRoute(String route) {
  final path = route.split('?').first;
  if (path == AppRoutes.home || path == '/') {
    return DesktopWindowKind.chat;
  }
  if (path.startsWith(AppRoutes.onboarding)) {
    return DesktopWindowKind.onboarding;
  }
  if (path.startsWith(AppRoutes.addServer)) {
    return DesktopWindowKind.addServer;
  }
  if (path.startsWith(AppRoutes.servers)) {
    return DesktopWindowKind.servers;
  }
  if (path.startsWith(AppRoutes.createPersona)) {
    return DesktopWindowKind.createPersona;
  }
  if (path.startsWith(AppRoutes.personas)) {
    return DesktopWindowKind.personas;
  }
  if (path.startsWith(AppRoutes.cloudSync)) {
    return DesktopWindowKind.cloudSync;
  }
  if (path.startsWith(AppRoutes.settings)) {
    return DesktopWindowKind.settings;
  }
  if (path.startsWith(AppRoutes.mcpTools)) {
    return DesktopWindowKind.mcpTools;
  }
  if (path.startsWith(AppRoutes.skillEditor)) {
    return DesktopWindowKind.skillEditor;
  }
  if (path.startsWith(AppRoutes.skills)) {
    return DesktopWindowKind.skills;
  }
  if (path.startsWith(AppRoutes.background)) {
    return DesktopWindowKind.background;
  }
  if (path.startsWith(AppRoutes.onDeviceModels)) {
    return DesktopWindowKind.onDeviceModels;
  }
  if (path.startsWith(AppRoutes.ttsModels)) {
    return DesktopWindowKind.ttsModels;
  }
  if (path.startsWith(AppRoutes.lmStudioModelBrowser)) {
    return DesktopWindowKind.lmStudioModels;
  }
  if (path.startsWith(AppRoutes.chatHistory)) {
    return DesktopWindowKind.history;
  }
  if (path.startsWith(AppRoutes.savedMessages)) {
    return DesktopWindowKind.savedMessages;
  }
  return DesktopWindowKind.chat;
}

/// The window title a route opens with.
String desktopTitleForRoute(String route) =>
    desktopWindowKindForRoute(route).defaultTitle;
