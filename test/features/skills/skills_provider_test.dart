import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/features/skills/data/skills_provider.dart';
import 'package:localmind/features/skills/data/skills_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late _FakeHost host;

  setUp(() {
    host = _FakeHost();
  });

  Future<ProviderContainer> makeContainer(Map<String, Object> prefsSeed) async {
    SharedPreferences.setMockInitialValues(prefsSeed);
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        skillsFileHostProvider.overrideWithValue(host),
      ],
    );
    return container;
  }

  Map<String, Object> seedWithSettings(AppSettings settings) => {
    'appSettings': settings.toJson(),
  };

  test(
    'build starts with the settings switch and an empty in-memory mirror',
    () async {
      final container = await makeContainer({});
      addTearDown(container.dispose);

      final state = container.read(skillsProvider);
      expect(state.enabled, isTrue);
      expect(state.entries, isEmpty);
    },
  );

  test('build mirrors a persisted disabled switch', () async {
    final container = await makeContainer(
      seedWithSettings(AppSettings().copyWith(skillsEnabled: false)),
    );
    addTearDown(container.dispose);

    final state = container.read(skillsProvider);
    expect(state.enabled, isFalse);
    expect(state.entries, isEmpty);
  });

  test('refresh loads entries from the file host and keeps enabled', () async {
    final container = await makeContainer({});
    addTearDown(container.dispose);
    host.files['alpha.md'] = SkillsStore.serialize(
      const SkillEntry(
        name: 'alpha',
        description: 'First',
        body: 'Alpha body.',
      ),
    );

    await container.read(skillsProvider.notifier).refresh();

    final state = container.read(skillsProvider);
    expect(state.entries, [
      const SkillEntry(
        name: 'alpha',
        description: 'First',
        body: 'Alpha body.',
      ),
    ]);
    expect(state.enabled, isTrue);
  });

  test('a bootstrap-shaped refresh over an empty host stays empty', () async {
    // The app boot calls refresh() off the critical path on the empty
    // documents dir — that must complete without bailing into the
    // bootstrap error state.
    final container = await makeContainer({});
    addTearDown(container.dispose);

    await container.read(skillsProvider.notifier).refresh();

    final state = container.read(skillsProvider);
    expect(state.entries, isEmpty);
    expect(state.enabled, isTrue);
  });

  test('refresh re-reads the settings switch each pass', () async {
    final container = await makeContainer({});
    addTearDown(container.dispose);
    expect(container.read(skillsProvider).enabled, isTrue);

    final prefs = container.read(sharedPreferencesProvider);
    await container
        .read(settingsProvider.notifier)
        .updateSettings(AppSettings().copyWith(skillsEnabled: false));

    await container.read(skillsProvider.notifier).refresh();

    expect(container.read(skillsProvider).enabled, isFalse);
    expect(prefs.getString('appSettings'), contains('"skillsEnabled":false'));
  });

  test(
    'setEnabled writes the settings flag through the settings notifier',
    () async {
      final container = await makeContainer({});
      addTearDown(container.dispose);

      await container.read(skillsProvider.notifier).setEnabled(false);

      final state = container.read(skillsProvider);
      expect(state.enabled, isFalse);
      expect(container.read(settingsProvider).skillsEnabled, isFalse);
      final prefs = container.read(sharedPreferencesProvider);
      final restored = AppSettings.fromJson(prefs.getString('appSettings')!);
      expect(restored.skillsEnabled, isFalse);
    },
  );

  test('setEnabled back on persists true', () async {
    final container = await makeContainer({});
    addTearDown(container.dispose);
    final notifier = container.read(skillsProvider.notifier);
    await notifier.setEnabled(false);

    await notifier.setEnabled(true);

    expect(container.read(skillsProvider).enabled, isTrue);
    final restored = AppSettings.fromJson(
      container.read(sharedPreferencesProvider).getString('appSettings')!,
    );
    expect(restored.skillsEnabled, isTrue);
  });
}

/// In-file boundary fake keyed by base names.
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
