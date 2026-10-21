// Private fields with public named parameters need explicit assignment.
// ignore_for_file: prefer_initializing_formals

import '../../../core/logger/app_logger.dart';
import '../../settings/data/models/app_settings.dart';
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

  String? _lastHash;
  bool _tickInFlight = false;
  bool _disposed = false;

  Future<void> tick() async {
    if (_disposed || _tickInFlight) return;
    final settings = _settings();
    if (!settings.screenMemoryEnabled) return;

    _tickInFlight = true;
    try {
      final screen = await _gateway.readText();
      if (_disposed || screen == null || !screen.isInteractive) return;
      if (_isBlocked(screen.packageName, settings.screenMemoryBlockedApps)) {
        return;
      }
      final text = _normalize(screen.text);
      if (text.isEmpty) return;
      final hash = _hash(screen.packageName, text);
      if (hash == _lastHash) return;
      _store.add(
        ScreenSample(
          capturedAt: _now(),
          packageName: screen.packageName,
          text: text,
          hash: hash,
        ),
      );
      _lastHash = hash;
    } catch (error) {
      // A channel or store hiccup must not kill the 500 ms timer; the next
      // tick retries, and an unchanged screen is still deduped by hash.
      Log.warning('Screen sampling failed: $error');
    } finally {
      _tickInFlight = false;
    }
  }

  void dispose() {
    _disposed = true;
  }

  /// An exact package or a blocked package's subpackage.
  static bool _isBlocked(String packageName, Iterable<String> blocked) {
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
