import 'dart:async';

import 'package:async/async.dart';

import '../../../core/logger/app_logger.dart';
import '../../../core/models/enums.dart';
import '../../../core/utils/uuid.dart';
import '../../servers/data/models/server.dart';
import 'chat_service.dart';
import 'models/background_task.dart';
import 'models/chat_parameters.dart';
import 'models/message.dart' hide ToolCallData;
import 'models/message.dart' as msg_model show ToolCallData;
import 'tools/tool_definition.dart';

/// Task 4: foreground background-task run pipeline.
///
/// This file is deliberately riverpod-free (and host-test friendly): it
/// receives everything the engine resolved in the UI isolate as plain
/// values — a per-run [ChatService] built for the snapshot's server target,
/// the auto-approvable tool definitions chosen when the snapshot was taken,
/// and closures for persistence + the engine cancel probe. The riverpod
/// seam wiring lives in `background_engine.dart`.
///
/// Spec semantics (docs/specs/2026-10-09-background-tasks-notifications-mcp
/// -design.md): `[BG_DONE]` detection happens on the FINAL assistant content
/// only, after the same think-tag stripping the main pipeline uses — the
/// [ChatService] classes already decode think tags, so the pipeline only
/// strips the trailing marker line here.

const bgDoneMarker = '[BG_DONE]';

/// Owner-result row contract: rows are written as
/// `Background task result (<taskId>): <final text>`.
const bgResultRowPrefix = 'Background task result (';

/// Composes the owner-visible result row content for [taskId].
String bgResultRowContent(String taskId, String finalContent) =>
    '$bgResultRowPrefix$taskId): $finalContent';

/// Per-run tool-round budget — mirrors the main pipeline's tool loop.
const int bgMaxToolRounds = 6;

/// Fixed system framing for autonomous child runs (no persona).
const String bgRunnerSystemPrompt =
    'You are a LocalMind background sub-agent task running autonomously '
    'inside a hidden conversation.\n'
    '- Complete the task as thoroughly as possible now; there is no user '
    'watching this thread live.\n'
    '- Tools here are limited to an auto-approved, low-risk subset. Some '
    'tools require an approval dialog: calling one returns an ERROR string '
    '— do not retry it; work without it instead.\n'
    '- When you consider the task complete, END your reply with the line '
    '$bgDoneMarker on its own line so the result is delivered. If the task '
    'should keep the loop going, reply normally.';

/// Tool families that are structurally kept OUT of a child-task snapshot —
/// spawning further tasks (bg.*) and harvesting notifications are never
/// available to a background child, whatever the toggles said at spawn.
const List<String> bgNeverAvailableToolPrefixes = [
  'bg.',
  'notifications.',
];

/// Composes the child-safe toolset for a background snapshot (review I2):
/// structurally minus [bgNeverAvailableToolPrefixes] (bg.* and
/// notifications.* are never exposed to a child) AND keeps only tools whose
/// [approvable] verdict is true under the spawn-time settings. Pure and
/// dependency-injected — the tooling wiring supplies the real approval
/// predicate; tests supply a fake.
Future<List<ToolDefinition>> backgroundChildSafeTools({
  required List<ToolDefinition> allDefs,
  required Future<bool> Function(String toolName) approvable,
}) async {
  final defs = <ToolDefinition>[];
  for (final def in allDefs) {
    if (bgNeverAvailableToolPrefixes.any(def.name.startsWith)) continue;
    if (!await approvable(def.name)) continue;
    defs.add(def);
  }
  return defs;
}

/// True when the content ENDS with the literal `[BG_DONE]` marker on its own
/// line (strip-normalized: last content line, whitespace-tolerant). Markers
/// quoted mid-prose do NOT finish a task.
bool hasTrailingBgDoneMarker(String content) {
  final normalized = content.trimRight();
  if (!normalized.endsWith(bgDoneMarker)) return false;
  return normalized == bgDoneMarker ||
      normalized.endsWith('\n$bgDoneMarker');
}

