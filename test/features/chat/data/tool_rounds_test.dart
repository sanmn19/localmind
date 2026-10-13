import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/chat/data/background_runner.dart' as bg
    show bgUnapprovedToolMessage;
import 'package:localmind/features/chat/data/chat_service.dart' show ToolCallData;
import 'package:localmind/features/chat/data/models/message.dart' as msg
    show Message, ToolCallData;
import 'package:localmind/features/chat/data/tool_rounds.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';

// Task 5B: the shared tool-round executor backing BOTH the background
// runner and the fork chat tool loop. The background-runner round tests
// (background_runner_test.dart) stay pinned on top of this executor via the
// re-export; here the GATE branches are pinned directly.
void main() {
  msg.Message buildFeedbackRow({
    required String callId,
    required String resultText,
    required int threadOrder,
  }) {
    return msg.Message(
      id: 'tool_$callId',
      conversationId: 'fork-t',
      role: MessageRole.tool,
      content: resultText,
      createdAt: DateTime(2026, 10, 12),
      status: MessageStatus.complete,
      toolCallId: callId,
      isActiveVariant: false,
      threadOrder: threadOrder,
    );
  }

  msg.Message buildRoundRow({
    required String content,
    required List<msg.ToolCallData> toolCalls,
    required int threadOrder,
  }) {
    return msg.Message(
      id: 'round-$threadOrder',
      conversationId: 'fork-t',
      role: MessageRole.assistant,
      content: content,
      createdAt: DateTime(2026, 10, 12),
      status: MessageStatus.complete,
      toolCalls: toolCalls,
      isActiveVariant: false,
      threadOrder: threadOrder,
    );
  }

  ToolRoundSpec spec({
    required List<ToolCallData> calls,
    required Set<String> allowed,
    required Future<bool> Function(String, Map<String, dynamic>) gate,
    Future<ToolExecutionResult> Function(String, Map<String, dynamic>)?
        execute,
    required List<msg.Message> wire,
    required List<msg.Message> sink,
  }) {
    return ToolRoundSpec(
      conversationId: 'fork-t',
      wire: wire,
      nextThreadOrder: 5,
      streamedContent: 'checking…',
      calls: calls,
      allowedToolNames: allowed,
      approvalGate: gate,
      executeTool: execute,
      persistRow: (row) async => sink.add(row),
      buildRoundRow: buildRoundRow,
      buildFeedbackRow: buildFeedbackRow,
    );
  }

  ToolCallData call(String tool, Map<String, dynamic> args) =>
      ToolCallData(tool: tool, arguments: args);

  test('the legacy bg skip text is preserved VERBATIM by the extraction',
      () {
    // Pin BOTH entry points: the re-export via background_runner.dart and
    // the canonical tool_rounds.dart definition stay the same string.
    expect(
      bg.bgUnapprovedToolMessage('mail.send'),
      sameTextLegacy(),
    );
    expect(
      bgUnapprovedToolMessage('mail.send'),
      sameTextLegacy(),
    );
  });

  test('allowed + approved gate executes and persists round + feedback rows',
      () async {
    final wire = <msg.Message>[];
    final sink = <msg.Message>[];
    final executed = <String, Map<String, dynamic>>{};
    final result = await executeToolRound(spec(
      calls: [call('calc.add', {'a': 1, 'b': 2})],
      allowed: {'calc.add'},
      gate: (_, _) async => true,
      execute: (name, args) async {
        executed[name] = args;
        return const ToolExecutionResult.success('3');
      },
      wire: wire,
      sink: sink,
    ));

    expect(executed, {'calc.add': {'a': 1, 'b': 2}});
    // Persisted shape: the round assistant(tool_calls) row first, the
    // MessageRole.tool feedback row second — bg parity.
    expect(sink, hasLength(2));
    expect(sink.first.role, MessageRole.assistant);
    expect(sink.first.toolCalls!.single.result, '3');
    expect(sink.last.role, MessageRole.tool);
    expect(sink.last.content, '3');
    expect(sink.last.toolCallId, sink.first.toolCalls!.single.id);
    expect(sink.last.threadOrder, 5);
    // The wire grows for the follow-up generation and the caller gets the
    // next free thread order.
    expect(wire, hasLength(2));
    expect(result.nextThreadOrder, 6);
  });

  test('a call OUTSIDE the allowed set never executes and gets the skip text',
      () async {
    final sink = <msg.Message>[];
    var executed = 0;
    await executeToolRound(spec(
      calls: [call('mail.send', const {})],
      allowed: {'calc.add'},
      gate: (_, _) async => true,
      execute: (_, _) async {
        executed++;
        return const ToolExecutionResult.success('ran');
      },
      wire: [],
      sink: sink,
    ));
    expect(executed, 0);
    expect(sink.first.toolCalls!.single.result, contains('ERROR:'));
    expect(sink.first.toolCalls!.single.result, contains('approval'));
  });

  test('a missing executor seam is treated exactly like a not-allowed call',
      () async {
    final sink = <msg.Message>[];
    await executeToolRound(spec(
      calls: [call('calc.add', const {})],
      allowed: {'calc.add'},
      gate: (_, _) async => true,
      execute: null,
      wire: [],
      sink: sink,
    ));
    expect(sink.first.toolCalls!.single.result, contains('approval'));
  });

  test('a gate DENIAL never executes and reports the user as the reason',
      () async {
    final sink = <msg.Message>[];
    var executed = 0;
    await executeToolRound(spec(
      calls: [call('mail.send', const {})],
      allowed: {'mail.send'},
      gate: (_, _) async => false,
      execute: (_, _) async {
        executed++;
        return const ToolExecutionResult.success('ran');
      },
      wire: [],
      sink: sink,
    ));
    expect(executed, 0);
    final resultText = sink.first.toolCalls!.single.result;
    expect(resultText, contains('ERROR:'));
    expect(resultText, contains('denied by the user'));
    expect(sink.last.content, contains('denied by the user'));
  });

  test('multiple calls in one round persist in call order', () async {
    final sink = <msg.Message>[];
    await executeToolRound(spec(
      calls: [call('calc.add', const {}), call('calc.multiply', const {})],
      allowed: {'calc.add', 'calc.multiply'},
      gate: (_, _) async => true,
      execute: (name, _) async =>
          ToolExecutionResult.success(name == 'calc.add' ? '3' : '24'),
      wire: [],
      sink: sink,
    ));
    expect(sink, hasLength(3));
    expect(
      sink.where((row) => row.role == MessageRole.tool).map((row) => row.content),
      ['3', '24'],
    );
  });
}

/// The original constant from background_runner.dart (pinned copy-of-copy:
/// the extractor must not re-word the model-visible protocol string).
String sameTextLegacy() =>
    'ERROR: tool `mail.send` requires the user\'s approval dialog and is '
    'not allowed to run in background tasks. Continue without it.';
