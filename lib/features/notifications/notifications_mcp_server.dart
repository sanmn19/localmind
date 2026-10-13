/// Model-facing contract for the in-process `local://notifications` MCP
/// server (`notifications.read_recent`).
const notificationsMcpServerLabel = 'Notifications';
const notificationsMcpServerUrl = 'local://notifications';
const notificationsReadRecentTool = 'notifications.read_recent';
const notificationsReadRecentMaxDefault = 20;
const notificationsReadRecentMaxCap = 50;

const notificationsReadEmptyMessage =
    'no recent notifications captured this session (reader starts fresh '
    'with the app session; grant Notification access in the card if it '
    'is off)';

class NotificationItem {
  const NotificationItem({
    required this.packageName,
    required this.title,
    required this.text,
    required this.postedAt,
  });

  factory NotificationItem.fromMap(Map<dynamic, dynamic> map) {
    return NotificationItem(
      // The channel layer carries these as strings, this is the decode site;
      // keep every field a String so rendering never has to re-escape.
      packageName: (map['packageName'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      text: (map['text'] ?? '').toString(),
      postedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['postedAtMillis'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  final String packageName;
  final String title;
  final String text;
  final DateTime postedAt;
}

typedef NotificationsRecent =
    Future<List<NotificationItem>> Function({
      int? max,
      int? sinceMinutes,
      String? package,
    });

class NotificationsServices {
  const NotificationsServices({required this.recent});

  final NotificationsRecent recent;
}

/// `pkg · HH:MM · title: text` rows, newest first (the ring's natural
/// order). A blank title collapses to the bare text.
String notificationsReadRender(List<NotificationItem> items) {
  if (items.isEmpty) return notificationsReadEmptyMessage;
  final rows = <String>[];
  for (final (index, item) in items.indexed) {
    final content = item.title.trim().isEmpty
        ? item.text
        : '${item.title}: ${item.text}';
    rows.add(
      '${index + 1}. ${item.packageName} · '
      '${_two(item.postedAt.hour)}:${_two(item.postedAt.minute)} · '
      '$content',
    );
  }
  return rows.join('\n');
}

String _two(int value) => value.toString().padLeft(2, '0');