/// Removes the trailing `[BG_DONE]` marker line when present; content
/// without the trailing marker is returned untouched (strip-normalization is
/// a suffix operation, not a global scrub).
String stripBgDoneMarker(String content) {
  if (!hasTrailingBgDoneMarker(content)) return content;
  final normalized = content.trimRight();
  final withoutMarker = normalized
      .substring(0, normalized.length - bgDoneMarker.length);
  return withoutMarker.trimRight();
}

/// Zero-input safety valve: a future that never resolves (used when no
/// cancel watch was wired).
Future<void> _neverSignal() => Completer<void>().future;

/// Failures that end a GENERATION (stream error, empty reply, tool-round
/// exhaustion). The engine's driver maps these onto the task row's `failed`
/// state; the row stays committed (no delivered result).
class BackgroundRunException implements Exception {
  BackgroundRunException(this.reason);

  final String reason;

  @override
  String toString() => 'BackgroundRunException: $reason';
}

/// A run could not START because no model target was ready for the snapshot
/// (review M7: the on-device pre-load case at boot-resume). Transient and
/// resumable — the driver returns WITHOUT [markFailed] so the task row stays
/// in the running state and the next engine pass picks it up.
class BackgroundTargetUnavailableException implements Exception {
  BackgroundTargetUnavailableException(this.reason);

  final String reason;

  @override
  String toString() =>
      'BackgroundTargetUnavailableException: $reason';
}

/// Outcome of one generation turn.
class BackgroundRunResult {
  const BackgroundRunResult({
    required this.content,
    required this.doneRequested,
    this.finalAssistantMessageId,
    this.error,
    this.aborted = false,
  });

  /// Strip-normalized final text (think tags already decoded by the chat
  /// service classes; trailing `[BG_DONE]` line removed).
  final String content;

  /// `[BG_DONE]` ended the task early (looping tasks finish now).
  final bool doneRequested;

  /// The persisted task-conversation assistant row id for the final
  /// (`ownerMessageId` on the task anchor row).
  final String? finalAssistantMessageId;

  /// Non-null on a stream failure — the driver marks the task failed.
  final String? error;

  /// A cancel relay hit the run: nothing finalizes, no rows count.
  final bool aborted;
}

/// Executes ONE tool call inside a background run (injected by the engine).
typedef BackgroundToolExecutor =
    Future<ToolExecutionResult> Function(
      String toolName,
      Map<String, dynamic> arguments,
    );

/// Resolves when a cancel request for this task arrives (engine cancel wire).
/// Never resolves when nothing was requested.
typedef BackgroundCancelWatch = Future<void> Function();

/// Plain-value snapshot the engine resolves at spawn time (UI isolate) and
/// hands to every run — see the module dartdoc.
class BackgroundRunSpec {
  const BackgroundRunSpec({
    required this.task,
    required this.prompt,
    required this.server,
    required this.modelId,
    required this.params,
    required this.toolDefs,
    required this.seedMessages,
    required this.chatService,
    this.toolExecutor,
    required this.persistRow,
    required this.isCancelled,
    this.cancelWatch,
  });

  final BackgroundTask task;
  final String prompt;
  final Server server;
  final String modelId;
  final ChatParameters params;

  /// Auto-approvable toolset, structurally minus bg.*/notifications.*.
  final List<ToolDefinition> toolDefs;

  /// Prior persisted rows of the task conversation (ordered oldest-first).
  final List<Message> seedMessages;
  final ChatService chatService;
  final BackgroundToolExecutor? toolExecutor;
  final Future<void> Function(Message row) persistRow;

  /// Engine cancel probe (in-memory flag; the loop driver re-polls the
  /// authoritative DB state between runs).
  final Future<bool> Function() isCancelled;

  /// Resolves once a cancel is requested — raced against stream events so a
  /// zero-input (hanging) stream still aborts promptly.
  final BackgroundCancelWatch? cancelWatch;

  Set<String> get allowedToolNames => {
        for (final tool in toolDefs) tool.name,
      };
}

