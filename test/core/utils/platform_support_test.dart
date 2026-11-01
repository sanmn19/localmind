import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/utils/platform_support.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('macOS is a desktop but not a mobile plugin platform', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(isMacDesktop, isTrue);
    expect(supportsMobileOnlyPlugins, isFalse);
    expect(supportsAndroidBackgroundService, isFalse);
    expect(supportsAudioBackground, isFalse);
    expect(supportsMicPermissionPlugin, isFalse);
    expect(supportsCalendarPlugin, isFalse);
  });

  test('Android keeps every plugin path enabled', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(isMacDesktop, isFalse);
    expect(supportsMobileOnlyPlugins, isTrue);
    expect(supportsAndroidBackgroundService, isTrue);
    expect(supportsAudioBackground, isTrue);
    expect(supportsMicPermissionPlugin, isTrue);
    expect(supportsCalendarPlugin, isTrue);
  });
}
