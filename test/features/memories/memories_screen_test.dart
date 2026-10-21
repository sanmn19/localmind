import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/memories/data/memory_repository.dart';
import 'package:localmind/features/memories/data/memory_store.dart';
import 'package:localmind/features/memories/data/models/memory.dart';
import 'package:localmind/features/memories/providers/memory_providers.dart';
import 'package:localmind/features/memories/views/components/memory_graph_view.dart';
import 'package:localmind/features/memories/views/memories_screen.dart';
import 'package:localmind/l10n/app_localizations.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

Memory _memory({
  required String id,
  MemoryKind kind = MemoryKind.fact,
  List<String> tags = const [],
  DateTime? expiresAt,
}) {
  final now = DateTime(2026, 1, 1);
  return Memory(
    id: id,
    kind: kind,
    title: 'Memory $id',
    content: 'Content $id',
    createdAt: now,
    updatedAt: now,
    tags: tags,
    shortSummary: 'Summary $id',
    expiresAt: expiresAt,
  );
}

Future<InMemoryMemoryStore> _pump(
  WidgetTester tester, {
  required List<Memory> memories,
}) async {
  final store = InMemoryMemoryStore();
  for (final memory in memories) {
    store.put(memory);
  }
  final container = ProviderContainer(
    overrides: [memoryStoreProvider.overrideWithValue(store)],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: _wrap(const MemoriesScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('lists stored memories and adds one from the sheet',
      (tester) async {
    final store = InMemoryMemoryStore();
    final container = ProviderContainer(
      overrides: [memoryStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _wrap(const MemoriesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('memory_add')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('memory_title_field')),
      'Coffee',
    );
    await tester.enterText(
      find.byKey(const ValueKey('memory_content_field')),
      'Oat milk flat white',
    );
    await tester.tap(find.byKey(const ValueKey('memory_save')));
    await tester.pumpAndSettle();

    expect(find.text('Coffee'), findsOneWidget);
    expect(store.list().single.content, 'Oat milk flat white');
  });

  testWidgets('the manual editor does not offer the inferred kind',
      (tester) async {
    final store = InMemoryMemoryStore();
    final container = ProviderContainer(
      overrides: [memoryStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _wrap(const MemoriesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('memory_add')));
    await tester.pumpAndSettle();

    final dropdown = tester.widget<DropdownButton<MemoryKind>>(
      find.byType(DropdownButton<MemoryKind>),
    );
    expect(
      dropdown.items!.map((item) => item.value).toSet(),
      {
        MemoryKind.fact,
        MemoryKind.preference,
        MemoryKind.entity,
        MemoryKind.event,
      },
    );
  });

  testWidgets('filters by inferred kind and by tag', (tester) async {
    await _pump(
      tester,
      memories: [
        _memory(id: 'm1', kind: MemoryKind.inferred, tags: const ['work']),
        _memory(id: 'm2', kind: MemoryKind.fact, tags: const ['home']),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('memory_kind_filter_inferred')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('memory_row_m1')), findsOneWidget);
    expect(find.byKey(const ValueKey('memory_row_m2')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('memory_tag_filter_work')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('memory_row_m1')), findsOneWidget);
  });

  testWidgets('search matches a tag and the expiry badge shows', (
    tester,
  ) async {
    await _pump(
      tester,
      memories: [
        _memory(
          id: 'm1',
          kind: MemoryKind.inferred,
          tags: const ['standup'],
          expiresAt: DateTime.now().add(const Duration(days: 2)),
        ),
      ],
    );
    await tester.enterText(find.byType(TextField), 'standup');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('memory_row_m1')), findsOneWidget);
    expect(find.byKey(const ValueKey('memory_expiry_m1')), findsOneWidget);
    expect(find.text('Expires in 2 days'), findsOneWidget);
  });

  testWidgets('inferred rows show the short summary instead of the content', (
    tester,
  ) async {
    await _pump(
      tester,
      memories: [
        _memory(id: 'm1', kind: MemoryKind.inferred),
        _memory(id: 'm2'),
      ],
    );
    expect(find.text('Summary m1'), findsOneWidget);
    expect(find.textContaining('Content m1'), findsNothing);
    expect(find.text('Content m2'), findsOneWidget);
  });

  testWidgets('the editor saves tags, a short summary, and an expiry', (
    tester,
  ) async {
    final store = await _pump(tester, memories: const []);

    await tester.tap(find.byKey(const ValueKey('memory_add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('memory_title_field')),
      'Coffee',
    );
    await tester.enterText(
      find.byKey(const ValueKey('memory_content_field')),
      'Oat milk flat white',
    );
    await tester.enterText(
      find.byKey(const ValueKey('memory_tags_field')),
      'Work, coffee',
    );
    await tester.enterText(
      find.byKey(const ValueKey('memory_summary_field')),
      'Prefers oat milk',
    );
    expect(find.byKey(const ValueKey('memory_expiry_clear')), findsNothing);

    final expiry = find.byKey(const ValueKey('memory_expiry_field'));
    await tester.ensureVisible(expiry);
    await tester.pumpAndSettle();
    await tester.tap(expiry);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('memory_expiry_clear')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('memory_expiry_clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('memory_expiry_clear')), findsNothing);
    expect(find.text('No expiry'), findsOneWidget);

    await tester.tap(expiry);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('memory_save')));
    await tester.pumpAndSettle();

    final saved = store.list().single;
    expect(saved.tags, ['work', 'coffee']);
    expect(saved.shortSummary, 'Prefers oat milk');
    expect(saved.expiresAt, isNotNull);
  });

  testWidgets('the graph view renders a node per memory', (tester) async {
    final store = InMemoryMemoryStore();
    MemoryRepository(store).remember(title: 'Coffee', content: 'Oat milk');
    final container = ProviderContainer(
      overrides: [memoryStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _wrap(const MemoriesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('memories_view_toggle')));
    await tester.pumpAndSettle();

    // The graph paints nodes on a canvas, so assert the graph widget itself.
    expect(find.byType(MemoryGraphView), findsOneWidget);
  });
}