/// Runs ONE generation turn against the task conversation: persists the run
/// prompt, streams via the injected [BackgroundRunSpec.chatService], mirrors
/// the main pipeline's tool feedback protocol (assistant tool_calls row +
/// MessageRole.tool rows), strip-normalizes the final content, and detects
/// the trailing `[BG_DONE]` marker.
///
/// Throws [BackgroundRunException] on stream failure / empty final reply /
/// tool-round exhaustion; returns an `aborted` result when the engine cancel
/// wire fired mid-run (the caller skips bookkeeping for aborted runs).
Future<BackgroundRunResult> runBackgroundTurn(BackgroundRunSpec spec) async {
  final rows = List<Message>.of(spec.seedMessages)
    ..sort((a, b) {
      final order = a.threadOrder.compareTo(b.threadOrder);
      if (order != 0) return order;
      return a.createdAt.compareTo(b.createdAt);
    });
  var nextThreadOrder = rows.isEmpty
      ? 0
      : rows.map((row) => row.threadOrder).reduce((a, b) => a > b ? a : b) + 1;

  // The run prompt rides the conversation as its own persisted user row
  // ("seeds it with the prompt as first user turn" — and re-runs the prompt
  // each loop iteration, per the spec wording "the prompt re-runs").
  final promptRow = Message(
    id: generateUuidV4(),
    conversationId: spec.task.taskConversationId,
    role: MessageRole.user,
    content: spec.prompt,
    createdAt: DateTime.now(),
    status: MessageStatus.complete,
  );
  await spec.persistRow(
    promptRow.copyWith(threadOrder: nextThreadOrder, isActiveVariant: true),
  );
  nextThreadOrder++;

  final wire = _assembleWire(spec, rows, promptRow);
  final allowed = spec.allowedToolNames;

  String content = '';
  var reasoningContent = '';
  final toolCalls = <ToolCallData>[];

  for (var round = 0; round < bgMaxToolRounds; round++) {
    content = '';
    reasoningContent = '';
    toolCalls.clear();
    var hadError = false;
    String? errorMessage;

    final responseQueue = StreamQueue<ChatResponse>(
      spec.chatService.sendMessage(
        server: spec.server,
        modelId: spec.modelId,
        messages: _liveWire(wire),
        params: spec.params,
        tools: spec.toolDefs.isEmpty ? null : spec.toolDefs,
      ),
    );
    final cancelSignal = (spec.cancelWatch ?? _neverSignal)();
    while (true) {
      if (await spec.isCancelled()) {
        // Mid-stream abort (cancel relay / delete cascade): cancel the
        // subscription and leave without any finalization writes.
        await responseQueue.cancel();
        return const BackgroundRunResult(
          content: '',
          doneRequested: false,
          aborted: true,
        );
      }
      // Race the next stream event against the cancel signal so a zero-input
      // (hanging) stream still aborts promptly.
      final race = Completer<ChatResponse?>();
      unawaited(
        responseQueue.hasNext.then((more) async {
          if (!race.isCompleted) {
            race.complete(more ? await responseQueue.next : null);
          }
        }),
      );
      unawaited(
        cancelSignal.then((_) {
          if (!race.isCompleted) race.complete(null);
        }),
      );
      final response = await race.future;
      // ignore: avoid_print
      if (response == null) {
        // Stream ended OR the cancel wire fired — probe which.
        await responseQueue.cancel();
        if (await spec.isCancelled()) {
          // ignore: avoid_print
          return const BackgroundRunResult(
            content: '',
            doneRequested: false,
            aborted: true,
          );
        }
        break;
      }
      switch (response.type) {
        case ChatResponseType.message:
          content += response.content ?? '';
        case ChatResponseType.reasoning:
          reasoningContent += response.reasoningContent ?? '';
        case ChatResponseType.toolCall:
          if (response.toolCall != null) toolCalls.add(response.toolCall!);
        case ChatResponseType.timeoutError:
        case ChatResponseType.error:
          hadError = true;
          errorMessage = response.content ??
              'The background model request failed.';
        case ChatResponseType.invalidToolCall:
        case ChatResponseType.done:
        case ChatResponseType.processing:
          break;
      }
    }

    if (hadError) {
      // streamHadError guard (fork notifier pattern): the error branch
      // finalizes the ONCE — the stream simply closes after the failure, and
      // the next round (or any done re-finalization) must never overwrite
      // the error row.
      await spec.persistRow(_assistantRow(
        spec,
        content: content,
        threadOrder: nextThreadOrder,
        status: MessageStatus.error,
        errorMessage: errorMessage,
        reasoningContent: reasoningContent,
      ));
      return BackgroundRunResult(
        content: '',
        doneRequested: false,
        error: errorMessage,
      );
    }

    if (toolCalls.isEmpty) {
      return _finalizeTurnWithoutTools(
        spec,
        content: content,
        reasoningContent: reasoningContent,
        threadOrder: nextThreadOrder,
      );
    }

    nextThreadOrder = await _executeToolRound(
      spec: spec,
      wire: wire,
      nextThreadOrder: nextThreadOrder,
      streamedContent: content,
      calls: List.of(toolCalls),
      allowedToolNames: allowed,
    );
  }

  throw BackgroundRunException(
    'Tool round limit reached ($bgMaxToolRounds) without a final answer.',
  );
}

