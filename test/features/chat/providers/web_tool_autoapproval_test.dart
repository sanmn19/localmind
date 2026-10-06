import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/mcp/data/web/web_search_service.dart';
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

  void setSettings(AppSettings next) => state = next;
}

ProviderContainer _container({
  required McpServerManager manager,
  required _MutableSettings settings,
}) {
  return ProviderContainer(
    overrides: [
      mcpServerManagerProvider.overrideWithValue(manager),
      settingsProvider.overrideWith(() => settings),
    ],
  );
}

void main() {
  group('shouldAutoApproveTool', () {
    test('auto-approves both web tools while web tools are enabled', () {
      expect(shouldAutoApproveTool('web.search', true), isTrue);
      expect(shouldAutoApproveTool('web.fetch', true), isTrue);
    });

    test('never auto-approves while web tools are disabled', () {
      expect(shouldAutoApproveTool('web.search', false), isFalse);
      expect(shouldAutoApproveTool('web.fetch', false), isFalse);
    });

    test('non-web tools do not leak into web auto-approval', () {
      expect(shouldAutoApproveTool('example.echo', true), isFalse);
      expect(shouldAutoApproveTool('calendar.get_events', true), isFalse);
      expect(shouldAutoApproveTool('location.current', true), isFalse);
      expect(shouldAutoApproveTool('web.unknown', true), isFalse);
    });

    test('matching is exact and case-sensitive', () {
      expect(shouldAutoApproveTool('WEB.SEARCH', true), isFalse);
      expect(shouldAutoApproveTool('web.search ', true), isFalse);
      expect(shouldAutoApproveTool('', true), isFalse);
    });
  });

  group('webSearchProviderFromName', () {
    test('maps the persisted provider names onto the enum', () {
      expect(webSearchProviderFromName('ddg'), WebSearchProvider.ddgLite);
      expect(webSearchProviderFromName('tavily'), WebSearchProvider.tavily);
      expect(webSearchProviderFromName('brave'), WebSearchProvider.brave);
      expect(webSearchProviderFromName('serper'), WebSearchProvider.serper);
    });

    test('unknown or blank names fall back to ddgLite', () {
      expect(
        webSearchProviderFromName('perplexity'),
        WebSearchProvider.ddgLite,
      );
      expect(webSearchProviderFromName(''), WebSearchProvider.ddgLite);
    });
  });

  group('webServerRegistrationProvider', () {
    test('registers the web server while the setting is on', () async {
      final manager = _RecordingManager();
      final settings = _MutableSettings(AppSettings(webToolsEnabled: true));
      final container = _container(manager: manager, settings: settings);
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      expect(manager.hasWebServer(), isTrue);
      expect(manager.getServerUrl(webMcpServerLabel), webMcpServerUrl);
      final toolNames = manager
          .getTools(webMcpServerLabel)
          .map((t) => t.name)
          .toList();
      expect(toolNames, containsAll(['web.search', 'web.fetch']));
    });

    test('does nothing while the setting is off', () async {
      final manager = _RecordingManager();
      final settings = _MutableSettings(AppSettings());
      final container = _container(manager: manager, settings: settings);
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      expect(manager.hasWebServer(), isFalse);
      expect(manager.addedWebServices, isEmpty);
    });

    test('unregisters when the setting is toggled off', () async {
      final manager = _RecordingManager();
      final settings = _MutableSettings(AppSettings(webToolsEnabled: true));
      final container = _container(manager: manager, settings: settings);
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();
      expect(manager.hasWebServer(), isTrue);

      settings.setSettings(AppSettings());
      await pumpEventQueue();
      expect(manager.hasWebServer(), isFalse);
    });

    test('propagates the search provider and api key while enabled', () async {
      final manager = _RecordingManager();
      final settings = _MutableSettings(
        AppSettings(
          webToolsEnabled: true,
          webSearchProvider: 'tavily',
          webSearchApiKey: 'KEY-A',
        ),
      );
      final container = _container(manager: manager, settings: settings);
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      expect(manager.addedWebServices, hasLength(1));
      expect(
        manager.addedWebServices.single.search.provider,
        WebSearchProvider.tavily,
      );
      expect(manager.addedWebServices.single.search.apiKey, 'KEY-A');

      settings.setSettings(
        AppSettings(
          webToolsEnabled: true,
          webSearchProvider: 'brave',
          webSearchApiKey: 'KEY-B',
        ),
      );
      await pumpEventQueue();

      expect(
        manager.addedWebServices.last.search.provider,
        WebSearchProvider.brave,
      );
      expect(manager.addedWebServices.last.search.apiKey, 'KEY-B');
      expect(manager.hasWebServer(), isTrue);
    });

    test(
      'tears the web server down when the container is disposed while on',
      () async {
        final manager = _RecordingManager();
        final settings = _MutableSettings(AppSettings(webToolsEnabled: true));
        final container = _container(manager: manager, settings: settings);

        container.listen(webServerRegistrationProvider, (_, _) {});
        await pumpEventQueue();
        expect(manager.hasWebServer(), isTrue);

        container.dispose();
        await pumpEventQueue();
        expect(manager.hasWebServer(), isFalse);
      },
    );
  });
}
