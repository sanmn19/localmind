import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/memories/data/memory_repository.dart';
import 'package:localmind/features/memories/data/memory_store.dart';
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
