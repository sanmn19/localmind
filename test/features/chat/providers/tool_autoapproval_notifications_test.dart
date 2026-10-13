import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/chat/data/tools/mcp_tool_provider.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/data/tools/tool_registry.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/notifications/notifications_mcp_server.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';

// Auto-approval matrix + settings-driven registration for the
// `local://notifications` server (notifications.read_recent only — pure
// read of the session ring). Mirrors the background matrix shape.

/// Fresh per test: a live channel closure would only resolve at CALL time
/// and this suite never executes the tool — registration wiring only.
NotificationsServices _services() => NotificationsServices(
      recent: ({int? max, int? sinceMinutes, String? package}) async =>
          const [],
    );

void main() {
  group('shouldAutoApproveTool — notifications matrix', () {
    Future<ToolRegistry> localNotificationsRegistry() async {
      final manager = McpServerManager();
      await manager.addNotificationsServer(_services());
      return ToolRegistry(providers: [McpToolProvider(serverManager: manager)]);
    }

    Future<bool> approve(
      String toolName,
      ToolRegistry registry, {
      required bool notifications,
    }) => shouldAutoApproveTool(
      toolName,
      webToolsEnabled: false,
      terminalToolsEnabled: false,
      notificationToolsEnabled: notifications,
      registry: registry,
      whitelist: null,
    );

    test('notifications.read_recent auto-approves while enabled and locally '
        'owned', () async {
      final registry = await localNotificationsRegistry();
      expect(
        await approve(
          'notifications.read_recent',
          registry,
          notifications: true,
        ),
        isTrue,
        reason: 'the read-only reader rides the toggle like web reads',
      );
    });

    test('falls back to the dialog while the toggle is off', () async {
      final registry = await localNotificationsRegistry();
      expect(
        await approve(
          'notifications.read_recent',
          registry,
          notifications: false,
        ),
        isFalse,
      );
    });

    test('remote-only shadowed reader name does not inherit the local '
        'bypass', () async {
      final registry = ToolRegistry(
        providers: [
          _RemoteShadowProvider(
            name: 'notifications.read_recent',
            providerRef: 'https://remote.example/mcp',
          ),
        ],
      );
      expect(
        await approve(
          'notifications.read_recent',
          registry,
          notifications: true,
        ),
        isFalse,
      );
    });

    test('unrelated tools never leak into the notifications bypass',
        () async {
      final registry = await localNotificationsRegistry();
      expect(
        await approve('example.echo', registry, notifications: true),
        isFalse,
      );
      expect(
        await approve('notifications.wipe', registry, notifications: true),
        isFalse,
      );
    });
  });

  group('webServerRegistrationProvider — notifications wiring', () {
    ProviderContainer containerFor(
      McpServerManager manager,
      _MutableSettings settings,
    ) => ProviderContainer(
      overrides: [
        mcpServerManagerProvider.overrideWithValue(manager),
        settingsProvider.overrideWith(() => settings),
      ],
    );

    _MutableSettings settingsWith(bool notificationToolsEnabled) =>
        _MutableSettings(
          AppSettings(notificationToolsEnabled: notificationToolsEnabled),
        );

    test('registers the notifications server while the switch is on',
        () async {
      final manager = _RecordingManager();
      final settings = settingsWith(true);
      final container = containerFor(manager, settings);
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      expect(manager.hasNotificationsServer(), isTrue);
      expect(
        manager.getServerUrl(notificationsMcpServerLabel),
        notificationsMcpServerUrl,
      );
      final toolNames = manager
          .getTools(notificationsMcpServerLabel)
          .map((t) => t.name)
          .toSet();
      expect(toolNames, {'notifications.read_recent'});
    });

    test('does nothing while the switch is off', () async {
      final manager = _RecordingManager();
      final container = containerFor(manager, settingsWith(false));
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      expect(manager.hasNotificationsServer(), isFalse);
    });

    test('unregisters when the switch is toggled off', () async {
      final manager = _RecordingManager();
      final settings = settingsWith(true);
      final container = containerFor(manager, settings);
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();
      expect(manager.hasNotificationsServer(), isTrue);

      settings.setSettings(AppSettings(notificationToolsEnabled: false));
      await pumpEventQueue();
      expect(manager.hasNotificationsServer(), isFalse);
    });

    test('tears the notifications server down when the container is '
        'disposed while on', () async {
      final manager = _RecordingManager();
      final container = containerFor(manager, settingsWith(true));

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();
      expect(manager.hasNotificationsServer(), isTrue);

      container.dispose();
      await pumpEventQueue();
      expect(manager.hasNotificationsServer(), isFalse);
    });
  });
}

class _RemoteShadowProvider implements ToolProvider {
  const _RemoteShadowProvider({
    required this.name,
    required this.providerRef,
  });

  final String name;
  final String providerRef;

  @override
  Future<List<ToolDefinition>> listTools() async => [
    ToolDefinition(
      name: name,
      description: 'Remote shadow of $name',
      inputSchema: {},
      providerType: ToolProviderType.mcp,
      providerRef: providerRef,
    ),
  ];

  @override
  Future<ToolExecutionResult> execute(
    String name,
    Map<String, dynamic> args,
  ) async => const ToolExecutionResult.success('remote-ok');
}

class _RecordingManager extends McpServerManager {
  final List<NotificationsServices> bundles = [];

  @override
  Future<void> addNotificationsServer(NotificationsServices services) async {
    bundles.add(services);
    await super.addNotificationsServer(services);
  }
}

class _MutableSettings extends SettingsNotifier {
  _MutableSettings(this._initial);
  final AppSettings _initial;

  @override
  AppSettings build() => _initial;

  void setSettings(AppSettings next) => state = next;
}
