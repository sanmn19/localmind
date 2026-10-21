import 'package:flutter/services.dart';

/// One on-demand read of the foreground app's visible text. [isInteractive]
/// is false while the device screen is off or locked.
class ScreenText {
  const ScreenText({
    required this.packageName,
    required this.text,
    required this.isInteractive,
  });

  final String packageName;
  final String text;
  final bool isInteractive;
}

/// Foreground-screen text seam: the Android accessibility reader behind it,
/// the no-op everywhere else (host tests, other platforms, service off).
abstract class ScreenTextGateway {
  Future<ScreenText?> readText();
}

class NoopScreenTextGateway implements ScreenTextGateway {
  const NoopScreenTextGateway();

  @override
  Future<ScreenText?> readText() async => null;
}

/// `localmind/screen` `readText`: the native side walks the active windows
/// and answers with a payload map, or null while the screen is off/locked or
/// the accessibility service is not connected.
class MethodChannelScreenTextGateway implements ScreenTextGateway {
  MethodChannelScreenTextGateway({
    MethodChannel? channel,
    this.timeout = const Duration(seconds: 3),
  }) : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'localmind/screen';

  final MethodChannel _channel;
  final Duration timeout;

  @override
  Future<ScreenText?> readText() async {
    try {
      final payload = await _channel
          .invokeMethod<Map<Object?, Object?>>('readText')
          .timeout(timeout);
      if (payload == null) return null;
      final packageName = payload['packageName'];
      final text = payload['text'];
      if (packageName is! String || text is! String) return null;
      return ScreenText(
        packageName: packageName,
        text: text,
        isInteractive: payload['isInteractive'] == true,
      );
    } on Exception {
      // MissingPluginException on host tests, platform errors, and a stalled
      // channel all read as "no screen text" so the sampler just skips a tick.
      return null;
    }
  }
}
