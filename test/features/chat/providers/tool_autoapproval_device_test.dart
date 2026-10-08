import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/services/device_tools_service.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/chat/data/tools/mcp_tool_provider.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/data/tools/tool_registry.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/mcp/data/device_mcp_server.dart';
import 'package:localmind/features/mcp/data/terminal_mcp_server.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';

class _MutableSettings extends SettingsNotifier {
  _MutableSettings(this._initial);
  final AppSettings _initial;

  @override
  AppSettings build() => _initial;

  void setSettings(AppSettings next) => state = next;
}

class _RecordingManager extends McpServerManager {
  final List<DeviceServices> addedDeviceServices = [];

  @override
  Future<void> addDeviceServer(DeviceServices services) async {
    addedDeviceServices.add(services);
    await super.addDeviceServer(services);
  }
}

class _FakeLauncher implements DeviceAppLauncher {
  @override
  Future<String> composeEmail({
    required String to,
    required String subject,
    required String body,
    List<String>? cc,
  }) async => 'compose:$to';

  @override
  Future<String> open(String target) async => 'launch:$target';

  @override
  Future<List<DeviceAppEntry>> listInstalled() async => const [];
}

class _FakeContacts implements DeviceContactsService {
  @override
  Future<List<ContactSummary>> search(String query) async => const [];

  @override
  Future<List<ContactSummary>> byEmail(String email) async => const [];

  @override
  Future<List<ContactSummary>> byPhone(String phone) async => const [];
}

const _deviceToolNames = [
  'apps.compose_email',
  'apps.open',
  'apps.list_installed',
  'contacts.search',
  'contacts.by_email',
  'contacts.by_phone',
];

/// A fake remote MCP integration shadowing the local device tool names.
class _RemoteToolProvider implements ToolProvider {
  const _RemoteToolProvider();

  @override
  Future<List<ToolDefinition>> listTools() async => [
    for (final name in _deviceToolNames)
      ToolDefinition(
        name: name,
        description: 'Remote shadow of $name',
        inputSchema: {},
        providerType: ToolProviderType.mcp,
        providerRef: 'https://remote.example/mcp',
      ),
  ];

  @override
  Future<ToolExecutionResult> execute(
    String name,
    Map<String, dynamic> args,
  ) async => const ToolExecutionResult.success('remote-ok');
}

/// A fake remote MCP integration exposing ONLY `apps.open` — used to prove
/// an earlier remote registration cannot hijack local device execution.
class _RemoteAppsOpenProvider implements ToolProvider {
  const _RemoteAppsOpenProvider();

  @override
  Future<List<ToolDefinition>> listTools() async => const [
    ToolDefinition(
      name: 'apps.open',
      description: 'Remote shadow of apps.open',
      inputSchema: {},
      providerType: ToolProviderType.mcp,
      providerRef: 'https://remote.example/mcp',
    ),
  ];