/// Assembles the request wire for a run: fixed background framing system
/// row, the filtered persisted history, then this run's fresh prompt row.
List<Message> _assembleWire(
  BackgroundRunSpec spec,
  List<Message> rows,
  Message promptRow,
) {
  return [
    Message(
      id: 'bg-system-${spec.task.id}',
      conversationId: spec.task.taskConversationId,
      role: MessageRole.system,
      content: bgRunnerSystemPrompt,
      createdAt: DateTime.now(),
      status: MessageStatus.complete,
    ),
    for (final row in rows)
      if (row.role != MessageRole.system &&
          shouldIncludeMessageInChatContext(row) &&
          row.content.trim().isNotEmpty)
        row,
    promptRow,
  ];
}

/// Frozen wire snapshot per round — a live list would mutate under a
/// recorded `requests` entry when later rounds append to it.
List<Message> _liveWire(List<Message> wire) => List.of(wire);

/// Empty-mask failure text for tools a background child may never run
/// (they need the approval dialog) — returned to the MODEL, not the user.
String bgUnapprovedToolMessage(String toolName) =>
    'ERROR: tool `$toolName` requires the user\'s approval dialog and is '
    'not allowed to run in background tasks. Continue without it.';

Future<BackgroundRunResult> _finalizeTurnWithoutTools(
  BackgroundRunSpec spec, {
  required String content,
  required String reasoningContent,
  required int threadOrder,
}) async {
  final donePresent = hasTrailingBgDoneMarker(content);
  final normalized = stripBgDoneMarker(content);
  if (normalized.trim().isEmpty) {
    throw BackgroundRunException(
      'The model returned an empty reply for this background run.',
    );
  }
  final rowId = generateUuidV4();
  await spec.persistRow(_assistantRow(
    spec,
    content: normalized,
    threadOrder: threadOrder,
    reasoningContent: reasoningContent,
    id: rowId,
  ));
  return BackgroundRunResult(
    content: normalized,
    doneRequested: donePresent,
    finalAssistantMessageId: rowId,
  );
}

Message _assistantRow(
  BackgroundRunSpec spec, {
  required String content,
  required int threadOrder,
  MessageStatus status = MessageStatus.complete,
  String? errorMessage,
  String? reasoningContent,
  List<msg_model.ToolCallData>? toolCalls,
  bool isActiveVariant = true,
  String? id,
}) {
  return Message(
    id: id ?? generateUuidV4(),
    conversationId: spec.task.taskConversationId,
    role: MessageRole.assistant,
    content: content,
    createdAt: DateTime.now(),
    status: status,
    modelId: spec.modelId,
    errorMessage: errorMessage,
    reasoningContent:
        reasoningContent == null || reasoningContent.isEmpty
            ? null
            : reasoningContent,
    toolCalls: (toolCalls == null || toolCalls.isEmpty) ? null : toolCalls,
    isActiveVariant: isActiveVariant,
    threadOrder: threadOrder,
  );
}

