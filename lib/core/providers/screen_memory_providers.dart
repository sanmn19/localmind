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

/// Live queue/processing status for the Memories screen.
class ScreenMemoryStatus {
  const ScreenMemoryStatus({
    required this.pending,
    required this.running,
    required this.lastBatchAt,
    required this.lastExtracted,
    required this.lastError,
    required this.blockedReason,
  });

  final int pending;
  final bool running;
  final DateTime? lastBatchAt;
  final int lastExtracted;
  final String? lastError;
  final String? blockedReason;
}

/// Polls the native ring and the ObjectBox queue only while the Memories screen
/// is mounted. Auto-dispose keeps it from waking the app in the background.
final screenMemoryStatusProvider =
    StreamProvider.autoDispose<ScreenMemoryStatus>((ref) async* {
  final batch = ref.watch(screenBatchProcessorProvider);
  final sampler = ref.watch(screenSamplerProvider);
  final settings = ref.watch(settingsProvider);
  final server = ref.watch(activeServerProvider);
  final modelId = ref.watch(activeChatTargetProvider).effectiveModelId ?? '';
  var disposed = false;
  ref.onDispose(() => disposed = true);
  while (!disposed) {
    final nativePending = await sampler.pendingSampleCount();
    String? reason;
    if (!settings.screenMemoryEnabled) {
      reason = 'off';
    } else if (server == null || modelId.isEmpty) {
      reason = 'no_model';
    } else if (batch.isBackingOff) {
      reason = 'backoff';
    } else if (batch.isAtHourlyCap) {
      reason = 'cap';
    }
    yield ScreenMemoryStatus(
      pending: batch.pendingCount + nativePending,
      running: batch.isRunning,
      lastBatchAt: batch.lastBatchAt,
      lastExtracted: batch.lastExtracted,
      lastError: batch.lastError,
      blockedReason: reason,
    );
    await Future<void>.delayed(const Duration(seconds: 2));
  }
});
