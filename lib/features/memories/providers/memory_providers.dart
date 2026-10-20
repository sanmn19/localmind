import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/storage_providers.dart';
import '../data/memory_extraction_service.dart';
import '../data/memory_repository.dart';
import '../data/memory_store.dart';
import '../data/models/memory.dart';

final memoryStoreProvider = Provider<MemoryStore>((ref) {
  final db = ref.watch(databaseProvider);
  return ObjectBoxMemoryStore(
    memories: db.memoryBox,
    relations: db.memoryRelationBox,
    embeddings: db.memoryEmbeddingBox,
  );
});

final memoryRepositoryProvider = Provider<MemoryRepository>((ref) {
  return MemoryRepository(ref.watch(memoryStoreProvider));
});

final memoriesProvider = FutureProvider<List<Memory>>((ref) async {
  return ref.watch(memoryRepositoryProvider).list();
});

final memoryRelationsProvider = FutureProvider<List<MemoryRelation>>((ref) async {
  return ref.watch(memoryStoreProvider).listRelations();
});

final memoryExtractionServiceProvider = Provider<MemoryExtractionService>(
  (ref) => MemoryExtractionService(),
);

final memoriesNotifierProvider =
    NotifierProvider<MemoriesNotifier, int>(MemoriesNotifier.new);

class MemoriesNotifier extends Notifier<int> {
  @override
  int build() {
    // Repair rows duplicated by the pre-upsert import path (best-effort).
    try {
      ref.read(memoryStoreProvider).dedupeById();
    } catch (_) {}
    return 0;
  }

  Future<Memory> remember({
    required String title,
    required String content,
    MemoryKind kind = MemoryKind.fact,
    int importance = 50,
    String? scopeConversationId,
  }) async {
    final memory = ref
        .read(memoryRepositoryProvider)
        .remember(
          title: title,
          content: content,
          kind: kind,
          importance: importance,
          scopeConversationId: scopeConversationId,
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
