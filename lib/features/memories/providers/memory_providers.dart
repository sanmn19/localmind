import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/storage_providers.dart';
import '../data/memory_repository.dart';
import '../data/memory_store.dart';
import '../data/models/memory.dart';

final memoryStoreProvider = Provider<MemoryStore>((ref) {
  final db = ref.watch(databaseProvider);
  return ObjectBoxMemoryStore(
    memories: db.memoryBox,
    relations: db.memoryRelationBox,
  );
});

final memoryRepositoryProvider = Provider<MemoryRepository>((ref) {
  return MemoryRepository(ref.watch(memoryStoreProvider));
});

final memoriesProvider = FutureProvider<List<Memory>>((ref) async {
  return ref.watch(memoryRepositoryProvider).list();
});

final memoriesNotifierProvider =
    NotifierProvider<MemoriesNotifier, int>(MemoriesNotifier.new);

class MemoriesNotifier extends Notifier<int> {
  @override
  int build() => 0;

  Future<Memory> remember({
    required String title,
    required String content,
    MemoryKind kind = MemoryKind.fact,
    int importance = 50,
  }) async {
    final memory = ref
        .read(memoryRepositoryProvider)
        .remember(
          title: title,
          content: content,
          kind: kind,
          importance: importance,
        );
    ref.invalidate(memoriesProvider);
    state++;
    return memory;
  }

  Future<void> forget(String memoryId) async {
    ref.read(memoryRepositoryProvider).forget(memoryId);
    ref.invalidate(memoriesProvider);
    state++;
  }

  Future<void> archive(String memoryId) async {
    ref.read(memoryRepositoryProvider).archive(memoryId);
    ref.invalidate(memoriesProvider);
    state++;
  }
}
