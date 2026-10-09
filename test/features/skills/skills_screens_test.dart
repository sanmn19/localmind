import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/theme/app_theme.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/features/skills/data/skills_provider.dart';
import 'package:localmind/features/skills/data/skills_store.dart';
import 'package:localmind/features/skills/views/skill_editor_screen.dart';
import 'package:localmind/features/skills/views/skills_screen.dart';
import 'package:localmind/l10n/app_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory [SkillFileHost] that records what the screens did to it —
/// the same fake shape the provider/store unit tests use.
class _RecordingHost implements SkillFileHost {
  final files = <String, String>{};
  final writes = <String>[];
  final deletes = <String>[];

  @override
  Future<List<String>> list() async => files.keys.toList()..sort();

  @override
  Future<String> read(String name) async => files[name]!;

  @override
  Future<void> write(String name, String content) async {
    writes.add(name);
    files[name] = content;
  }

  @override
  Future<void> delete(String name) async {
    deletes.add(name);
    files.remove(name);
  }
}

Widget _materialApp(Widget home) {
  return ShadTheme(
    data: AppTheme.lightShadTheme,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
}

/// Mock app prefs seeded the way the app persists settings, settled
/// eagerly before the container builds, exactly like the provider tests.
Future<SharedPreferences> _seededPrefs() async {
  SharedPreferences.setMockInitialValues({
    'appSettings': AppSettings().toJson(),
  });
  return SharedPreferences.getInstance();
}

/// Pumps [child] as the home page inside the same chrome the app would give
/// it. The provider mirror starts empty; tests drive
/// [SkillsNotifier.refresh] the way the app does.
Future<void> _pumpHarness(
  WidgetTester tester,
  _RecordingHost host, {
  required Widget child,
}) async {
  final prefs = await _seededPrefs();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        skillsFileHostProvider.overrideWithValue(host),
      ],
      child: _materialApp(Scaffold(body: child)),
    ),
  );
  await tester.pump();
}

