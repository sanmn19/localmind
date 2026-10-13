import '../../../core/utils/uuid.dart';
import 'chat_service.dart';
import 'models/message.dart' as message_model;
import 'tools/tool_definition.dart';

/// Per-turn tool-round budget — shared by the background runner, the main
/// pipeline's loop and the fork tool loop (bg parity by construction).
const int bgMaxToolRounds = 6;

/// SHARED tool-round machinery (bg-upgrades/fork-tools task 5B): ONE
/// definition of the assistant(tool_calls) + MessageRole.tool round-row
/// protocol, reused by the background runner (`background_runner.dart`) AND
/// the fork chat tool loop (`fork_chat_notifier.dart`). The riverpod-free
/// module gives both callers an [approvalGate] seam:
/// - the background runner passes a default always-approved gate — its
///   dialog-tool denials keep coming from the ALLOWED SET (snapshot-time
///   auto-approve filtering), so all existing bg semantics are untouched;
/// - the fork loop's gate resolves `shouldAutoApproveTool` for the current
///   toggles and may await an in-panel approval chip.
///
/// Copy contract: the skip string below is the model-visible protocol text
/// the background pipeline has shipped since task 4 — it is pinned verbatim
/// by `background_runner_test.dart` and must not be re-worded here.

/// Error text the MODEL receives for a call it may not run on this surface
/// (structurally excluded, or an executor seam that is simply absent).
String bgUnapprovedToolMessage(String toolName) =>
    'ERROR: tool `$toolName` requires the user\'s approval dialog and is '
    'not allowed to run in background tasks. Continue without it.';

/// Error text the MODEL receives after a live approval chip was DENIED.
String toolDeniedByUserMessage(String toolName) =>
    'ERROR: tool `$toolName` was denied by the user. Continue without it.';

/// Consulted per call AFTER the tool name passed the allowed-set check.
/// Returning false yields [toolDeniedByUserMessage] instead of execution.
typedef ToolApprovalGate =
    Future<bool> Function(String toolName, Map<String, dynamic> arguments);

/// The background runner's historical semantics: every call that made it
/// past the allowed set runs without a dialog gate.
Future<bool> alwaysApprovedToolGate(
  String toolName,
  Map<String, dynamic> arguments,
) async => true;

/// One executed tool round's output rows (before the caller appends the
/// follow-up generation) plus the next free thread order.
class ToolRoundRows {
  const ToolRoundRows({
    required this.roundRow,
    required this.feedbackRows,
    required this.nextThreadOrder,
  });

  /// The assistant row carrying this round's tool-call entries.
  final message_model.Message roundRow;

  /// MessageRole.tool rows (wire + persisted, order = call order).
  final List<message_model.Message> feedbackRows;

  /// The next free thread order after this round's rows.
  final int nextThreadOrder;
}

/// Plain-value input for [executeToolRound]. Row BUILDER closures keep the
/// module free of per-caller persistence/presentation differences (the bg
/// runner and the fork notifier compose their own Message shapes).
class ToolRoundSpec {
  const ToolRoundSpec({
    required this.conversationId,
    required this.wire,
    required this.nextThreadOrder,
    required this.streamedContent,
    required this.calls,
    required this.allowedToolNames,
    this.approvalGate = alwaysApprovedToolGate,
    this.executeTool,
    required this.persistRow,
    required this.buildRoundRow,
    required this.buildFeedbackRow,
  });

  /// Hidden conversation the round rows belong to.
  final String conversationId;
  final List<message_model.Message> wire;
  final int nextThreadOrder;

  /// Assistant content streamed BEFORE the tool calls — persisted verbatim
  /// on the round row (bg parity: the wire keeps the full turn).
  final String streamedContent;

  /// Streamed calls of this round (`chat_service.ToolCallData` shape: the
  /// wire tool-call event; persisted rows use the message-model shape).
  final List<ToolCallData> calls;
  final Set<String> allowedToolNames;
  final ToolApprovalGate approvalGate;

  /// Executes an allowed, gate-approved call. Absent → every allowed call
  /// gets the skip string (the bg snapshot can ship without an executor).
  final Future<ToolExecutionResult> Function(
    String toolName,
    Map<String, dynamic> arguments,
  )? executeTool;

  final Future<void> Function(message_model.Message row) persistRow;

  /// Builds the persisted assistant(tool_calls) round row (isActiveVariant
  /// false is the caller's choice — builders own the row shape).
  final message_model.Message Function({
    required String content,
    required List<message_model.ToolCallData> toolCalls,
    required int threadOrder,
  }) buildRoundRow;

  /// Builds one MessageRole.tool feedback row per call.
  final message_model.Message Function({
    required String callId,
    required String resultText,
    required int threadOrder,
  }) buildFeedbackRow;
}

/// Executes every call in [ToolRoundSpec.calls] through allowed-set → gate →
/// executor, persists the round's assistant(tool_calls) row + one
/// MessageRole.tool row per call, and APPENDS both to the spec's wire for
/// the follow-up generation. Returns the rows plus the next free thread
/// order (bg parity: the whole round shares one thread order; the follow-up
/// generation gets `+ 1`).
Future<ToolRoundRows> executeToolRound(ToolRoundSpec spec) async {
  final persistedCalls = <message_model.ToolCallData>[];
  final feedbackRows = <message_model.Message>[];
  for (final call in spec.calls) {
    final callId = 'call_${generateUuidV4()}';
    String resultText;
    if (!spec.allowedToolNames.contains(call.tool) ||
        spec.executeTool == null) {
      resultText = bgUnapprovedToolMessage(call.tool);
    } else if (!await spec.approvalGate(call.tool, call.arguments)) {
      resultText = toolDeniedByUserMessage(call.tool);
    } else {
      final outcome = await spec.executeTool!(call.tool, call.arguments);
      resultText = outcome.success
          ? outcome.output
          : 'ERROR: ${outcome.error ?? 'tool failed'}';
    }
    persistedCalls.add(
      message_model.ToolCallData(
        id: callId,
        toolName: call.tool,
        arguments: call.arguments,
        result: resultText,
      ),
    );
    feedbackRows.add(
      spec.buildFeedbackRow(
        callId: callId,
        resultText: resultText,
        threadOrder: spec.nextThreadOrder,
      ),
    );
  }

  final roundRow = spec.buildRoundRow(
    content: spec.streamedContent,
    toolCalls: persistedCalls,
    threadOrder: spec.nextThreadOrder,
  );
  await spec.persistRow(roundRow);
  for (final feedback in feedbackRows) {
    await spec.persistRow(feedback);
  }

  spec.wire
    ..add(roundRow)
    ..addAll(feedbackRows);
  return ToolRoundRows(
    roundRow: roundRow,
    feedbackRows: feedbackRows,
    nextThreadOrder: spec.nextThreadOrder + 1,
  );
}
