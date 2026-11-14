import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:localmind/core/logger/app_logger.dart';

const toolApprovalChannelId = 'localmind_tool_approvals';

/// Notification tap/action payload. The approval id identifies the pending
/// completer; the conversation id lets a tap open the right chat.
final class ToolApprovalPayload {
  const ToolApprovalPayload._();

  static const prefix = 'tool-approval|';

  static String compose(String approvalId, String conversationId) =>
      '$prefix$approvalId|$conversationId';

  static ({String approvalId, String conversationId})? tryParse(
    String? payload,
  ) {
    if (payload == null || !payload.startsWith(prefix)) return null;
    final rest = payload.substring(prefix.length);
    final split = rest.indexOf('|');
    if (split <= 0 || split == rest.length - 1) return null;
    return (
      approvalId: rest.substring(0, split),
      conversationId: rest.substring(split + 1),
    );
  }
}

class ToolApprovalNotifier {
  ToolApprovalNotifier({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static DidReceiveNotificationResponseCallback? onAction;

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: onAction,
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        toolApprovalChannelId,
        'Tool approvals',
        description: 'Asks whether a tool call may run while you are away.',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      ),
    );
  }

  Future<void> show({
    required String approvalId,
    required String conversationId,
    required String conversationTitle,
    required String toolName,
    required Map<String, dynamic> arguments,
  }) async {
    try {
      await _ensureInitialized();
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (await android?.areNotificationsEnabled() == false) return;
      final preview = arguments.toString();
      await _plugin.show(
        id: approvalId.hashCode & 0x7fffffff,
        title: 'Approval needed · $conversationTitle',
        body:
            'Tool call: $toolName\n${preview.length > 120 ? '${preview.substring(0, 120)}…' : preview}',
        payload: ToolApprovalPayload.compose(approvalId, conversationId),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            toolApprovalChannelId,
            'Tool approvals',
            channelDescription:
                'Asks whether a tool call may run while you are away.',
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            actions: [
              AndroidNotificationAction('deny', 'Deny'),
              AndroidNotificationAction('approve', 'Approve'),
              AndroidNotificationAction(
                'always',
                'Always…',
                showsUserInterface: true,
              ),
            ],
          ),
        ),
      );
    } catch (error) {
      Log.warning('Tool approval notification failed: $error');
    }
  }

  Future<void> cancel(String approvalId) async {
    try {
      await _plugin.cancel(id: approvalId.hashCode & 0x7fffffff);
    } catch (_) {
      // Best effort.
    }
  }
}