/// One tool round: executes every call through the snapshot-gated executor
/// (dialog-needing names get the skip-with-error string), persists the
/// round's assistant(tool_calls) + tool-result rows, and APPENDS them to the
/// in-memory wire for the follow-up generation. Returns the next free
/// thread order.
Future<int> _executeToolRound({
  required BackgroundRunSpec spec,
  required List<Message> wire,
  required int nextThreadOrder,
  required String streamedContent,
  required List<ToolCallData> calls,
  required Set<String> allowedToolNames,
}) async {
  final persistedCalls = <msg_model.ToolCallData>[];
  final feedbackRows = <Message>[];
  for (final call in calls) {
    final callId = 'call_${generateUuidV4()}';
    String resultText;
    if (!allowedToolNames.contains(call.tool)) {
      resultText = bgUnapprovedToolMessage(call.tool);
    } else if (spec.toolExecutor == null) {
      resultText = bgUnapprovedToolMessage(call.tool);
    } else {
      final outcome = await spec.toolExecutor!(call.tool, call.arguments);
      resultText = outcome.success
          ? outcome.output
          : 'ERROR: ${outcome.error ?? 'tool failed'}';
    }
    persistedCalls.add(
      msg_model.ToolCallData(
        id: callId,
        toolName: call.tool,
        arguments: call.arguments,
        result: resultText,
      ),
    );
    feedbackRows.add(
      Message(
        id: 'tool_$callId',
        conversationId: spec.task.taskConversationId,
        role: MessageRole.tool,
        content: resultText,
        createdAt: DateTime.now(),
        status: MessageStatus.complete,
        toolCallId: callId,
        isActiveVariant: false,
        threadOrder: nextThreadOrder,
      ),
    );
  }

  final roundRow = _assistantRow(
    spec,
    content: streamedContent,
    threadOrder: nextThreadOrder,
    toolCalls: persistedCalls,
    isActiveVariant: false,
  );
  await spec.persistRow(roundRow);
  for (final feedback in feedbackRows) {
    await spec.persistRow(feedback);
  }

  wire
    ..add(roundRow)
    ..addAll(feedbackRows);
  return nextThreadOrder + 1;
}

/// Loop-driver seams: the DB/service-facing surface the engine injects.
/// All persistence-backed seams re-poll/verify authoritative state — the
/// driver only interprets and sequences.
class BackgroundLoopSeams {
  const BackgroundLoopSeams({
    required this.inspectRow,
    required this.conversationExists,
    required this.recordRun,
    required this.markFinished,
    required this.markFailed,
    required this.runTurn,
    required this.finalize,
    required this.waitBetweenRuns,
    required this.canceller,
  });

  /// Authoritative task-row read (null = row gone → loop exits).
  final Future<BackgroundTask?> Function(String taskId) inspectRow;

  /// Whether the hidden task conversation still exists (T2 concern: deleting
  /// a task conversation outside the delete-cascade leaves a dangling row).
  final Future<bool> Function(String conversationId) conversationExists;

  /// Post-run bookkeeping: runCount++ / lastRunAt (only running rows move).
  final Future<bool> Function(String taskId) recordRun;
  final Future<bool> Function(
    String taskId, {
    String? resultMessageId,
    String? ownerMessageId,
  })
      markFinished;
  final Future<bool> Function(String taskId) markFailed;

  /// Runs one generation turn (the runner above — engine-built).
  final Future<BackgroundRunResult> Function(BackgroundTask task) runTurn;

  /// Engine finalize: appends the owner-conversation result row, commits the
  /// anchor ids, posts the notification, invalidates UI state. A cancelTask
  /// race keeps the anchor row cancelled — the engine handles that outcome
  /// internally.
  final Future<void> Function(BackgroundTask task, BackgroundRunResult result)
      finalize;

  /// Resolves when the task's next run may fire — production sleeps for
  /// `loopMinutes`; tests inject instant resumption.
  final Future<void> Function(BackgroundTask task, Duration delay)
      waitBetweenRuns;

  /// Shared cancel registry (the engine's cancel wire flags + wakes here).
  final BackgroundRunCanceller canceller;
}

