import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/utils/json_safe.dart';
import 'package:localmind/features/chat/data/tools/tool_event.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';

void main() {
  test('jsonSafe converts unencodable values to strings', () {
    final encoded = jsonEncode(
      jsonSafe({
        'bad': Object(),
        'list': [Object()],
        'when': DateTime.utc(2026, 11, 11),
      }),
    );
    expect(encoded, contains('Instance of'));
    expect(encoded, contains('2026-11-11'));
  });

  test('a tool event with a non-encodable argument still encodes', () {
    final event = ToolEvent(
      eventId: 'e1',
      timestamp: DateTime.utc(2026, 11, 11),
      status: ToolEventStatus.failed,
      toolName: 'web.fetch',
      providerType: ToolProviderType.mcp,
      arguments: {'raw': Object()},
      error: 'failed',
    );
    expect(() => jsonEncode(event.toMap()), returnsNormally);
  });
}
