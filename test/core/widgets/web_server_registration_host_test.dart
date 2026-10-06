import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/widgets/web_server_registration_host.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';

class _RecordingManager extends McpServerManager {
  final List<WebServices> addedWebServices = [];

  @override
  Future<void> addWebServer(WebServices services) async {
    addedWebServices.add(services);
    await super.addWebServer(services);
  }
}

class _MutableSettings extends SettingsNotifier {
  _MutableSettings(this._initial);
  final AppSettings _initial;

  @override
  AppSettings build() => _initial;
}

void main() {
  testWidgets(
    'registers the web server at app start without any screen involvement',
    (tester) async {
      final manager = _RecordingManager();
      final settings = _MutableSettings(AppSettings(webToolsEnabled: true));
      final container = ProviderContainer(
        overrides: [
          mcpServerManagerProvider.overrideWithValue(manager),
          settingsProvider.overrideWith(() => settings),
        ],
      );
      addTearDown(container.dispose);

      // Mount the host exactly the way app.dart does: no MCP tools screen
      // is opened — the host itself must bootstrap the registration.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: WebServerRegistrationHost(child: const Placeholder()),
        ),
      );
      await tester.pump();

      expect(
        manager.hasWebServer(),
        isTrue,
        reason:
            'web server must register from app start, not from the '
            'MCP tools screen',
      );
      expect(manager.getServerUrl(webMcpServerLabel), webMcpServerUrl);
      expect(manager.addedWebServices, hasLength(1));
    },
  );
}
