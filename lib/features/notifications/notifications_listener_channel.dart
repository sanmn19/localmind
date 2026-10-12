import 'package:flutter/services.dart';

import 'notifications_mcp_server.dart';
import 'notifications_store.dart';

/// MethodChannel wrapper for `localmind/notifications`: the grant read,
/// the settings deep-link and the ring fetch. A missing platform plugin
/// (host tests, unsupported platforms) reads as disabled/empty instead of
/// throwing so callers never special-case the test hosts.
class NotificationListenerChannel {
  const NotificationListenerChannel();

  static const MethodChannel _channel = MethodChannel(
    'localmind/notifications',
  );

  /// True when Android connected LocalMind's NotificationListenerService,
  /// i.e. Notification access is granted AND the listener is attached.
  Future<bool> isListenerEnabled() async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('isListenerEnabled').timeout(
                _channelTimeout,
              );
      return granted ?? false;
    } on Exception {
      // MissingPluginException under host tests; any unexpected platform
      // channel failure reads the same as "not granted".
      return false;
    }
  }

  /// Deep-links to the system Notification access screen (Kotlin-side
  /// ACTION_NOTIFICATION_LISTENER_SETTINGS intent; the activity runs it).
  Future<void> requestGrantOpenSettings() async {
    try {
      await _channel.invokeMethod<void>(
        'openNotificationAccessSettings',
      ).timeout(_channelTimeout);
    } on Exception {
      // Host tests / other platforms have no settings screen to open.
    }
  }

  /// Ring rows already filtered DART-side: [package] exact match after
  /// trim, rows posted within [sinceMinutes] (when given), capped to [max]
  /// after filtering. The Kotlin side always returns the full ring.
  Future<List<NotificationItem>> fetchRecent({
    int? max,
    int? sinceMinutes,
    String? package,
  }) async {
    final items = await _rawRing();
    return filterRecent(
      items,
      now: DateTime.now(),
      max: max,
      sinceMinutes: sinceMinutes,
      package: package,
    );
  }

  /// Rows captured this session (newest first), unfiltered.
  Future<int> ringSize() async {
    try {
      return await _channel.invokeMethod<int>('ringSize').timeout(
            _channelTimeout,
          ) ??
          0;
    } on Exception {
      return 0;
    }
  }

  Future<List<NotificationItem>> _rawRing() async {
    try {
      final raw = await _channel
          .invokeMethod<List<dynamic>>('fetchRecent')
          .timeout(_channelTimeout);
      return [
        for (final row in raw ?? const [])
          if (row is Map) NotificationItem.fromMap(row),
      ];
    } on Exception {
      return const [];
    }
  }

  /// Widget-test hosts leave unmocked platform-channel futures pending
  /// forever; every read is bounded so callers always resolve (offline /
  /// forbearing device behavior matches the disabled read).
  static const _channelTimeout = Duration(seconds: 3);
}
