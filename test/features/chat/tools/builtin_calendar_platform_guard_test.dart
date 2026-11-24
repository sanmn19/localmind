import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/tools/builtin_tool_provider.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('macOS calendar tools fail without touching the plugin', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final provider = BuiltInToolProvider(calendarToolsEnabled: true);

    for (final name in const [
      'calendar.list_events',
      'calendar.create_event',
      'calendar.list_calendars',
    ]) {
      final result = await provider.execute(name, const {});

      expect(result.success, isFalse, reason: name);
      expect(result.error, contains('unavailable'), reason: name);
    }
  });
}
