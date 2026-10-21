// Private fields with public named parameters need explicit assignment.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../../settings/data/models/app_settings.dart';
import 'screen_memory_batch_processor.dart';
import 'screen_sampler.dart';

/// Owns the sampler and batch timers and starts or stops them from settings.
///
/// [applySettings] is idempotent: re-applying the running configuration keeps
/// the existing timers, while a disabled feature or a changed interval restarts
/// them. The app root drives it through `screenMemoryTickProvider`.
class ScreenMemoryScheduler {
  ScreenMemoryScheduler({
    required ScreenSampler sampler,
    required ScreenMemoryBatchProcessor batch,
  }) : _sampler = sampler,
       _batch = batch;

  final ScreenSampler _sampler;
  final ScreenMemoryBatchProcessor _batch;

  Timer? _sampleTimer;
  Timer? _batchTimer;
  Duration? _sampleInterval;
  Duration? _batchInterval;

  bool get isRunning => _sampleTimer != null && _batchTimer != null;

  void applySettings(AppSettings settings) {
    final sampleMs = settings.screenMemorySampleIntervalMs;
    final batchSeconds = settings.screenMemoryBatchIntervalSeconds;
    if (!settings.screenMemoryEnabled || sampleMs <= 0 || batchSeconds <= 0) {
      stop();
      return;
    }

    final sampleInterval = Duration(milliseconds: sampleMs);
    final batchInterval = Duration(seconds: batchSeconds);
    if (isRunning &&
        _sampleInterval == sampleInterval &&
        _batchInterval == batchInterval) {
      return;
    }

    stop();
    _sampleInterval = sampleInterval;
    _batchInterval = batchInterval;
    _sampleTimer = Timer.periodic(
      sampleInterval,
      (_) => unawaited(_sampler.tick()),
    );
    _batchTimer = Timer.periodic(
      batchInterval,
      (_) => unawaited(_batch.batchNow()),
    );
  }

  /// Drains the queue now: app open/resume and the overlay being shown.
  Future<void> batchNow() => _batch.batchNow();

  void stop() {
    _sampleTimer?.cancel();
    _batchTimer?.cancel();
    _sampleTimer = null;
    _batchTimer = null;
    _sampleInterval = null;
    _batchInterval = null;
  }

  void dispose() => stop();
}
