// Private fields with public named parameters need explicit assignment.
// ignore_for_file: prefer_initializing_formals

import '../../../core/logger/app_logger.dart';
import '../../chat/data/chat_service.dart';
import '../../chat/data/models/chat_parameters.dart';
import '../../servers/data/models/server.dart';
import '../../settings/data/models/app_settings.dart';
import 'memory_extraction_service.dart';
import 'memory_repository.dart';
import 'screen_sample_store.dart';

/// Drains the screen-sample queue into at most one extraction call per batch.
///
/// Runs every 60 s, on app open/resume, and when the floating window is shown
/// (the wiring calls [batchNow]). Guards: 6 batches per hour, a 5-minute backoff
/// after a failure, and a 4000-character merged-text cap.
class ScreenMemoryBatchProcessor {
  ScreenMemoryBatchProcessor({
    required ScreenSampleStore store,
    required MemoryExtractionService extractor,
    required MemoryRepository repository,
    required ChatService Function() chatService,
    required Server? Function() server,
    required String Function() modelId,
    required ChatParameters Function() params,
    required AppSettings Function() settings,
    DateTime Function()? now,
    void Function(String)? onFailure,
  }) : _store = store,
       _extractor = extractor,
       _repository = repository,
       _chatService = chatService,
       _server = server,
       _modelId = modelId,
       _params = params,
       _settings = settings,
       _now = now ?? DateTime.now,
       _onFailure = onFailure;

  static const _maxBatchesPerHour = 6;
  static const _maxMergedChars = 4000;
  static const _sampleRetention = Duration(hours: 24);
  static const _failureBackoff = Duration(minutes: 5);
  static const _keepMaxSamples = 4000;

  final ScreenSampleStore _store;
  final MemoryExtractionService _extractor;
  final MemoryRepository _repository;
  final ChatService Function() _chatService;
  final Server? Function() _server;
  final String Function() _modelId;
  final ChatParameters Function() _params;
  final AppSettings Function() _settings;
  final DateTime Function() _now;
  final void Function(String)? _onFailure;

  final List<DateTime> _batchTimes = [];
  DateTime? _backoffUntil;
  bool _running = false;

  bool get isRunning => _running;

  Future<void> batchNow() async {
    if (_running) return;
    final now = _now();
    try {
      _store.prune(
        before: now.subtract(_sampleRetention),
        keepMax: _keepMaxSamples,
      );
    } catch (error) {
      // Pruning is best-effort; a store hiccup must not stop the batch.
      Log.warning('Screen sample prune failed: $error');
    }
    if (!_settings().screenMemoryEnabled) return;

    final backoffUntil = _backoffUntil;
    if (backoffUntil != null && now.isBefore(backoffUntil)) return;

    _batchTimes.removeWhere(
      (time) => now.difference(time) >= const Duration(hours: 1),
    );
    if (_batchTimes.length >= _maxBatchesPerHour) return;

    final samples = _store.pending();
    if (samples.isEmpty) return;

    final server = _server();
    final modelId = _modelId();
    if (server == null || modelId.isEmpty) return;

    final merged = _merge(samples);
    if (merged.text.isEmpty) return;

    final ChatService chatService;
    try {
      chatService = _chatService();
    } catch (error) {
      _fail(now, error);
      return;
    }

    _store.markProcessed(samples.map((sample) => sample.id), now);
    _batchTimes.add(now);
    _running = true;
    try {
      final extracted = await _extractor.extractScreen(
        chatService: chatService,
        server: server,
        modelId: modelId,
        params: _params(),
        screenText: merged.text,
        sourceApp: merged.sourceApp,
        existingTitles: _repository
            .list()
            .map((memory) => memory.title)
            .toList(),
        now: now,
      );
      for (final item in extracted) {
        // One malformed item must not abort the rest of the batch.
        if (item.content.trim().isEmpty) continue;
        _repository.rememberInferred(
          title: item.title,
          content: item.content,
          tags: item.tags,
          shortSummary: item.shortSummary,
          // Null is permanent: never invent a default expiry.
          expiresAt: item.expiresAt,
          sourceApp: merged.sourceApp,
          importance: item.importance,
        );
      }
    } catch (error) {
      _fail(now, error);
    } finally {
      _running = false;
    }
  }

  void _fail(DateTime now, Object error) {
    _backoffUntil = now.add(_failureBackoff);
    Log.warning('Screen memory batch failed: $error');
    _onFailure?.call(error.toString());
  }

  /// Latest text per package, joined in first-seen package order and capped.
  ({String text, String sourceApp}) _merge(List<ScreenSample> samples) {
    final latest = <String, ScreenSample>{};
    for (final sample in samples) {
      final current = latest[sample.packageName];
      if (current == null || sample.capturedAt.isAfter(current.capturedAt)) {
        latest[sample.packageName] = sample;
      }
    }
    final buffer = StringBuffer();
    for (final entry in latest.entries) {
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer
        ..writeln('[${entry.key}]')
        ..write(entry.value.text);
    }
    final text = buffer.toString();
    return (
      text: text.length > _maxMergedChars
          ? text.substring(0, _maxMergedChars)
          : text,
      sourceApp: latest.keys.join(', '),
    );
  }
}
