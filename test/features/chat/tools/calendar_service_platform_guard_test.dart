import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/tools/calendar_service.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('macOS calendar calls never touch the plugin', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final cal = CalendarService.instance;

    expect(await cal.requestAccess(), isFalse);
    expect(await cal.hasAccess(), isFalse);
    expect(await cal.listCalendars(), isEmpty);
    expect(await cal.listEvents(), isEmpty);

    final created = await cal.createEvent(
      title: 'Standup',
      startDate: DateTime(2026, 10, 21, 9),
      endDate: DateTime(2026, 10, 21, 9, 30),
    );
    expect(created['success'], isFalse);
    expect(created['error'], contains('unavailable'));
  });
}
