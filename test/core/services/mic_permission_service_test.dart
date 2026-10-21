import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/services/mic_permission_service.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('macOS treats the mic as granted without the plugin', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    const client = MicPermissionClientImpl();

    expect(await client.isGranted(), isTrue);
    expect(await client.request(), isTrue);
  });
}
