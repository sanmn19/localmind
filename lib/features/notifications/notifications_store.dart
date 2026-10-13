import 'notifications_mcp_server.dart';

const notificationRingCapacity = 200;

List<NotificationItem> filterRecent(
  List<NotificationItem> items, {
  required DateTime now,
  int? max,
  int? sinceMinutes,
  String? package,
}) {
  final wantedPackage = package?.trim();
  final packageMatched = <NotificationItem>[
    for (final item in items)
      if (wantedPackage == null ||
          wantedPackage.isEmpty ||
          item.packageName == wantedPackage)
        item,
  ];
  final recencyFiltered = sinceMinutes != null && sinceMinutes > 0
      ? <NotificationItem>[
          for (final item in packageMatched)
            if (item.postedAt.isAfter(
              now.subtract(Duration(minutes: sinceMinutes)),
            ))
              item,
        ]
      : packageMatched;
  final cap = max;
  return recencyFiltered
      .take(cap == null || cap < 0 ? recencyFiltered.length : cap)
      .toList();
}
