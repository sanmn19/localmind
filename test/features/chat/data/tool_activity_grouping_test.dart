import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/data/tool_activity_grouping.dart';

Message _assistant(
  String id, {
  String? group,
  int index = 0,
  bool active = true,
  int threadOrder = 0,
  String content = '',
  String? reasoning,
  List<ToolCallData>? toolCalls,
  String? parent,
}) {
  return Message(
    id: id,
    conversationId: 'c',
    role: MessageRole.assistant,
    content: content,
    createdAt: DateTime.utc(2026, 10, 5, 0, 0, threadOrder),
    reasoningContent: reasoning,
    toolCalls: toolCalls,
    variantGroupId: group,
    variantIndex: index,
    threadOrder: threadOrder,
    isActiveVariant: active,
    parentMessageId: parent,
  );
}

Message _tool(
  String id, {
  required String callId,
  required String parent,
  String? group,
  int index = 0,
  String content = 'result text',
  int threadOrder = 0,
}) {
  return Message(
    id: id,
    conversationId: 'c',
    role: MessageRole.tool,
    content: content,
    createdAt: DateTime.utc(2026, 10, 5, 0, 0, threadOrder + 50),
    toolCallId: callId,
    variantGroupId: group,
    variantIndex: index,
    threadOrder: threadOrder,
    parentMessageId: parent,
  );
}

ToolCallData _call(String id, String name, Map<String, dynamic> args) {
  return ToolCallData(id: id, toolName: name, arguments: args);
}

final _search = _call('call_1', 'web.search', {'query': 'flutter riverpod'});
final _fetch = _call('call_2', 'web.fetch', {'url': 'https://example.com'});

void main() {
  test('plain answer turns yield no activity block', () {
    final user = _assistant('u', group: 'U', content: 'question');
    final someOtherTurn = _assistant(
      'other',
      group: 'X',
      threadOrder: 5,
      content: 'other answer',
    );
    final tail = _assistant(
      'tail',
      group: 'A',
      threadOrder: 10,
      content: 'plain answer',
    );

    expect(toolActivityForChain([user, someOtherTurn, tail], tail), isNull);
  });

  test('collects one chain of search->fetch rounds with results', () {
    final user = _assistant(
      'user-turn',
      group: 'U',
      content: 'find it',
      threadOrder: 0,
    );
    final round1 = _assistant(
      'round-1',
      group: 'A',
      threadOrder: 1,
      toolCalls: [_search],
    );
    final result1 = _tool(
      'tool-1',
      callId: 'call_1',
      parent: 'round-1',
      group: 'A',
      content: 'search results body',
      threadOrder: 1,
    );
    final round2 = _assistant(
      'round-2',
      group: 'A',
      threadOrder: 2,
      toolCalls: [_fetch],
    );
    final result2 = _tool(
      'tool-2',
      callId: 'call_2',
      parent: 'round-2',
      group: 'A',
      content: 'fetched page body',
      threadOrder: 2,
    );
    final tail = _assistant(
      'tail',
      group: 'A',
      threadOrder: 3,
      content: 'final answer',
      reasoning: 'The answer follows from the search.',
    );

    final snapshot = toolActivityForChain([
      user,
      round1,
      result1,
      round2,
      result2,
      tail,
    ], tail);

    expect(snapshot, isNotNull);
    expect(snapshot!.calls, hasLength(2));
    expect(snapshot.calls[0].toolName, 'web.search');
    expect(snapshot.calls[0].arguments, {'query': 'flutter riverpod'});
    expect(snapshot.calls[0].result, 'search results body');
    expect(snapshot.calls[1].toolName, 'web.fetch');
    expect(snapshot.calls[1].result, 'fetched page body');
    expect(snapshot.reasoning, 'The answer follows from the search.');

    expect(
      chainToolMessages([
        user,
        round1,
        result1,
        round2,
        result2,
        tail,
      ], tail).map((m) => m.id),
      ['tool-1', 'tool-2'],
    );
  });

  test('falls back to the tool call result when no tool row exists', () {
    final round = _assistant(
      'round',
      group: 'A',
      threadOrder: 1,
      toolCalls: [
        ToolCallData(
          id: 'call_1',
          toolName: 'web.search',
          arguments: {},
          result: 'server executed output',
        ),
      ],
    );
    final tail = _assistant(
      'tail',
      group: 'A',
      threadOrder: 2,
      content: 'answer',
    );

    final snapshot = toolActivityForChain([round, tail], tail);
    expect(snapshot, isNotNull);
    expect(snapshot!.calls.single.result, 'server executed output');
  });

  test(
    'tail reasoning wins; without it earlier rounds concatenate and cap',
    () {
      final round1 = _assistant(
        'round-1',
        group: 'A',
        threadOrder: 1,
        toolCalls: [_search],
        reasoning: 'round thinking',
      );
      final tailWithThinking = _assistant(
        'tail',
        group: 'A',
        threadOrder: 2,
        content: 'answer',
        reasoning: 'tail thinking',
      );
      expect(
        toolActivityForChain([
          round1,
          tailWithThinking,
        ], tailWithThinking)!.reasoning,
        'tail thinking',
      );

      final tailWithoutThinking = _assistant(
        'tail',
        group: 'A',
        threadOrder: 2,
        content: 'answer',
      );
      expect(
        toolActivityForChain([
          round1,
          tailWithoutThinking,
        ], tailWithoutThinking)!.reasoning,
        'round thinking',
      );

      final chattyRoundLong = _assistant(
        'round-1',
        group: 'A',
        threadOrder: 1,
        toolCalls: [_search],
        reasoning: 'a' * 1500 + ' OLDER-THINKING-TAIL',
      );
      final collapsed = toolActivityForChain([
        chattyRoundLong,
        tailWithoutThinking,
      ], tailWithoutThinking);
      final reasoning = collapsed!.reasoning!;
      expect(reasoning.length, 1500);
      expect(reasoning.endsWith('OLDER-THINKING-TAIL'), isTrue);
    },
  );

  test('chain rounds that stream after the tail are not collapsed', () {
    final round1 = _assistant(
      'round-1',
      group: 'A',
      threadOrder: 1,
      toolCalls: [_search],
    );
    final result1 = _tool(
      'tool-1',
      callId: 'call_1',
      parent: 'round-1',
      group: 'A',
      threadOrder: 1,
    );
    final tail = _assistant(
      'tail',
      group: 'A',
      threadOrder: 2,
      content: 'answer',
    );

    expect(toolActivityForChain([round1, result1, tail], tail), isNotNull);
    // Neither of them is a chain tail for the block: the active timeline
    // only surfaces the LAST assistant of the group (the answer tail).
    // Callers pass the timeline the way the resolver produced it; a round
    // row (toolCalls present) is never a tail candidate.
    expect(toolActivityForChain([round1, result1, tail], round1), isNull);
  });
}
