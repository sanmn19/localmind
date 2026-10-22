// Private fields with public named parameters need explicit assignment.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../../../core/logger/app_logger.dart';
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

  Timer? _batchTimer;
  Duration? _sampleInterval;
  Duration? _batchInterval;
  bool _sampling = false;

  bool get isRunning => _batchTimer != null;

  void applySettings(AppSettings settings) {
    final sampleMs = settings.screenMemorySampleIntervalMs;
    final batchSeconds = settings.screenMemoryBatchIntervalSeconds;
    if (!settings.screenMemoryEnabled || sampleMs <= 0 || batchSeconds <= 0) {
      stop();
      unawaited(
        _sampler.stopSampling().catchError((Object error, StackTrace stack) {
          Log.warning('Screen sampling stop failed: $error');
        }),
      );
      // No more batches run while the feature is off, so drain expired samples
      // here instead of leaving captured text on disk indefinitely.
      unawaited(
        _batch.pruneSamples().catchError((Object error, StackTrace stack) {
          Log.warning('Screen sample prune failed: $error');
        }),
      );
      return;
    }

    final sampleInterval = Duration(milliseconds: sampleMs);
    final batchInterval = Duration(seconds: batchSeconds);

    // Native event-driven sampling: start or change the debounce. It survives
    // the app being backgrounded, unlike a Dart timer.
    if (!_sampling || _sampleInterval != sampleInterval) {
      _sampleInterval = sampleInterval;
      _sampling = true;
      unawaited(
        _sampler.startSampling(sampleMs).catchError((
          Object error,
          StackTrace stack,
        ) {
          Log.warning('Screen sampling start failed: $error');
        }),
      );
    }

    if (_batchTimer != null && _batchInterval == batchInterval) return;
    _batchTimer?.cancel();
    _batchInterval = batchInterval;
    _batchTimer = Timer.periodic(
      batchInterval,
      (_) => unawaited(
        _batch.batchNow().catchError((Object error, StackTrace stack) {
          Log.warning('Screen memory batch failed: $error');
        }),
      ),
    );
  }

  /// Drains native samples, then processes the queue: app open/resume and the
  /// overlay being shown.
  Future<void> batchNow() async {
    await _sampler.drain();
    await _batch.batchNow();
  }

  void stop() {
    _batchTimer?.cancel();
    _batchTimer = null;
    _sampleInterval = null;
    _batchInterval = null;
    _sampling = false;
  }

  void dispose() {
    stop();
    unawaited(
      _sampler.stopSampling().catchError((Object error, StackTrace stack) {
        Log.warning('Screen sampling stop failed: $error');
      }),
    );
  }
}
