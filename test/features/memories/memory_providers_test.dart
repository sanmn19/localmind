import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/memories/data/memory_store.dart';
import 'package:localmind/features/memories/data/models/memory.dart';
import 'package:localmind/features/memories/providers/memory_providers.dart';

void main() {
  late InMemoryMemoryStore store;
  late ProviderContainer container;

  setUp(() {
    store = InMemoryMemoryStore();
    container = ProviderContainer(
      overrides: [memoryStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
  });

  test('remember rejects the inferred kind', () async {
    await expectLater(
      container
          .read(memoriesNotifierProvider.notifier)
          .remember(
            title: 'Standup',
            content: 'Standup at 10:00.',
            kind: MemoryKind.inferred,
          ),
      throwsArgumentError,
    );
    expect(store.list(), isEmpty);
  });

  test(
    'remember passes tags, summary, expiry and source app through',
    () async {
      final memory = await container
          .read(memoriesNotifierProvider.notifier)
          .remember(
            title: 'Standup',
            content: 'Standup at 10:00.',
            tags: const ['Work', 'work'],
            shortSummary: 'Standup at 10:00',
            expiresAt: DateTime(2026, 10, 21, 23, 59, 59, 999),
            sourceApp: 'com.whatsapp',
          );

      expect(memory.tags, ['work']);
      expect(memory.shortSummary, 'Standup at 10:00');
      expect(memory.expiresAt, DateTime(2026, 10, 21, 23, 59, 59, 999));
      expect(memory.sourceApp, 'com.whatsapp');
    },
  );
}
