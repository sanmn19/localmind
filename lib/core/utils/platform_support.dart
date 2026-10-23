import 'package:flutter/foundation.dart';

/// Platform capability switches for this mobile-first app.
///
/// Feature code asks these getters instead of `Platform.isAndroid`/`isMacOS` so
/// tests can drive every branch through `debugDefaultTargetPlatformOverride`,
/// and so web never enables a plugin whose platform channel is absent.

bool get _isAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// The macOS desktop build. The only Apple desktop target.
bool get isMacDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// The Apple platforms that share TCC permission prompts.
bool get isAppleDesktop => isMacDesktop || _isIOS;

/// Plugins that only ship Android and iOS implementations.
bool get supportsMobileOnlyPlugins => _isAndroid || _isIOS;

/// The Android foreground-service keep-alive.
bool get supportsAndroidBackgroundService => _isAndroid;

/// `just_audio_background`'s media-session notification.
bool get supportsAudioBackground => supportsMobileOnlyPlugins;

/// `haptic_feedback`'s vibration engine.
bool get supportsHaptics => supportsMobileOnlyPlugins;

/// `permission_handler`'s microphone permission.
bool get supportsMicPermissionPlugin => supportsMobileOnlyPlugins;

/// `device_calendar_plus`'s device calendar access.
bool get supportsCalendarPlugin => supportsMobileOnlyPlugins;
