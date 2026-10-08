import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/views/components/message_variant_navigator.dart';
import 'package:localmind/l10n/app_localizations.dart';

Message _assistant(
  String id, {
  required String group,
  required int index,
  required bool active,
  int threadOrder = 0,
  List<ToolCallData>? toolCalls,
}) {
  return Message(
    id: id,
    conversationId: 'c',
    role: MessageRole.assistant,
    content: id,
    createdAt: DateTime.utc(2026, 10, 5, 0, 0, threadOrder),
    toolCalls: toolCalls,
    variantGroupId: group,
    variantIndex: index,
    threadOrder: threadOrder,
    isActiveVariant: active,
  );
}

Message _tool(String id, {required String group, required int index}) {
  return Message(
    id: id,
    conversationId: 'c',
    role: MessageRole.tool,
    content: _result,
    createdAt: DateTime.utc(2026, 10, 5, 0, 0, 100),
    variantGroupId: group,
    variantIndex: index,
    threadOrder: 9,
  );
}

const _result = 'tool result';

void main() {
  testWidgets('chain groups collapse to a single page (no pager)', (
    tester,
  ) async {
    const group = 'chain-group';
    final round1 = _assistant(
      'round1',
      group: group,
      index: 0,
      active: false,
      threadOrder: 1,
      toolCalls: [
        ToolCallData(id: 'call_1', toolName: 'web.search', arguments: {}),
      ],
    );
    final round2 = _assistant(
      'round2',
      group: group,
      index: 0,
      active: false,
      threadOrder: 2,
      toolCalls: [
        ToolCallData(id: 'call_2', toolName: 'web.fetch', arguments: {}),
      ],
    );
    final tail = _assistant(
      'tail',
      group: group,
      index: 0,
      active: true,
      threadOrder: 3,
    );
    final allMessages = [
      round1,
      _tool('tool1', group: group, index: 0),
      round2,
      _tool('tool2', group: group, index: 0),
      tail,
    ];

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MessageVariantNavigator(
            message: tail,
            allMessages: allMessages,
            onCycle: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Chain rounds and tool rows are timeline steps, not user-cyclable
    // variants: the tail is the only answer page, so no pager appears.
    expect(find.textContaining('/'), findsNothing);
  });

  testWidgets('plain variants keep the pager', (tester) async {
    const group = 'answer-group';
    final answer1 = _assistant(
      'answer1',
      group: group,
      index: 0,
      active: false,
    );
    final answer2 = _assistant('answer2', group: group, index: 1, active: true);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MessageVariantNavigator(
            message: answer2,
            allMessages: [answer1, answer2],
            onCycle: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('/'), findsOneWidget);
  });

  testWidgets('legacy chains (multiple active rounds) keep the pager', (
    tester,
  ) async {
    // Chains written before consolidation: every round row saved active, so
    // the resolver surfaces the first active row and the pager was the only
    // way to reach the final answer. The filter must not hide it there.
    const group = 'legacy-chain';
    final round1 = _assistant(
      'round1',
      group: group,
      index: 0,
      active: true,
      threadOrder: 1,
      toolCalls: [
        ToolCallData(id: 'call_1', toolName: 'web.search', arguments: {}),
      ],
    );
    final round2 = _assistant(
      'round2',
      group: group,
      index: 1,
      active: true,
      threadOrder: 2,
    );
    final tail = _assistant(
      'tail',
      group: group,
      index: 2,
      active: true,
      threadOrder: 3,
    );
    final allMessages = [
      round1,
      _tool('tool1', group: group, index: 0),
      round2,
      tail,
    ];

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MessageVariantNavigator(
            message: round1,
            allMessages: allMessages,
            onCycle: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('/'), findsOneWidget);
  });
}
