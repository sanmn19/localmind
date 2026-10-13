import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/notifications/notifications_mcp_server.dart';
import 'package:localmind/features/notifications/notifications_store.dart';

// Unit surface of the notifications reader: NotificationItem decode from
// the channel rows, the pure filterRecent ring filter and the
// notifications.read_recent render contract.

NotificationItem _item(
  int epochMillis, {
  String packageName = 'com.example.mail',
  String title = 'Title',
  String text = 'Body',
}) {
  return NotificationItem(
    packageName: packageName,
    title: title,
    text: text,
    postedAt: DateTime.fromMillisecondsSinceEpoch(epochMillis),
  );
}

void main() {
  final now = DateTime(2026, 10, 9, 12, 30);

  group('filterRecent', () {
    test('keeps the newest-first input order and all rows without filters',
        () {
      final items = [
        _item(now.millisecondsSinceEpoch),
        _item(now.millisecondsSinceEpoch - 1000),
        _item(now.millisecondsSinceEpoch - 2000),
      ];
      final filtered = filterRecent(items, now: now, max: 50);
      expect(filtered, hasLength(3));
      expect(filtered.first.postedAt, items.first.postedAt);
      expect(filtered.last.postedAt, items.last.postedAt);
    });

    test('max truncates to the newest rows only', () {
      final items = [
        _item(now.millisecondsSinceEpoch),
        _item(now.millisecondsSinceEpoch - 1000),
        _item(now.millisecondsSinceEpoch - 2000),
      ];
      final filtered = filterRecent(items, now: now, max: 2);
      expect(filtered, hasLength(2));
      expect(filtered[0].postedAt, items[0].postedAt);
      expect(filtered[1].postedAt, items[1].postedAt);
    });

    test('sinceMinutes drops rows outside the recency window', () {
      final fresh = _item(now.millisecondsSinceEpoch - 2 * 60 * 1000);
      final stale = _item(now.millisecondsSinceEpoch - 40 * 60 * 1000);
      final filtered = filterRecent(
        [fresh, stale],
        now: now,
        max: 50,
        sinceMinutes: 10,
      );
      expect(filtered, [fresh]);
    });

    test('package filter exact-matches the trimmed package name', () {
      final mail = _item(1, packageName: 'com.example.mail');
      final chat = _item(2, packageName: 'com.example.chat');
      expect(
        filterRecent(
          [chat, mail],
          now: now,
          max: 50,
          package: 'com.example.chat',
        ),
        [chat],
      );
      expect(
        filterRecent(
          [chat, mail],
          now: now,
          max: 50,
          package: ' com.example.mail ',
        ),
        [mail],
      );
      expect(
        filterRecent([chat, mail], now: now, max: 50, package: 'example.mail'),
        isEmpty,
      );
    });

    test('filters compose: package, recency, then max', () {
      final freshChat = _item(
        now.millisecondsSinceEpoch - 1000,
        packageName: 'com.example.chat',
      );
      final freshMail = _item(
        now.millisecondsSinceEpoch - 2000,
        packageName: 'com.example.mail',
      );
      final staleChat = _item(
        now.millisecondsSinceEpoch - 60 * 60 * 1000,
        packageName: 'com.example.chat',
      );
      final filtered = filterRecent(
        [freshMail, freshChat, staleChat],
        now: now,
        max: 1,
        sinceMinutes: 10,
        package: 'com.example.chat',
      );
      expect(filtered, [freshChat]);
    });
  });

  group('NotificationItem.fromMap', () {
    test('decodes the channel row shape and tolerates absent fields', () {
      final item = NotificationItem.fromMap({
        'packageName': 'com.example.mail',
        'title': 'Alarm',
        'postedAtMillis': 1791590000000,
      });
      expect(item.packageName, 'com.example.mail');
      expect(item.title, 'Alarm');
      expect(item.text, '');
      expect(item.postedAt.millisecondsSinceEpoch, 1791590000000);
    });
  });

  group('notificationsReadRender', () {
    test('renders numbered pkg · HH:MM · title: text rows', () {
      final rendered = notificationsReadRender([
        _item(
          DateTime(2026, 10, 9, 9, 5).millisecondsSinceEpoch,
          text: 'System update ready',
        ),
        _item(
          DateTime(2026, 10, 9, 14, 30).millisecondsSinceEpoch,
          packageName: 'com.example.chat',
          text: 'See you then',
        ),
      ]);
      final lines = rendered.split('\n');
      expect(lines, hasLength(2));
      expect(lines[0], contains('com.example.mail'));
      expect(lines[0], contains(' · 09:05 · Title: System update ready'));
      expect(lines[0], matches(RegExp(r'^1\. ')));
      expect(lines[1], contains(' · 14:30 · Title: See you then'));
    });

    test('blank titles fall back to bare text rows', () {
      final rendered = notificationsReadRender([
        _item(
          DateTime(2026, 10, 9, 10, 1).millisecondsSinceEpoch,
          title: '',
          text: 'Only body text',
        ),
      ]);
      expect(rendered, contains(' · 10:01 · Only body text'));
    });

    test('an empty ring renders the session-scoped guidance message', () {
      expect(
        notificationsReadRender(const []),
        notificationsReadEmptyMessage,
      );
      expect(
        notificationsReadEmptyMessage,
        contains('reader starts fresh with the app session'),
      );
    });
  });
}