/// Same harness but driven by a real router, for screens that navigate.
/// Home is a marker page so a successful editor pop lands somewhere
/// assertable; `/skills/edit` mounts the editor as `/`'s child so
/// `context.pop()` has a page below it, mirroring the shell setup.
Future<GoRouter> _pumpRoutedHarness(
  WidgetTester tester,
  _RecordingHost host, {
  required SkillEntry? editorEntry,
}) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('HOME')),
      ),
      GoRoute(
        path: '/skills/edit',
        builder: (_, _) => Scaffold(
          // The harness hands the entry directly — route extra plumbing isn't
          // what these tests exercise.
          body: SkillEditorScreen(existing: editorEntry),
        ),
      ),
    ],
  );
  final prefs = await _seededPrefs();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        skillsFileHostProvider.overrideWithValue(host),
      ],
      child: ShadTheme(
        data: AppTheme.lightShadTheme,
        child: MaterialApp.router(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pump();
  router.push('/skills/edit');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return router;
}

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(SkillsScreen)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingHost host;

  setUp(() => host = _RecordingHost());

  group('SkillsScreen', () {
    testWidgets('shows toggle, empty state and the add FAB', (tester) async {
      await _pumpHarness(tester, host, child: const SkillsScreen());
      final l10n = lookupAppLocalizations(const Locale('en'));

      expect(find.byKey(const Key('skills_toggle')), findsOneWidget);
      expect(find.byKey(const Key('skills_add_fab')), findsOneWidget);
      expect(find.text(l10n.skills_name), findsOneWidget);

      // Nothing until the mirror has been refreshed from the host.
      await _containerOf(tester).read(skillsProvider.notifier).refresh();
      await tester.pumpAndSettle();

      expect(find.text(l10n.skills_toggle), findsOneWidget);
      expect(find.text(l10n.skills_empty), findsOneWidget);
    });

    testWidgets('lists seeded skills with edit and delete actions', (
      tester,
    ) async {
      await _pumpHarness(tester, host, child: const SkillsScreen());

      host.files['alpha'] = SkillsStore.serialize(
        const SkillEntry(
          name: 'alpha',
          description: 'First skill',
          body: 'Alpha body.',
        ),
      );
      await _containerOf(tester).read(skillsProvider.notifier).refresh();
      await tester.pumpAndSettle();

      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('First skill'), findsOneWidget);
      expect(find.byKey(const Key('skill_edit_alpha')), findsOneWidget);
      expect(find.byKey(const Key('skill_delete_alpha')), findsOneWidget);
    });

    testWidgets('the master toggle flips state and persists to settings', (
      tester,
    ) async {
      await _pumpHarness(tester, host, child: const SkillsScreen());
      final container = _containerOf(tester);
      expect(container.read(skillsProvider).enabled, isTrue);

      await tester.tap(find.byKey(const Key('skills_toggle')));
      await tester.pumpAndSettle();

      expect(container.read(skillsProvider).enabled, isFalse);
      expect(container.read(settingsProvider).skillsEnabled, isFalse);

      await tester.tap(find.byKey(const Key('skills_toggle')));
      await tester.pumpAndSettle();
      expect(container.read(skillsProvider).enabled, isTrue);
    });

    testWidgets('delete shows a confirm dialog and removes the skill', (
      tester,
    ) async {
      await _pumpHarness(tester, host, child: const SkillsScreen());
      host.files['alpha'] = SkillsStore.serialize(
        const SkillEntry(name: 'alpha', description: 'First', body: 'B.'),
      );
      final container = _containerOf(tester);
      await container.read(skillsProvider.notifier).refresh();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('skill_delete_alpha')));
      await tester.pumpAndSettle();

      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(find.text(l10n.skills_delete_confirm('alpha')), findsOneWidget);
      expect(find.text(l10n.cannot_undo), findsOneWidget);
      expect(find.text(l10n.cancel), findsOneWidget);

      await tester.tap(find.text(l10n.skills_delete));
      await tester.pumpAndSettle();

      expect(host.deletes, ['alpha']);
      expect(host.files, isEmpty);
      expect(container.read(skillsProvider).entries, isEmpty);
    });
  });

  group('SkillEditorScreen', () {
    testWidgets('an invalid name shows the inline hint and saves nothing', (
      tester,
    ) async {
      final router = await _pumpRoutedHarness(tester, host, editorEntry: null);
      final l10n = lookupAppLocalizations(const Locale('en'));

      await tester.enterText(find.byKey(const Key('skill_name_field')), '!!!');
      await tester.pump();
      await tester.tap(find.byKey(const Key('skill_save')));
      await tester.pump();

      expect(find.byKey(const Key('skill_name_error')), findsOneWidget);
      expect(find.text(l10n.name_invalid_hint), findsOneWidget);
      expect(host.writes, isEmpty);
      // Still on the editor: no pop back home.
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/skills/edit',
      );
    });

    testWidgets('the normalized name previews live while typing', (
      tester,
    ) async {
      await _pumpRoutedHarness(tester, host, editorEntry: null);

      await tester.enterText(
        find.byKey(const Key('skill_name_field')),
        'My Cool Skill',
      );
      await tester.pump();

      expect(find.byKey(const Key('skill_name_preview')), findsOneWidget);
      expect(find.text('@my_cool_skill'), findsOneWidget);
    });

    testWidgets('a valid save writes the store, refreshes and pops', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1080, 1920));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpRoutedHarness(tester, host, editorEntry: null);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SkillEditorScreen)),
      );

      await tester.enterText(
        find.byKey(const Key('skill_name_field')),
        'alpha',
      );
      await tester.enterText(
        find.byKey(const Key('skill_description_field')),
        'First described',
      );
      await tester.enterText(
        find.byKey(const Key('skill_body_field')),
        '# Alpha\nDo the thing.',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('skill_save')));
      await tester.pumpAndSettle();

      expect(host.writes, ['alpha']);
      expect(host.files.containsKey('alpha'), isTrue);
      expect(host.files['alpha'], contains('name: alpha'));
      expect(host.files['alpha'], contains('First described'));

      expect(container.read(skillsProvider).entries, hasLength(1));
      expect(container.read(skillsProvider).entries.single.name, 'alpha');

      // Popped back (the editor leaves the tree) after a successful save.
      expect(find.byType(SkillEditorScreen), findsNothing);
    });

    testWidgets('a duplicate name reports the store clash inline', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1080, 1920));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      host.files['alpha'] = SkillsStore.serialize(
        const SkillEntry(name: 'alpha', description: 'Existing', body: ''),
      );
      await _pumpRoutedHarness(tester, host, editorEntry: null);
      final l10n = lookupAppLocalizations(const Locale('en'));

      await tester.enterText(
        find.byKey(const Key('skill_name_field')),
        'alpha',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('skill_save')));
      await tester.pump();

      expect(find.text(l10n.duplicate_name_hint), findsOneWidget);
      expect(host.writes, isEmpty);
    });

    testWidgets('editing an existing entry deletes through the dialog', (
      tester,
    ) async {
      final existing = const SkillEntry(
        name: 'alpha',
        description: 'Existing',
        body: 'Some body.',
      );
      host.files['alpha'] = SkillsStore.serialize(existing);
      await _pumpRoutedHarness(tester, host, editorEntry: existing);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SkillEditorScreen)),
      );
      await container.read(skillsProvider.notifier).refresh();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('skill_delete')));
      await tester.pumpAndSettle();

      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(find.text(l10n.skills_delete_confirm('alpha')), findsOneWidget);
      // Two 'Delete' texts exist (the editor's icon row + the dialog's
      // confirm button) — tap the dialog's one.
      await tester.tap(find.text(l10n.skills_delete).last);
      await tester.pumpAndSettle();

      expect(host.deletes, ['alpha']);
      expect(container.read(skillsProvider).entries, isEmpty);
      // Popped off the editor after deletion.
      expect(find.byType(SkillEditorScreen), findsNothing);
    });
  });
}
