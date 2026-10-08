import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/skills/data/skills_store.dart';

void main() {
  group('SkillsStore.parse', () {
    test('extracts name, description and body from frontmatter', () {
      final entry = SkillsStore.parse('alpha.md', '''
---
name: alpha
description: First skill
---
Body line one.
Body line two.''');
      expect(entry.name, 'alpha');
      expect(entry.description, 'First skill');
      expect(entry.body, 'Body line one.\nBody line two.');
    });

    test('handles CRLF line endings', () {
      final entry = SkillsStore.parse(
        'crlf.md',
        '---\r\nname: crlf\r\ndescription: Windows file\r\n---\r\n'
            'Body text.\r\nSecond line.',
      );
      expect(entry.name, 'crlf');
      expect(entry.description, 'Windows file');
      expect(entry.body, 'Body text.\r\nSecond line.');
    });

    test('falls back to the file name when frontmatter is missing', () {
      final entry = SkillsStore.parse('notes.md', 'Just some markdown body.');
      expect(entry.name, 'notes');
      expect(entry.description, '');
      expect(entry.body, 'Just some markdown body.');
    });

    test('round-trips through serialize', () {
      const entry = SkillEntry(
        name: 'round_trip',
        description: 'Docs',
        body: '# Title\n\nBody text.',
      );
      expect(
        SkillsStore.parse('whatever.md', SkillsStore.serialize(entry)),
        entry,
      );
    });
  });

  group('SkillsStore.serialize', () {
    test('renders frontmatter then the verbatim body', () {
      final text = SkillsStore.serialize(
        const SkillEntry(
          name: 'code',
          description: 'Run code',
          body: 'print(hi);',
        ),
      );
      expect(text, '---\nname: code\ndescription: Run code\n---\nprint(hi);');
    });
  });

  group('SkillsStore.normalizeName', () {
    test('lowercases and turns spaces into underscores', () {
      expect(SkillsStore.normalizeName('My Cool Skill'), 'my_cool_skill');
    });

    test('collapses underscore runs and trims the edges', () {
      expect(
        SkillsStore.normalizeName('  Inference__  notes  '),
        'inference_notes',
      );
    });

    test('strips symbols that are not alnum or underscore', () {
      expect(SkillsStore.normalizeName('a&b!C-d'), 'abcd');
    });

    test('caps the length at 48 characters', () {
      final normalized = SkillsStore.normalizeName('a' * 60);
      expect(normalized.length, 48);
      expect(SkillsStore.isValidName(normalized), isTrue);
    });
  });

  group('SkillsStore.isValidName', () {
    test('accepts lowercase snake names within the 48 char cap', () {
      expect(SkillsStore.isValidName('quick_start'), isTrue);
      expect(SkillsStore.isValidName('a'), isTrue);
      expect(SkillsStore.isValidName('a' * 48), isTrue);
    });

    test('rejects uppercase, symbols, empty and overlong names', () {
      expect(SkillsStore.isValidName('Quick'), isFalse);
      expect(SkillsStore.isValidName('quick-start'), isFalse);
      expect(SkillsStore.isValidName('quick start'), isFalse);
      expect(SkillsStore.isValidName(''), isFalse);
      expect(SkillsStore.isValidName('a' * 49), isFalse);
    });
  });

  group('SkillsStore CRUD over a fake host', () {
    late _FakeHost host;
    late SkillsStore store;

    setUp(() {
      host = _FakeHost();
      store = SkillsStore(host);
    });

    test('refresh reads and parses every stored skill in name order', () async {
      host.files['beta.md'] = 'no frontmatter body';
      host.files['alpha.md'] = SkillsStore.serialize(
        const SkillEntry(
          name: 'alpha',
          description: 'First',
          body: 'Alpha body.',
        ),
      );

      final entries = await store.refresh();
      expect(entries.map((e) => e.name).toList(), ['alpha', 'beta']);
      expect(
        entries[0],
        const SkillEntry(
          name: 'alpha',
          description: 'First',
          body: 'Alpha body.',
        ),
      );
    });

    test('refresh over an empty host yields nothing', () async {
      expect(await store.refresh(), isEmpty);
    });

    test('add normalizes the name and writes the serialized file', () async {
      await store.add(
        const SkillEntry(name: 'My New Skill', description: 'D', body: 'B'),
      );
      expect(host.files.keys, contains('my_new_skill.md'));
      final parsed = SkillsStore.parse(
        'my_new_skill.md',
        host.files['my_new_skill.md']!,
      );
      expect(parsed.name, 'my_new_skill');
      expect(parsed.description, 'D');
      expect(parsed.body, 'B');
    });

    test('add rejects a name that normalizes away entirely', () async {
      await expectLater(
        store.add(const SkillEntry(name: '!!!', description: '', body: 'b')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('invalid skill name'),
          ),
        ),
      );
      expect(host.files, isEmpty);
    });

    test('add rejects a duplicate normalized name', () async {
      await store.add(
        const SkillEntry(name: 'alpha', description: 'd', body: 'b'),
      );
      await expectLater(
        store.add(
          const SkillEntry(name: '  Alpha ', description: 'other', body: 'x'),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('already exists'),
          ),
        ),
      );
      final entries = await store.refresh();
      expect(entries, hasLength(1));
      expect(entries.single.description, 'd');
    });

    test('delete of a missing skill does not throw', () async {
      await store.delete('ghost');
      expect(host.files, isEmpty);
    });

    test('delete drops the file', () async {
      await store.add(
        const SkillEntry(name: 'alpha', description: 'd', body: 'b'),
      );
      await store.delete('alpha');
      expect(host.files.containsKey('alpha.md'), isFalse);
    });

    test(
      'update writes the new file and removes the old one on rename',
      () async {
        await store.add(
          const SkillEntry(name: 'alpha', description: 'd', body: 'b'),
        );
        await store.update(
          'alpha',
          const SkillEntry(name: 'alpha_v2', description: 'renamed', body: 'n'),
        );

        expect(host.files.containsKey('alpha.md'), isFalse);
        expect(host.files.containsKey('alpha_v2.md'), isTrue);
        final parsed = SkillsStore.parse(
          'alpha_v2.md',
          host.files['alpha_v2.md']!,
        );
        expect(
          parsed,
          const SkillEntry(name: 'alpha_v2', description: 'renamed', body: 'n'),
        );
      },
    );

    test('update rejects renaming onto an existing skill', () async {
      await store.add(
        const SkillEntry(name: 'alpha', description: 'd', body: 'b'),
      );
      await store.add(
        const SkillEntry(name: 'beta', description: 'd', body: 'b'),
      );
      await expectLater(
        store.update(
          'alpha',
          const SkillEntry(name: 'beta', description: 'x', body: 'x'),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('already exists'),
          ),
        ),
      );
      expect(host.files.containsKey('alpha.md'), isTrue);
      expect(host.files.containsKey('beta.md'), isTrue);
    });

    test('update to the same name rewrites the file in place', () async {
      await store.add(
        const SkillEntry(name: 'alpha', description: 'old', body: 'old body'),
      );
      await store.update(
        'alpha',
        const SkillEntry(name: 'alpha', description: 'new', body: 'new body'),
      );
      expect(host.files.keys, ['alpha.md']);
      final parsed = SkillsStore.parse('alpha.md', host.files['alpha.md']!);
      expect(
        parsed,
        const SkillEntry(name: 'alpha', description: 'new', body: 'new body'),
      );
    });
  });

  group('buildSkillsSystemSection', () {
    test('lists the header, every name row and every body verbatim', () {
      final section = buildSkillsSystemSection(const [
        SkillEntry(
          name: 'release_checklist',
          description: 'Release checks',
          body: 'Run the smoke tests.',
        ),
        SkillEntry(
          name: 'code_style',
          description: 'House style',
          body: 'Keep lines short.',
        ),
      ]);

      expect(section, startsWith('# Skills'));
      expect(section, contains('The user maintains these skills.'));
      expect(section, contains('- release_checklist: Release checks'));
      expect(section, contains('Run the smoke tests.'));
      expect(section, contains('- code_style: House style'));
      expect(section, contains('Keep lines short.'));
      expect(section, isNot(contains(skillsTruncationMarker)));
    });

    test('emits nothing when there are no entries', () {
      expect(buildSkillsSystemSection(const []), '');
    });

    test('keeps all bodies when they fit the shared budget', () {
      final section = buildSkillsSystemSection([
        for (var i = 1; i <= 2; i++)
          SkillEntry(
            name: 'skill_$i',
            description: 'Skill $i',
            body: 'unique$i ${'x' * 5000}',
          ),
      ]);

      expect(section, isNot(contains(skillsTruncationMarker)));
      expect(section, contains('unique1'));
      expect(section, contains('unique2'));
    });

    test('drops bodies past the budget but keeps every name row', () {
      final section = buildSkillsSystemSection([
        for (var i = 1; i <= 4; i++)
          SkillEntry(
            name: 'skill_$i',
            description: 'Skill $i',
            body: 'unique$i ${'x' * 5000}',
          ),
      ]);

      expect(section, contains(skillsTruncationMarker));
      expect(section, startsWith('# Skills'));
      for (var i = 1; i <= 4; i++) {
        expect(section, contains('- skill_$i: Skill $i'));
      }
      expect(section, contains('unique1'));
      expect(section, contains('unique2'));
      expect(section, isNot(contains('unique3')));
      expect(section, isNot(contains('unique4')));
      // The budget holds even with the always-kept name rows.
      expect(section.length, lessThanOrEqualTo(12650));
    });
  });

  group('DirectorySkillFileHost integration', () {
    test('persists skill files under skills/ in the given directory', () async {
      final temp = Directory.systemTemp.createTempSync('skills_store_test');
      addTearDown(() => temp.deleteSync(recursive: true));
      final host = DirectorySkillFileHost(Future.value(temp));
      const entry = SkillEntry(
        name: 'on_disk',
        description: 'Disk',
        body: 'Saved to disk.',
      );
      final store = SkillsStore(host);

      await store.add(entry);
      final file = File('${temp.path}/skills/on_disk.md');
      expect(file.existsSync(), isTrue);

      final loaded = await store.refresh();
      expect(loaded, [entry]);

      await store.delete('on_disk');
      expect(file.existsSync(), isFalse);
      expect(await store.refresh(), isEmpty);
    });
  });
}

/// In-file boundary fake keyed like the real host by base names.
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
