import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/mcp_client.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/skills/data/skills_mcp_server.dart';
import 'package:localmind/features/skills/data/skills_store.dart';

/// In-file boundary fake keyed by base names (mirrors skills_provider_test).
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

/// Harness bundling the in-memory host with [SkillsServices] closure
/// records so the manager's dispatcher contract (the resolved names it
/// hands over, which failures skip delegation) is directly assertable.
class _Harness {
  _Harness({this.enabledFlag = true});

  final _FakeHost host = _FakeHost();
  final added = <List<String>>[];
  final deleted = <String>[];
  int refreshCalls = 0;
  bool enabledFlag;

  void seed(String name, {String description = '', String body = ''}) {
    host.files['$name.md'] = SkillsStore.serialize(
      SkillEntry(name: name, description: description, body: body),
    );
  }

  /// Real mechanic: writes go to the host first, then the refresh hook
  /// runs — exactly the write-through shape the registration wires.
  SkillsServices build() {
    return SkillsServices(
      list: () => SkillsStore(host).refresh(),
      add: (name, description, content) async {
        added.add([name, description, content]);
        await SkillsStore(
          host,
        ).add(SkillEntry(name: name, description: description, body: content));
      },
      delete: (name) async {
        deleted.add(name);
        await SkillsStore(host).delete(name);
      },
      enabled: () {
        refreshCalls++;
        return enabledFlag;
      },
    );
  }
}

Future<McpServerManager> _managerWith(_Harness harness) async {
  final manager = McpServerManager();
  await manager.addSkillsServer(harness.build());
  return manager;
}

