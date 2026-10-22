// Private fields with public named parameters need explicit assignment.
// ignore_for_file: prefer_initializing_formals

import '../../../core/logger/app_logger.dart';
import '../../settings/data/models/app_settings.dart';
import 'screen_privacy_filter.dart';
import 'screen_sample_store.dart';
import 'screen_text_gateway.dart';

/// Reads the foreground app's visible text every tick and queues only changed,
/// allowed screens. It never calls the model.
class ScreenSampler {
  ScreenSampler({
    required ScreenTextGateway gateway,
    required ScreenSampleStore store,
    required AppSettings Function() settings,
    DateTime Function()? now,
  }) : _gateway = gateway,
       _store = store,
       _settings = settings,
       _now = now ?? DateTime.now;

  /// Matches the Kotlin reader's cap so a fake gateway cannot bloat a row.
  static const _maxSampleChars = 8000;

  final ScreenTextGateway _gateway;
  final ScreenSampleStore _store;
  final AppSettings Function() _settings;
  final DateTime Function() _now;

  final Map<String, String> _lastHashes = {};
  bool _tickInFlight = false;
  bool _disposed = false;

  /// Starts native event-driven sampling. The native service owns the debounce
  /// and the screen-off pause; no Dart timer is needed.
  Future<void> startSampling(int intervalMs) =>
      _gateway.startSampling(intervalMs);

  Future<void> stopSampling() => _gateway.stopSampling();

  /// Samples waiting in the native ring, before the next drain.
  Future<int> pendingSampleCount() => _gateway.pendingSampleCount();

  /// Drains native changed-screen samples into the on-disk queue.
  Future<void> drain() async {
    if (_disposed || _tickInFlight) return;
    final settings = _settings();
    if (!settings.screenMemoryEnabled) return;

    _tickInFlight = true;
    try {
      final samples = await _gateway.drainSamples();
      for (final screen in samples) {
        if (_disposed || !screen.isInteractive) continue;
        if (isBlockedPackage(
          screen.packageName,
          settings.screenMemoryBlockedApps,
        )) {
          continue;
        }
        final text = _normalize(screen.text);
        if (text.isEmpty) continue;
        final hash = _hash(screen.packageName, text);
        if (_lastHashes[screen.packageName] == hash) continue;
        if (ScreenPrivacyFilter.containsSensitiveData(text)) {
          // Remember the hash so the same sensitive screen is not re-read every
          // batch; a changed screen is evaluated again.
          _lastHashes[screen.packageName] = hash;
          Log.info('Screen sample skipped: sensitive content');
          continue;
        }
        _store.add(
          ScreenSample(
            capturedAt: screen.capturedAt ?? _now(),
            packageName: screen.packageName,
            text: text,
            hash: hash,
          ),
        );
        _lastHashes[screen.packageName] = hash;
      }
    } catch (error) {
      // A channel or store hiccup must not kill the sampler; the next batch
      // retries, and an unchanged screen is still deduped by hash.
      Log.warning('Screen sampling failed: $error');
    } finally {
      _tickInFlight = false;
    }
  }

  /// Backwards-compatible single drain (tests and callers that pump once).
  Future<void> tick() => drain();

  void dispose() {
    _disposed = true;
  }

  /// An exact package or a blocked package's subpackage.
  static bool isBlockedPackage(String packageName, Iterable<String> blocked) {
    for (final app in blocked) {
      final value = app.trim();
      if (value.isEmpty) continue;
      if (packageName == value || packageName.startsWith('$value.')) {
        return true;
      }
    }
    return false;
  }

  /// Collapses whitespace so layout changes do not create new samples.
  static String _normalize(String text) {
    final normalized = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return normalized.length > _maxSampleChars
        ? normalized.substring(0, _maxSampleChars)
        : normalized;
  }

  /// Stable FNV-1a hash of package + normalized text, used for the
  /// unchanged-screen check and as the queue's index.
  static String _hash(String packageName, String text) {
    var hash = 0x811c9dc5;
    for (final unit in '$packageName\u0000$text'.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
