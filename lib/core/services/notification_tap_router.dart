import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// One plugin callback for every LocalMind notification producer.
///
/// flutter_local_notifications keeps a single response callback per app; the last
/// `initialize` call wins. Separate notifiers used to install their own callbacks,
/// so a tool-approval action could be delivered to the chat-completion handler and
/// silently ignored. Every notifier now initializes with [handle], which dispatches
/// by payload prefix.
class NotificationTapRouter {
  const NotificationTapRouter._();

  static DidReceiveNotificationResponseCallback? onBackgroundTap;
  static DidReceiveNotificationResponseCallback? onToolApprovalTap;

  static void handle(NotificationResponse response) {
    final payload = response.payload ?? '';
    if (payload.startsWith('tool-approval|')) {
      onToolApprovalTap?.call(response);
      return;
    }
    onBackgroundTap?.call(response);
  }
}
