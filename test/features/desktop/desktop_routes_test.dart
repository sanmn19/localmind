import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/routes/app_routes.dart';
import 'package:localmind/features/desktop/data/models/desktop_window.dart';
import 'package:localmind/features/desktop/utils/desktop_routes.dart';

void main() {
  test('maps every app route to a desktop window kind', () {
    expect(desktopWindowKindForRoute(AppRoutes.home), DesktopWindowKind.chat);
    expect(
      desktopWindowKindForRoute(AppRoutes.chatHistory),
      DesktopWindowKind.history,
    );
    expect(
      desktopWindowKindForRoute(AppRoutes.savedMessages),
      DesktopWindowKind.savedMessages,
    );
    expect(
      desktopWindowKindForRoute(AppRoutes.servers),
      DesktopWindowKind.servers,
    );
    expect(
      desktopWindowKindForRoute(AppRoutes.addServer),
      DesktopWindowKind.addServer,
    );
    expect(
      desktopWindowKindForRoute(AppRoutes.personas),
      DesktopWindowKind.personas,
    );
    expect(
      desktopWindowKindForRoute(AppRoutes.createPersona),
      DesktopWindowKind.createPersona,
    );
    expect(
      desktopWindowKindForRoute(AppRoutes.settings),
      DesktopWindowKind.settings,
    );
    expect(
      desktopWindowKindForRoute(AppRoutes.cloudSync),
      DesktopWindowKind.cloudSync,
    );
    expect(
      desktopWindowKindForRoute(AppRoutes.mcpTools),
      DesktopWindowKind.mcpTools,
    );
    expect(
      desktopWindowKindForRoute(AppRoutes.skills),
      DesktopWindowKind.skills,
    );
    expect(
      desktopWindowKindForRoute(AppRoutes.skillEditor),
      DesktopWindowKind.skillEditor,
    );
    expect(
      desktopWindowKindForRoute(AppRoutes.background),
      DesktopWindowKind.background,
    );
    expect(
      desktopWindowKindForRoute(AppRoutes.onDeviceModels),
      DesktopWindowKind.onDeviceModels,
    );
    expect(
      desktopWindowKindForRoute(AppRoutes.ttsModels),
      DesktopWindowKind.ttsModels,
    );
    expect(
      desktopWindowKindForRoute(AppRoutes.lmStudioModelBrowser),
      DesktopWindowKind.lmStudioModels,
    );
  });

  test('maps an unknown route to a chat window', () {
    expect(desktopWindowKindForRoute('/not-a-route'), DesktopWindowKind.chat);
    expect(desktopWindowKindForRoute('/'), DesktopWindowKind.chat);
  });

  test('titles every route with its window kind title', () {
    expect(desktopTitleForRoute(AppRoutes.settings), 'Settings');
    expect(desktopTitleForRoute(AppRoutes.addServer), 'Add server');
    expect(desktopTitleForRoute('/not-a-route'), 'Chat');
  });

  test('lists every palette route once and never lists onboarding', () {
    expect(desktopRoutes.toSet(), hasLength(desktopRoutes.length));
    expect(desktopRoutes, contains(AppRoutes.settings));
    expect(desktopRoutes, isNot(contains(AppRoutes.onboarding)));
    for (final route in desktopRoutes) {
      expect(
        desktopWindowKindForRoute(route),
        isNot(DesktopWindowKind.onboarding),
        reason: '$route must open a workspace window',
      );
    }
  });
}
