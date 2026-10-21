import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/providers/storage_providers.dart';
import '../../chat/providers/chat_params_providers.dart';
import '../../chat/providers/chat_service_providers.dart';
import '../../chat/providers/model_selection_providers.dart';
import '../../servers/providers/server_providers.dart';
import '../data/memory_extraction_service.dart';
import '../data/memory_repository.dart';
import '../data/memory_store.dart';
import '../data/models/memory.dart';
import '../data/screen_memory_batch_processor.dart';
import '../data/screen_sample_store.dart';
import '../data/screen_sampler.dart';
import '../data/screen_text_gateway.dart';

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

/// The Android accessibility reader; a no-op on hosts and other platforms.
final screenTextGatewayProvider = Provider<ScreenTextGateway>((ref) {
  return Platform.isAndroid
      ? MethodChannelScreenTextGateway()
      : const NoopScreenTextGateway();
});

final screenSampleStoreProvider = Provider<ScreenSampleStore>((ref) {
  return ObjectBoxScreenSampleStore(
    ref.watch(databaseProvider).screenSampleBox,
  );
});

final screenSamplerProvider = Provider<ScreenSampler>((ref) {
  final sampler = ScreenSampler(
    gateway: ref.watch(screenTextGatewayProvider),
    store: ref.watch(screenSampleStoreProvider),
    settings: () => ref.read(settingsProvider),
  );
  ref.onDispose(sampler.dispose);
  return sampler;
});

final screenBatchProcessorProvider = Provider<ScreenMemoryBatchProcessor>((
  ref,
) {
  return ScreenMemoryBatchProcessor(
    store: ref.watch(screenSampleStoreProvider),
    extractor: ref.watch(memoryExtractionServiceProvider),
    repository: ref.watch(memoryRepositoryProvider),
    chatService: () {
      final service = ref.read(chatServiceProvider);
      if (service == null) {
        throw StateError('no active chat service');
      }
      return service;
    },
    server: () => ref.read(activeServerProvider),
    modelId: () => ref.read(activeChatTargetProvider).effectiveModelId ?? '',
    params: () => ref.read(chatParamsProvider),
    settings: () => ref.read(settingsProvider),
  );
});

/// Starts the sampler and batch timers while screen memories are on, and stops
/// them when the feature is switched off. Watched once by the app root.
final screenMemoryTickProvider = Provider<void>((ref) {
  final enabled = ref.watch(
    settingsProvider.select((settings) => settings.screenMemoryEnabled),
  );
  if (!enabled) return;

  final sampleMs = ref.watch(
    settingsProvider.select(
      (settings) => settings.screenMemorySampleIntervalMs,
    ),
  );
  final batchSeconds = ref.watch(
    settingsProvider.select(
      (settings) => settings.screenMemoryBatchIntervalSeconds,
    ),
  );
  if (sampleMs <= 0 || batchSeconds <= 0) return;

  final sampler = ref.watch(screenSamplerProvider);
  final batch = ref.watch(screenBatchProcessorProvider);
  final sampleTimer = Timer.periodic(
    Duration(milliseconds: sampleMs),
    (_) => unawaited(sampler.tick()),
  );
  final batchTimer = Timer.periodic(
    Duration(seconds: batchSeconds),
    (_) => unawaited(batch.batchNow()),
  );
  ref.onDispose(() {
    sampleTimer.cancel();
    batchTimer.cancel();
  });
});

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
    List<String> tags = const [],
    String shortSummary = '',
    DateTime? expiresAt,
    String? sourceApp,
  }) async {
    if (kind == MemoryKind.inferred) {
      throw ArgumentError.value(
        kind,
        'kind',
        'inferred memories are written by the screen extractor',
      );
    }
    final memory = ref
        .read(memoryRepositoryProvider)
        .remember(
          title: title,
          content: content,
          kind: kind,
          importance: importance,
          scopeConversationId: scopeConversationId,
          tags: tags,
          shortSummary: shortSummary,
          expiresAt: expiresAt,
          sourceApp: sourceApp,
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
