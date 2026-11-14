import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:localmind/core/logger/app_logger.dart';

import 'background_engine.dart'
    show BackgroundResultNotifier, BgNotificationPayload;

/// One notification per conversation: a newer reply replaces the older one, while
/// different chats keep separate notifications.
const chatReplyChannelId = 'localmind_chat_replies';

int chatReplyNotificationId(String conversationId) =>
    conversationId.hashCode & 0x7fffffff;

/// First readable line of the reply, collapsed and clipped for the notification.
String chatReplyPreview(String content, {int maxChars = 140}) {
  final collapsed = content
      .replaceAll(RegExp(r'```.*?```', dotAll: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (collapsed.length <= maxChars) return collapsed;
  return '${collapsed.substring(0, maxChars).trim()}…';
}

/// Posts the "reply ready" notification when a chat finishes while LocalMind is
/// not in the foreground. Taps reuse the background-task payload contract, so the
/// bootstrap handler opens the owning conversation.
class ChatCompletionNotifier {
  ChatCompletionNotifier({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse:
          BackgroundResultNotifier.onNotificationTap,
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        chatReplyChannelId,
        'Chat replies',
        description:
            'Notifies when a chat reply is ready while LocalMind is in the background.',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      ),
    );
  }

  Future<void> notify({
    required String conversationId,
    required String title,
    required String body,
  }) async {
    if (body.trim().isEmpty) return;
    try {
      await _ensureInitialized();
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (await android?.areNotificationsEnabled() == false) return;
      await _plugin.show(
        id: chatReplyNotificationId(conversationId),
        title: title,
        body: body,
        payload: BgNotificationPayload.compose(conversationId),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            chatReplyChannelId,
            'Chat replies',
            channelDescription:
                'Notifies when a chat reply is ready while LocalMind is in the background.',
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
          ),
        ),
      );
    } catch (error) {
      Log.warning('Chat reply notification failed: $error');
    }
  }
}
