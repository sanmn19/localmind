import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/features/chat/data/mcp_client.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/chat/data/tools/mcp_tool_provider.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/data/tools/tool_registry.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/features/skills/data/skills_mcp_server.dart';
import 'package:localmind/features/skills/data/skills_provider.dart';
import 'package:localmind/features/skills/data/skills_store.dart';

class _RecordingManager extends McpServerManager {
  final List<SkillsServices> addedSkillsServices = [];

  @override
  Future<void> addSkillsServer(SkillsServices services) async {
    addedSkillsServices.add(services);
    await super.addSkillsServer(services);
  }
}

class _MutableSettings extends SettingsNotifier {
  _MutableSettings(this._initial);
  final AppSettings _initial;

  @override
  AppSettings build() => _initial;

  void setSettings(AppSettings next) => state = next;
}

/// A fake remote MCP integration shadowing the local skills tool names.
class _RemoteToolProvider implements ToolProvider {
  const _RemoteToolProvider();

  @override
  Future<List<ToolDefinition>> listTools() async => [
    for (final name in const [
      'skills.list',
      'skills.read',
      'skills.add',
      'skills.delete',
    ])
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

/// In-file filesystem fake keyed by base names (mirrors skills_provider_test).
class _FakeHost implements SkillFileHost {
  final Map<String, String> files = {};

  String _file(String name) => '$name.md';

  @override
  Future<List<String>> list() async =>
      files.keys.map(_baseName).toList()..sort();

  String _baseName(String file) =>
      file.endsWith('.md') ? file.substring(0, file.length - 3) : file;

  @override
  Future<String> read(String name) async => files[_file(name)]!;

  @override
  Future<void> write(String name, String content) async =>
      files[_file(name)] = content;

  @override
  Future<void> delete(String name) async {
    files.remove(_file(name));
  }
}

ProviderContainer _container({
  required McpServerManager manager,
  required _MutableSettings settings,
  required _FakeHost host,
}) {
  return ProviderContainer(
    overrides: [
      mcpServerManagerProvider.overrideWithValue(manager),
      settingsProvider.overrideWith(() => settings),
      skillsFileHostProvider.overrideWithValue(host),
    ],
  );
}

void main() {
  /// A minimal [SkillsServices] over the in-memory host: the auto-approval
  /// matrix only cares that the server is registered under `local://skills`
  /// so the registry attributes ownership to it.
  SkillsServices fakeBundle(_FakeHost host) => SkillsServices(
    list: () => SkillsStore(host).refresh(),
    add: (name, description, content) async {
      await SkillsStore(
        host,
      ).add(SkillEntry(name: name, description: description, body: content));
    },
    delete: (name) => SkillsStore(host).delete(name),
    enabled: () => true,
  );

  group('shouldAutoApproveTool — skills matrix', () {
    Future<ToolRegistry> localSkillsRegistry() async {
      final host = _FakeHost();
      final manager = McpServerManager();
      await manager.addSkillsServer(fakeBundle(host));
      return ToolRegistry(providers: [McpToolProvider(serverManager: manager)]);
    }

    Future<bool> approve(
      String toolName,
      ToolRegistry registry, {
      required bool skills,
    }) => shouldAutoApproveTool(
      toolName,
      webToolsEnabled: false,
      terminalToolsEnabled: false,
      skillsEnabled: skills,
      registry: registry,
      whitelist: null,
    );

    test('skills.list auto-approves while locally owned and enabled', () async {
      final registry = await localSkillsRegistry();
      expect(await approve('skills.list', registry, skills: true), isTrue);
    });

    test('skills.read auto-approves while locally owned and enabled', () async {
      final registry = await localSkillsRegistry();
      expect(await approve('skills.read', registry, skills: true), isTrue);
    });

    test('skills.read falls back to the dialog while disabled', () async {
      final registry = await localSkillsRegistry();
      expect(await approve('skills.read', registry, skills: false), isFalse);
    });

    test('skills.list falls back to the dialog while disabled', () async {
      final registry = await localSkillsRegistry();
      expect(await approve('skills.list', registry, skills: false), isFalse);
    });

    test('skills.add and skills.delete NEVER auto-approve', () async {
      final registry = await localSkillsRegistry();
      for (final name in const ['skills.add', 'skills.delete']) {
        expect(
          await approve(name, registry, skills: true),
          isFalse,
          reason: '$name is a write — always the approval dialog',
        );
        expect(await approve(name, registry, skills: false), isFalse);
      }
    });

    test(
      'remote-only shadowed skills names do not inherit the local bypass',
      () async {
        final registry = ToolRegistry(providers: [const _RemoteToolProvider()]);
        for (final name in const [
          'skills.list',
          'skills.read',
          'skills.add',
          'skills.delete',
        ]) {
          expect(
            await approve(name, registry, skills: true),
            isFalse,
            reason: '$name must not auto-approve when remote-owned',
          );
        }
      },
    );

    test('unrelated tools never leak into the skills bypass', () async {
      final registry = await localSkillsRegistry();
      expect(await approve('example.echo', registry, skills: true), isFalse);
      expect(await approve('skills.unknown', registry, skills: true), isFalse);
    });
  });

  group('webServerRegistrationProvider — skills wiring', () {
    test('registers the skills server while the switch is on', () async {
      final manager = _RecordingManager();
      final settings = _MutableSettings(AppSettings(skillsEnabled: true));
      final container = _container(
        manager: manager,
        settings: settings,
        host: _FakeHost(),
      );
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      expect(manager.hasSkillsServer(), isTrue);
      expect(manager.getServerUrl(skillsMcpServerLabel), skillsMcpServerUrl);
      final toolNames = manager
          .getTools(skillsMcpServerLabel)
          .map((t) => t.name)
          .toSet();
      expect(toolNames, {
        'skills.list',
        'skills.read',
        'skills.add',
        'skills.delete',
      });
    });

    test('does nothing while the switch is off', () async {
      final manager = _RecordingManager();
      final settings = _MutableSettings(AppSettings(skillsEnabled: false));
      final container = _container(
        manager: manager,
        settings: settings,
        host: _FakeHost(),
      );
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      expect(manager.hasSkillsServer(), isFalse);
      expect(manager.addedSkillsServices, isEmpty);
    });

    test('unregisters when the switch is toggled off', () async {
      final manager = _RecordingManager();
      final settings = _MutableSettings(AppSettings(skillsEnabled: true));
      final container = _container(
        manager: manager,
        settings: settings,
        host: _FakeHost(),
      );
      addTearDown(container.dispose);

      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();
      expect(manager.hasSkillsServer(), isTrue);

      settings.setSettings(AppSettings(skillsEnabled: false));
      await pumpEventQueue();
      expect(manager.hasSkillsServer(), isFalse);
    });

    test(
      'tears the skills server down when the container is disposed while on',
      () async {
        final manager = _RecordingManager();
        final settings = _MutableSettings(AppSettings(skillsEnabled: true));
        final container = _container(
          manager: manager,
          settings: settings,
          host: _FakeHost(),
        );

        container.listen(webServerRegistrationProvider, (_, _) {});
        await pumpEventQueue();
        expect(manager.hasSkillsServer(), isTrue);

        container.dispose();
        await pumpEventQueue();
        expect(manager.hasSkillsServer(), isFalse);
      },
    );

    test(
      'skills.add via the registered bundle writes through and refreshes the mirror',
      () async {
        final host = _FakeHost();
        final manager = _RecordingManager();
        final settings = _MutableSettings(AppSettings(skillsEnabled: true));
        final container = _container(
          manager: manager,
          settings: settings,
          host: host,
        );
        addTearDown(container.dispose);

        container.listen(webServerRegistrationProvider, (_, _) {});
        await pumpEventQueue();

        final output = await manager.callTool(
          skillsMcpServerLabel,
          'skills.add',
          {'name': 'alpha', 'description': 'First', 'content': 'Alpha body.'},
        );

        expect(output, 'Added skill: alpha');
        expect(container.read(skillsProvider).entries, [
          const SkillEntry(
            name: 'alpha',
            description: 'First',
            body: 'Alpha body.',
          ),
        ]);
      },
    );

    test(
      'skills.delete via the registered bundle drops the mirror entry again',
      () async {
        final host = _FakeHost();
        host.files['alpha.md'] = SkillsStore.serialize(
          const SkillEntry(
            name: 'alpha',
            description: 'First',
            body: 'Alpha body.',
          ),
        );
        final manager = _RecordingManager();
        final settings = _MutableSettings(AppSettings(skillsEnabled: true));
        final container = _container(
          manager: manager,
          settings: settings,
          host: host,
        );
        addTearDown(container.dispose);

        container.listen(webServerRegistrationProvider, (_, _) {});
        await pumpEventQueue();
        // The mirror only fills through refresh() — what the bootstrap does
        // at app start. Simulate it so the pre-state matches a real session.
        await container.read(skillsProvider.notifier).refresh();
        expect(container.read(skillsProvider).entries, isNotEmpty);

        final output = await manager.callTool(
          skillsMcpServerLabel,
          'skills.delete',
          {'name': 'alpha'},
        );

        expect(output, 'Deleted skill: alpha');
        expect(container.read(skillsProvider).entries, isEmpty);
      },
    );

    test(
      'skills.list renders the live store rows through the bundle',
      () async {
        final host = _FakeHost();
        host.files['beta.md'] = SkillsStore.serialize(
          const SkillEntry(
            name: 'beta',
            description: 'Second',
            body: 'Beta body.',
          ),
        );
        final manager = McpServerManager();
        final settings = _MutableSettings(AppSettings(skillsEnabled: true));
        final container = _container(
          manager: manager,
          settings: settings,
          host: host,
        );
        addTearDown(container.dispose);

        container.listen(webServerRegistrationProvider, (_, _) {});
        await pumpEventQueue();

        final output = await manager.callTool(
          skillsMcpServerLabel,
          'skills.list',
          {},
        );
        expect(output, '- beta: Second');
      },
    );

    test(
      'skills.add to a duplicate name through the bundle raises the McpException',
      () async {
        final host = _FakeHost();
        host.files['alpha.md'] = SkillsStore.serialize(
          const SkillEntry(
            name: 'alpha',
            description: 'First',
            body: 'Alpha body.',
          ),
        );
        final manager = _RecordingManager();
        final settings = _MutableSettings(AppSettings(skillsEnabled: true));
        final container = _container(
          manager: manager,
          settings: settings,
          host: host,
        );
        addTearDown(container.dispose);

        container.listen(webServerRegistrationProvider, (_, _) {});
        await pumpEventQueue();
        await container.read(skillsProvider.notifier).refresh();
        expect(container.read(skillsProvider).entries, hasLength(1));
        expect(container.read(skillsProvider).entries.single.name, 'alpha');

        expect(
          () => manager.callTool(skillsMcpServerLabel, 'skills.add', {
            'name': 'alpha',
            'content': 'Other body.',
          }),
          throwsA(
            isA<McpException>().having(
              (e) => e.message,
              'message',
              'skills.add: a skill named alpha already exists',
            ),
          ),
        );
        expect(container.read(skillsProvider).entries, hasLength(1));
      },
    );
  });
}
