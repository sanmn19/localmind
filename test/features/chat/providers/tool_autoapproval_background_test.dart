import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/features/chat/data/background_task_service.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/chat/data/models/background_task.dart';
import 'package:localmind/features/chat/data/tools/mcp_tool_provider.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/data/tools/tool_registry.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';

// Task 3: the auto-approval matrix for the `local://background` server plus
// the settings-driven registration wiring. Mirrors the skills matrix shape
// (tool_autoapproval_skills_test.dart).

class _RemoteToolProvider implements ToolProvider {
  const _RemoteToolProvider();

  @override
  Future<List<ToolDefinition>> listTools() async => [
    for (final name in const ['bg.spawn', 'bg.status', 'bg.cancel'])
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

class _FakeServices implements BackgroundServices {
  const _FakeServices();

  @override
  Future<BackgroundTask> Function({
    required String ownerConversationId,
    required String prompt,
    int? loopMinutes,
    int? maxRuns,
  }) get spawn => ({required String ownerConversationId, required String prompt,
      int? loopMinutes, int? maxRuns}) async => throw UnimplementedError();

  @override
  Future<List<BackgroundTask>> Function(String) get tasksFor =>
      (ownerConversationId) async => const [];

  @override
  Future<bool> Function(String) get cancelTask =>
      (taskId) async => false;

  @override
  void Function(String taskId)? get runRequester => null;

  @override
  String? Function()? get currentOwnerConversationId => null;
}

const _regionNote = 'see background_mcp_server_test.dart for the exact '
    'render/dispatch behavior';

void main() {
  group('shouldAutoApproveTool — background matrix', () {
    Future<ToolRegistry> localBackgroundRegistry() async {
      final manager = McpServerManager();
      await manager.addBackgroundServer(const _FakeServices());
      return ToolRegistry(providers: [McpToolProvider(serverManager: manager)]);
    }

    Future<bool> approve(
      String toolName,
      ToolRegistry registry, {
      required bool background,
    }) => shouldAutoApproveTool(
      toolName,
      webToolsEnabled: false,
      terminalToolsEnabled: false,
      backgroundTasksEnabled: background,
      registry: registry,
      whitelist: null,
    );

    test('bg.status and bg.cancel auto-approve while enabled and locally '
        'owned', () async {
      final registry = await localBackgroundRegistry();
      expect(await approve('bg.status', registry, background: true), isTrue);
      expect(await approve('bg.cancel', registry, background: true), isTrue);
    });

    test('bg.status and bg.cancel fall back to the dialog while disabled',
        () async {
      final registry = await localBackgroundRegistry();
      expect(await approve('bg.status', registry, background: false), isFalse);
      expect(await approve('bg.cancel', registry, background: false), isFalse);
    });

    test('bg.spawn NEVER auto-approves — the toggle cannot cover it',
        () async {
      final registry = await localBackgroundRegistry();
      expect(await approve('bg.spawn', registry, background: true), isFalse);
      expect(await approve('bg.spawn', registry, background: false), isFalse);
    });

    test('remote-only shadowed bg names do not inherit the local bypass',
        () async {
      final registry = ToolRegistry(providers: [const _RemoteToolProvider()]);
      for (final name in const ['bg.spawn', 'bg.status', 'bg.cancel']) {
        expect(
          await approve(name, registry, background: true),
          isFalse,
          reason: '$name must not auto-approve when remote-owned',
        );
      }
    });

    test('unrelated tools never leak into the background bypass', () async {
      final registry = await localBackgroundRegistry();
      expect(await approve('example.echo', registry, background: true),
          isFalse);
      expect(await approve('bg.unknown', registry, background: true), isFalse);
    });
  });

  group('webServerRegistrationProvider — background wiring', () {
    ProviderContainer containerFor(
      McpServerManager manager,
      _MutableSettings settings,
    ) => ProviderContainer(
      overrides: [
        mcpServerManagerProvider.overrideWithValue(manager),
        settingsProvider.overrideWith(() => settings),
        backgroundTasksServiceProvider.overrideWith(
          (ref) => _RegistrationStubDb(),
        ),
      ],
    );

    _MutableSettings settingsWith(bool backgroundTasksEnabled) =>
        _MutableSettings(AppSettings(backgroundTasksEnabled: backgroundTasksEnabled));

    test('registers the background server while the switch is on', () async {
      final manager = _RecordingManager();
      final settings = settingsWith(true);
      final container = containerFor(manager, settings);
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      expect(manager.hasBackgroundServer(), isTrue);
      expect(manager.getServerUrl(bgMcpServerLabel), bgMcpServerUrl);
      final toolNames = manager
          .getTools(bgMcpServerLabel)
          .map((t) => t.name)
          .toSet();
      expect(toolNames, {'bg.spawn', 'bg.status', 'bg.cancel'});
      // The bundle carries the run-request seam for Task 4's engine.
      expect(manager.bundles.single.runRequester, isNotNull);
      expect(
        manager.bundles.single.tasksFor,
        isNotNull,
        reason: _regionNote,
      );
    });

    test('does nothing while the switch is off', () async {
      final manager = _RecordingManager();
      final container = containerFor(manager, settingsWith(false));
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      expect(manager.hasBackgroundServer(), isFalse);
      expect(manager.bundles, isEmpty);
    });

    test('unregisters when the switch is toggled off', () async {
      final manager = _RecordingManager();
      final settings = settingsWith(true);
      final container = containerFor(manager, settings);
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();
      expect(manager.hasBackgroundServer(), isTrue);

      settings.setSettings(AppSettings(backgroundTasksEnabled: false));
      await pumpEventQueue();
      expect(manager.hasBackgroundServer(), isFalse);
    });

    test('tears the background server down when the container is disposed '
        'while on', () async {
      final manager = _RecordingManager();
      final container = containerFor(manager, settingsWith(true));

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();
      expect(manager.hasBackgroundServer(), isTrue);

      container.dispose();
      await pumpEventQueue();
      expect(manager.hasBackgroundServer(), isFalse);
    });
  });
}

class _RegistrationStubDb extends Fake implements BackgroundTasksService {}

class _RecordingManager extends McpServerManager {
  final List<BackgroundServices> bundles = [];

  @override
  Future<void> addBackgroundServer(BackgroundServices services) async {
    bundles.add(services);
    await super.addBackgroundServer(services);
  }
}

class _MutableSettings extends SettingsNotifier {
  _MutableSettings(this._initial);
  final AppSettings _initial;

  @override
  AppSettings build() => _initial;

  void setSettings(AppSettings next) => state = next;
}
