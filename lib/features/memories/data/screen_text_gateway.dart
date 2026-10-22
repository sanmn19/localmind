import 'package:flutter/services.dart';

/// One on-demand read of the foreground app's visible text. [isInteractive]
/// is false while the device screen is off or locked.
class ScreenText {
  const ScreenText({
    required this.packageName,
    required this.text,
    required this.isInteractive,
    this.capturedAt,
    this.windowId = 0,
  });

  final String packageName;
  final String text;
  final bool isInteractive;
  final DateTime? capturedAt;
  final int windowId;
}

/// Foreground-screen text seam: the Android accessibility reader behind it,
/// the no-op everywhere else (host tests, other platforms, service off).
abstract class ScreenTextGateway {
  Future<ScreenText?> readText();

  /// Starts native event-driven sampling with a debounce in milliseconds.
  Future<void> startSampling(int intervalMs);

  /// Stops native sampling and drops queued samples.
  Future<void> stopSampling();

  /// Drains changed-screen samples captured natively.
  Future<List<ScreenText>> drainSamples();

  /// Samples currently waiting in the native ring.
  Future<int> pendingSampleCount();
}

class NoopScreenTextGateway implements ScreenTextGateway {
  const NoopScreenTextGateway();

  @override
  Future<ScreenText?> readText() async => null;

  @override
  Future<void> startSampling(int intervalMs) async {}

  @override
  Future<void> stopSampling() async {}

  @override
  Future<List<ScreenText>> drainSamples() async => const [];

  @override
  Future<int> pendingSampleCount() async => 0;
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
        windowId: (payload['windowId'] as num?)?.toInt() ?? 0,
      );
    } on Exception {
      // MissingPluginException on host tests, platform errors, and a stalled
      // channel all read as "no screen text" so the sampler just skips a tick.
      return null;
    }
  }

  @override
  Future<void> startSampling(int intervalMs) async {
    try {
      await _channel
          .invokeMethod<void>('startSampling', {'intervalMs': intervalMs})
          .timeout(timeout);
    } on Exception {
      // Service off / host tests: sampling simply does not start.
    }
  }

  @override
  Future<void> stopSampling() async {
    try {
      await _channel.invokeMethod<void>('stopSampling').timeout(timeout);
    } on Exception {
      // Best effort.
    }
  }

  @override
  Future<List<ScreenText>> drainSamples() async {
    try {
      final raw = await _channel
          .invokeMethod<List<dynamic>>('drainSamples')
          .timeout(timeout);
      return [
        for (final row in raw ?? const [])
          if (row is Map)
            ScreenText(
              packageName: row['packageName'] as String? ?? '',
              text: row['text'] as String? ?? '',
              isInteractive: true,
              capturedAt: DateTime.fromMillisecondsSinceEpoch(
                (row['capturedAtMillis'] as num?)?.toInt() ?? 0,
              ),
            ),
      ];
    } on Exception {
      return const [];
    }
  }

  @override
  Future<int> pendingSampleCount() async {
    try {
      return await _channel.invokeMethod<int>('pendingSampleCount').timeout(
            timeout,
          ) ??
          0;
    } on Exception {
      return 0;
    }
  }
}
