import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haptic_feedback/haptic_feedback.dart';

import '../providers/app_providers.dart';
import '../utils/platform_support.dart';

typedef HapticVibrate = Future<void> Function(HapticsType type);

/// The single setting-aware entry point for application haptic feedback.
class AppHaptics {
  AppHaptics(this._isEnabled, {HapticVibrate? vibrate})
    : _vibrate = vibrate ?? _platformVibrate;

  /// Default engine: the plugin only ships Android/iOS implementations, so
  /// desktop builds stay a silent no-op instead of raising a missing channel.
  static Future<void> _platformVibrate(HapticsType type) async {
    if (!supportsHaptics) return;
    await Haptics.vibrate(type);
  }

  final bool Function() _isEnabled;
  final HapticVibrate _vibrate;

  Future<void> vibrate(HapticsType type) async {
    if (!_isEnabled()) return;
    try {
      await _vibrate(type);
    } catch (_) {
      // Haptics are best-effort on unsupported devices and simulators.
    }
  }

  Future<void> light() => vibrate(HapticsType.light);
  Future<void> medium() => vibrate(HapticsType.medium);
  Future<void> selection() => vibrate(HapticsType.selection);
}

final appHapticsProvider = Provider<AppHaptics>((ref) {
  return AppHaptics(() => ref.read(settingsProvider).hapticFeedbackEnabled);
});