void main() {
  group('skills mcp server registration', () {
    test(
      'addSkillsServer advertises the four tools with the local url',
      () async {
        final manager = await _managerWith(_Harness());

        expect(manager.hasSkillsServer(), isTrue);
        expect(manager.hasServer(skillsMcpServerLabel), isTrue);
        expect(manager.serverLabels, contains(skillsMcpServerLabel));
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
        expect(manager.hasWebServer(), isFalse);
        expect(manager.hasTerminalServer(), isFalse);
      },
    );

    test('skills.read schema requires exactly the name', () async {
      final manager = await _managerWith(_Harness());

      final read = manager
          .getTools(skillsMcpServerLabel)
          .firstWhere((t) => t.name == 'skills.read');
      expect(read.inputSchema['required'], ['name']);
      expect((read.inputSchema['properties'] as Map).keys, ['name']);
    });

    test(
      'the read-path descriptions reference skills.read, not injection',
      () async {
        final manager = await _managerWith(_Harness());
        final tools = manager.getTools(skillsMcpServerLabel);

        final read = tools.firstWhere((t) => t.name == 'skills.read');
        expect(
          read.description,
          "Return the full instructions of one skill by name; use it before "
          "following a skill's details.",
        );
        // The old 'body is already injected' claim is false under progressive
        // disclosure: the list points at skills.read instead.
        final list = tools.firstWhere((t) => t.name == 'skills.list');
        expect(list.description, contains('skills.read'));
        expect(list.description, isNot(contains('already injected')));
      },
    );

    test('skills.add schema requires name and content', () async {
      final manager = await _managerWith(_Harness());

      final add = manager
          .getTools(skillsMcpServerLabel)
          .firstWhere((t) => t.name == 'skills.add');
      expect(
        (add.inputSchema['required'] as List),
        containsAll(['name', 'content']),
      );
      final properties = add.inputSchema['properties'] as Map;
      expect(properties.keys, containsAll(['name', 'content', 'description']));
    });

    test('re-registration replaces without duplicating', () async {
      final manager = McpServerManager();
      await manager.addSkillsServer(_Harness().build());
      await manager.addSkillsServer(_Harness().build());

      expect(manager.getTools(skillsMcpServerLabel), hasLength(4));
      expect(manager.getSkillsServices(), isNotNull);
      expect(manager.serverCount, 1);
    });

    test('removeServer and clear tear the skills server down', () async {
      final harness = _Harness()..seed('alpha');
      final manager = await _managerWith(harness);

      await manager.removeServer(skillsMcpServerLabel);
      expect(manager.hasSkillsServer(), isFalse);
      expect(manager.getSkillsServices(), isNull);
      expect(manager.hasServer(skillsMcpServerLabel), isFalse);

      final harness2 = _Harness()..seed('alpha');
      final manager2 = await _managerWith(harness2);
      await manager2.clear();
      expect(manager2.hasSkillsServer(), isFalse);
    });
  });

  group('skills.list dispatch', () {
    test('renders `- name: description` rows in store order', () async {
      final harness = _Harness()
        ..seed('alpha', description: 'First')
        ..seed('beta', description: 'Second');
      final manager = await _managerWith(harness);

      final output = await manager.callTool(
        skillsMcpServerLabel,
        'skills.list',
        {},
      );

      expect(output, '''
- alpha: First
- beta: Second''');
    });

    test('an empty store renders the friendly placeholder', () async {
      final manager = await _managerWith(_Harness());

      final output = await manager.callTool(
        skillsMcpServerLabel,
        'skills.list',
        {},
      );
      expect(output, 'No skills defined.');
    });
  });

  group('skills.read dispatch', () {
    test('renders header, description and the full body', () async {
      final harness = _Harness()
        ..seed('alpha', description: 'First', body: 'Alpha body.');
      final manager = await _managerWith(harness);

      final output = await manager.callTool(
        skillsMcpServerLabel,
        'skills.read',
        {'name': 'alpha'},
      );

      expect(harness.host.files, isNotEmpty);
      expect(output, '# alpha\nFirst\n\nAlpha body.');
    });

    test('a missing name raises the dispatcher McpException', () async {
      final harness = _Harness()..seed('alpha');
      final manager = await _managerWith(harness);

      expect(
        () => manager.callTool(skillsMcpServerLabel, 'skills.read', {
          'name': 'nope',
        }),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            'skills.read: no skill named nope',
          ),
        ),
      );
    });

    test('requires a string name argument', () async {
      final harness = _Harness()..seed('alpha');
      final manager = await _managerWith(harness);

      expect(
        () => manager.callTool(skillsMcpServerLabel, 'skills.read', {}),
        throwsA(isA<McpException>()),
      );
      expect(
        () =>
            manager.callTool(skillsMcpServerLabel, 'skills.read', {'name': 7}),
        throwsA(isA<McpException>()),
      );
    });

    test('a huge body trims at the read cap with the marker', () async {
      final harness = _Harness()
        ..seed('big', description: 'Big', body: 'z' * 13000);
      final manager = await _managerWith(harness);

      final output = await manager.callTool(
        skillsMcpServerLabel,
        'skills.read',
        {'name': 'big'},
      );

      expect(output, endsWith('\n$skillsReadTruncationMarker'));
      expect(
        output.length,
        skillsReadMaxChars + 1 + skillsReadTruncationMarker.length,
      );
      expect(output, startsWith('# big\nBig\n\n'));
      final composed = '# big\nBig\n\n${'z' * 13000}';
      expect(
        output.substring(0, skillsReadMaxChars),
        composed.substring(0, skillsReadMaxChars),
      );
    });
  });

  group('skills.add dispatch', () {
    test('adds a skill and reports the resolved name', () async {
      final harness = _Harness();
      final manager = await _managerWith(harness);

      final output = await manager.callTool(
        skillsMcpServerLabel,
        'skills.add',
        {'name': 'alpha', 'description': 'First', 'content': 'Alpha body.'},
      );

      expect(output, 'Added skill: alpha');
      expect(harness.added.single, ['alpha', 'First', 'Alpha body.']);
      expect(harness.host.files['alpha.md'], contains('Alpha body.'));
    });

    test('normalizes a mixed-case name before persisting', () async {
      final harness = _Harness();
      final manager = await _managerWith(harness);

      final output = await manager.callTool(
        skillsMcpServerLabel,
        'skills.add',
        {'name': 'My Cool Skill', 'content': 'Body'},
      );

      expect(output, 'Added skill: my_cool_skill');
      expect(harness.added.single.first, 'my_cool_skill');
      // The description argument is optional and defaults to empty.
      expect(harness.added.single[1], '');
    });

    test('an invalid name raises the dispatcher McpException', () async {
      final harness = _Harness();
      final manager = await _managerWith(harness);

      expect(
        () => manager.callTool(skillsMcpServerLabel, 'skills.add', {
          'name': '!!!',
          'content': 'Body',
        }),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            'skills.add: invalid skill name "!!!" — lowercase letters, '
                'digits and underscores (max ${SkillsStore.maxNameLength})',
          ),
        ),
      );
      expect(harness.added, isEmpty);
    });

    test('a duplicate name raises the dispatcher McpException', () async {
      final harness = _Harness()..seed('alpha');
      final manager = await _managerWith(harness);

      expect(
        () => manager.callTool(skillsMcpServerLabel, 'skills.add', {
          'name': 'alpha',
          'content': 'Body',
        }),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            'skills.add: a skill named alpha already exists',
          ),
        ),
      );
      expect(harness.added, isEmpty);
    });

    test('requires string name and content arguments', () async {
      final harness = _Harness();
      final manager = await _managerWith(harness);

      expect(
        () => manager.callTool(skillsMcpServerLabel, 'skills.add', {}),
        throwsA(isA<McpException>()),
      );
      expect(
        () => manager.callTool(skillsMcpServerLabel, 'skills.add', {
          'name': 42,
          'content': 'Body',
        }),
        throwsA(isA<McpException>()),
      );
      expect(
        () => manager.callTool(skillsMcpServerLabel, 'skills.add', {
          'name': 'alpha',
        }),
        throwsA(isA<McpException>()),
      );
      expect(harness.added, isEmpty);
    });
  });

  group('skills.delete dispatch', () {
    test('deletes a skill and reports the resolved name', () async {
      final harness = _Harness()..seed('alpha');
      final manager = await _managerWith(harness);

      final output = await manager.callTool(
        skillsMcpServerLabel,
        'skills.delete',
        {'name': 'alpha'},
      );

      expect(output, 'Deleted skill: alpha');
      expect(harness.deleted, ['alpha']);
      expect(harness.host.files, isEmpty);
    });

    test('a missing name raises the dispatcher McpException', () async {
      final harness = _Harness();
      final manager = await _managerWith(harness);

      expect(
        () => manager.callTool(skillsMcpServerLabel, 'skills.delete', {
          'name': 'nope',
        }),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            'skills.delete: no skill named nope',
          ),
        ),
      );
      expect(harness.deleted, isEmpty);
    });

    test('requires a string name argument', () async {
      final harness = _Harness()..seed('alpha');
      final manager = await _managerWith(harness);

      expect(
        () => manager.callTool(skillsMcpServerLabel, 'skills.delete', {}),
        throwsA(isA<McpException>()),
      );
      expect(
        () => manager.callTool(skillsMcpServerLabel, 'skills.delete', {
          'name': 7,
        }),
        throwsA(isA<McpException>()),
      );
      expect(harness.deleted, isEmpty);
    });
  });

  group('skills server guards', () {
    test('unknown tool names raise McpException', () async {
      final manager = await _managerWith(_Harness());

      expect(
        () => manager.callTool(skillsMcpServerLabel, 'skills.nope', {}),
        throwsA(isA<McpException>()),
      );
    });

    test('a disabled bundle refuses every skills tool', () async {
      final harness = _Harness(enabledFlag: false)..seed('alpha');
      final manager = await _managerWith(harness);

      for (final (name, args) in const <(String, Map<String, dynamic>)>[
        ('skills.list', {}),
        ('skills.read', {'name': 'alpha'}),
        ('skills.add', {'name': 'alpha', 'content': 'b'}),
        ('skills.delete', {'name': 'alpha'}),
      ]) {
        expect(
          () => manager.callTool(skillsMcpServerLabel, name, args),
          throwsA(
            isA<McpException>().having(
              (e) => e.message,
              'message',
              'the skills feature is disabled',
            ),
          ),
          reason: '$name must refuse while the kill switch is off',
        );
      }
      expect(harness.added, isEmpty);
      expect(harness.deleted, isEmpty);
      expect(harness.enabledFlag, isFalse);
    });
  });
}