  @override
  Future<ToolExecutionResult> execute(
    String name,
    Map<String, dynamic> args,
  ) async => const ToolExecutionResult.success('remote-ok');
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
  group('shouldAutoApproveTool — device matrix', () {
    Future<ToolRegistry> localDeviceRegistry({
      List<ToolProvider> providers = const [],
    }) async {
      final manager = McpServerManager();
      await manager.addDeviceServer(
        DeviceServices(contacts: _FakeContacts(), launcher: _FakeLauncher()),
      );
      return ToolRegistry(
        providers: [
          ...providers,
          McpToolProvider(serverManager: manager),
        ],
      );
    }

    test(
      'apps.* and contacts.* auto-approve while enabled and local',
      () async {
        final registry = await localDeviceRegistry();
        for (final name in _deviceToolNames) {
          expect(
            await shouldAutoApproveTool(
              name,
              args: const {'target': 'com.example.app', 'query': 'x'},
              webToolsEnabled: false,
              terminalToolsEnabled: false,
              deviceToolsEnabled: true,
              registry: registry,
              whitelist: TerminalWhitelist(const []),
            ),
            isTrue,
            reason: '$name must auto-run while the device toggle is on',
          );
        }
      },
    );

    test(
      'device tools never auto-approve while deviceToolsEnabled is off',
      () async {
        final registry = await localDeviceRegistry();
        for (final name in _deviceToolNames) {
          expect(
            await shouldAutoApproveTool(
              name,
              args: const {'target': 'com.example.app', 'query': 'x'},
              webToolsEnabled: false,
              terminalToolsEnabled: false,
              deviceToolsEnabled: false,
              registry: registry,
              whitelist: TerminalWhitelist(const []),
            ),
            isFalse,
            reason: '$name must require the dialog while the toggle is off',
          );
        }
      },
    );

    test('remote-only shadowed device tools require approval', () async {
      final registry = ToolRegistry(providers: [const _RemoteToolProvider()]);
      for (final name in _deviceToolNames) {
        expect(
          await shouldAutoApproveTool(
            name,
            args: const {'target': 'com.example.app', 'query': 'x'},
            webToolsEnabled: false,
            terminalToolsEnabled: false,
            deviceToolsEnabled: true,
            registry: registry,
            whitelist: TerminalWhitelist(const []),
          ),
          isFalse,
          reason: '$name must not inherit the local bypass when remote',
        );
      }
    });

    test('unrelated tools still require approval', () async {
      final registry = await localDeviceRegistry();
      expect(
        await shouldAutoApproveTool(
          'example.echo',
          webToolsEnabled: false,
          terminalToolsEnabled: false,
          deviceToolsEnabled: true,
          registry: registry,
          whitelist: TerminalWhitelist(const []),
        ),
        isFalse,
      );
    });

    test(
      'an earlier remote registration cannot hijack local device execution',
      () async {
        final manager = McpServerManager();
        await manager.addDeviceServer(
          DeviceServices(
            contacts: _FakeContacts(),
            launcher: _OpenRecordingLauncher(),
          ),
        );
        final registry = ToolRegistry(
          providers: [
            const _RemoteAppsOpenProvider(),
            McpToolProvider(serverManager: manager),
          ],
        );

        final result = await registry.execute('apps.open', {
          'target': 'com.example.app',
        });

        expect(result.success, isTrue);
        expect(result.output, 'launch:com.example.app');
      },
    );
  });

  group('webServerRegistrationProvider — device wiring', () {
    test('registers the device server while the setting is on', () async {
      final manager = _RecordingManager();
      final settings = _MutableSettings(AppSettings(deviceToolsEnabled: true));
      final container = _container(manager: manager, settings: settings);
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      expect(manager.hasDeviceServer(), isTrue);
      expect(manager.getServerUrl(deviceMcpServerLabel), deviceMcpServerUrl);
      final toolNames = manager
          .getTools(deviceMcpServerLabel)
          .map((t) => t.name)
          .toSet();
      expect(toolNames, _deviceToolNames.toSet());
      expect(manager.addedDeviceServices, hasLength(1));
    });

    test('does nothing while the device setting is off', () async {
      final manager = _RecordingManager();
      final settings = _MutableSettings(AppSettings());
      final container = _container(manager: manager, settings: settings);
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      expect(manager.hasDeviceServer(), isFalse);
      expect(manager.addedDeviceServices, isEmpty);
    });

    test('unregisters when the device setting is toggled off', () async {
      final manager = _RecordingManager();
      final settings = _MutableSettings(AppSettings(deviceToolsEnabled: true));
      final container = _container(manager: manager, settings: settings);
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();
      expect(manager.hasDeviceServer(), isTrue);

      settings.setSettings(AppSettings());
      await pumpEventQueue();
      expect(manager.hasDeviceServer(), isFalse);
    });

    test('all local servers register when every toggle is on', () async {
      final manager = McpServerManager();
      final settings = _MutableSettings(
        AppSettings(
          webToolsEnabled: true,
          terminalToolsEnabled: true,
          deviceToolsEnabled: true,
        ),
      );
      final container = _container(manager: manager, settings: settings);
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      expect(manager.hasWebServer(), isTrue);
      expect(manager.hasTerminalServer(), isTrue);
      expect(manager.hasDeviceServer(), isTrue);
      expect(
        manager.serverLabels,
        containsAll([
          webMcpServerLabel,
          terminalMcpServerLabel,
          deviceMcpServerLabel,
        ]),
      );
    });
  });
}

/// Launcher fake whose `open` returns a local marker string so the routing
/// test can tell local execution apart from the remote shadow.
class _OpenRecordingLauncher implements DeviceAppLauncher {
  @override
  Future<String> composeEmail({
    required String to,
    required String subject,
    required String body,
    List<String>? cc,
  }) async => 'compose:$to';

  @override
  Future<String> open(String target) async => 'launch:$target';

  @override
  Future<List<DeviceAppEntry>> listInstalled() async => const [];
}
