import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat/providers/chat_params_providers.dart';
import '../../features/chat/providers/chat_service_providers.dart';
import '../../features/chat/providers/model_selection_providers.dart';
import '../../features/memories/data/screen_memory_batch_processor.dart';
import '../../features/memories/data/screen_memory_scheduler.dart';
import '../../features/memories/providers/memory_providers.dart';
import '../../features/servers/providers/server_providers.dart';
import 'app_providers.dart';

/// The screen-memory batch processor: one hidden extraction call per batch.
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

/// The sampler/batch timer owner, driven from settings.
final screenMemorySchedulerProvider = Provider<ScreenMemoryScheduler>((ref) {
  final scheduler = ScreenMemoryScheduler(
    sampler: ref.watch(screenSamplerProvider),
    batch: ref.watch(screenBatchProcessorProvider),
  );
  ref.onDispose(scheduler.dispose);
  return scheduler;
});

/// Starts the sampler and batch timers while screen memories are on, and stops
/// them when the feature is switched off. Watched once by the app root.
final screenMemoryTickProvider = Provider<void>((ref) {
  ref.watch(
    settingsProvider.select((settings) => settings.screenMemoryEnabled),
  );
  ref.watch(
    settingsProvider.select(
      (settings) => settings.screenMemorySampleIntervalMs,
    ),
  );
  ref.watch(
    settingsProvider.select(
      (settings) => settings.screenMemoryBatchIntervalSeconds,
    ),
  );
  // applySettings also prunes the sample queue while the feature is off, so a
  // previous build's captured text cannot outlive the 24-hour window.
  final scheduler = ref.watch(screenMemorySchedulerProvider);
  scheduler.applySettings(ref.read(settingsProvider));
  ref.onDispose(scheduler.stop);
});