/// Drives a task row to completion: re-polls the AUTHORITATIVE row state
/// before every atomic step, runs a generation turn per iteration, records
/// run bookkeeping, and finalizes on single-run completion / maxRuns
/// exhaustion / trailing `[BG_DONE]`.
///
/// Returns silently when the row went missing or left the running state —
/// cancellation and delete cascades are committed states, not failures.
Future<void> driveBackgroundTaskLoop(
  String taskId, {
  required BackgroundLoopSeams seams,
}) async {
  while (true) {
    final task = await seams.inspectRow(taskId);
    if (task == null || task.state != BackgroundTaskState.running) {
      return;
    }
    if (!await seams.conversationExists(task.taskConversationId)) {
      // Dangling task conversation (T2 concern #1): skip gracefully.
      await seams.markFailed(taskId);
      return;
    }

    final BackgroundRunResult result;
    try {
      result = await seams.runTurn(task);
    } on BackgroundTargetUnavailableException {
      // Review M7: an unreachable model target is transient (on-device
      // pre-load etc.). The row stays RUNNING and resumable — no markFailed,
      // no finalize; a later engine pass resumes it.
      Log.info(
        'Background task $taskId waits for a ready model target '
        '(target unavailable).',
      );
      return;
    } on BackgroundRunException catch (error, stack) {
      Log.error('Background task $taskId run failed: $error\n$stack');
      await seams.markFailed(taskId);
      return;
    } catch (error, stack) {
      Log.error('Background task $taskId crashed: $error\n$stack');
      await seams.markFailed(taskId);
      return;
    }
    if (result.aborted) return;

    // Bookkeeping precedes the exit-poll on purpose: recordRun only moves
    // still-running rows (service-side guard), and the poll then refuses
    // further work when the row was cancelled mid-run.
    final recorded = await seams.recordRun(taskId);

    // Authoritative re-poll BEFORE final/bookkeeping steps: the row may
    // have been cancelled (bg.cancel relay) or deleted while streaming.
    final postRun = await seams.inspectRow(taskId);
    if (postRun == null || postRun.state != BackgroundTaskState.running) {
      return;
    }
    if (!recorded) return;

    final runNumber = postRun.runCount;
    final isFinal =
        postRun.loopMinutes == 0 ||
        result.doneRequested ||
        runNumber >= postRun.maxRuns;
    if (isFinal) {
      final finalContent = hasTrailingBgDoneMarker(result.content)
          ? stripBgDoneMarker(result.content)
          : result.content;
      await seams.finalize(
        postRun,
        BackgroundRunResult(
          content: finalContent,
          doneRequested: result.doneRequested,
          finalAssistantMessageId: result.finalAssistantMessageId,
        ),
      );
      return;
    }

    await seams.waitBetweenRuns(postRun, Duration(minutes: postRun.loopMinutes));
  }
}

/// The engine's cancel registry. Flagging a task wakes any pending
/// `sleep` early AND is what the per-round `isCancelled` probe reads.
class BackgroundRunCanceller {
  final Set<String> _flagged = {};
  final Map<String, List<Completer<void>>> _waiters = {};

  void request(String taskId) {
    _flagged.add(taskId);
    for (final waiter in _waiters[taskId] ?? const <Completer<void>>[]) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  bool isRequested(String taskId) => _flagged.contains(taskId);

  /// Resolves once a cancel request for [taskId] arrives (never if none
  /// comes). Raced against stream events inside the run.
  Future<void> watch(String taskId) {
    if (_flagged.contains(taskId)) return Future.value();
    final completer = Completer<void>();
    (_waiters[taskId] ??= <Completer<void>>[]).add(completer);
    return completer.future;
  }

  /// Resolves after [delay], or EARLY once a cancel request for [taskId]
  /// arrived; the caller re-polls authoritative state when woken. Returns
  /// whether a cancel request was seen.
  Future<bool> sleep(String taskId, Duration delay) async {
    if (_flagged.contains(taskId)) return true;
    final completer = Completer<void>();
    (_waiters[taskId] ??= <Completer<void>>[]).add(completer);
    final timer = Timer(delay, () {
      if (!completer.isCompleted) completer.complete();
    });
    try {
      await completer.future;
    } finally {
      timer.cancel();
      _waiters[taskId]?.remove(completer);
    }
    return _flagged.contains(taskId);
  }
}
