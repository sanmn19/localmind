import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/chat/data/background_runner.dart';
import 'package:localmind/features/chat/data/chat_service.dart';
import 'package:localmind/features/chat/data/models/background_task.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/mcp_integration.dart';
import 'package:localmind/features/chat/data/models/message.dart' hide
    ToolCallData;
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/servers/data/models/server.dart';

// Task 4 of the background sub-agents feature: the riverpod-free run
// pipeline. One "turn" is a full generation against the task conversation's
// persisted rows (tool rounds included); the loop driver chains re-runs for
// looping tasks until maxRuns / [BG_DONE] / cancellation.
//
// ChatService is faked per repo convention (fork_chat_notifier_test.dart's
// streaming fakes); persistence is an in-memory sandbox list — the host
// toolchain cannot load libobjectbox.so (probe convention documented in
// fork_service_test.dart). Closures stand in for the DB-backed seams the
// engine wires in production.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('stripBgDoneMarker / hasTrailingBgDoneMarker', () {
    test('strips a trailing marker line', () {
      expect(stripBgDoneMarker('answer\n[BG_DONE]'), 'answer');
      expect(stripBgDoneMarker('answer\n\n[BG_DONE]\n  '), 'answer');
    });

    test('leaves content without the trailing marker untouched', () {
      expect(stripBgDoneMarker('plain answer'), 'plain answer');
      expect(
        stripBgDoneMarker('[BG_DONE] quoted in prose'),
        '[BG_DONE] quoted in prose',
      );
      expect(hasTrailingBgDoneMarker('plain answer'), isFalse);
    });

    test('detects the trailing marker', () {
      expect(hasTrailingBgDoneMarker('done\n[BG_DONE]'), isTrue);
      expect(hasTrailingBgDoneMarker('done'), isFalse);
    });
  });

  group('backgroundChildSafeTools (I2 exclusion filter)', () {
    ToolDefinition def(String name) => ToolDefinition(
          name: name,
          description: 'test $name',
          inputSchema: const {},
          providerType: ToolProviderType.mcp,
        );

    test('child set keeps only approvable non-bg tool names (fake verdicts)',
        () async {
      final child = await backgroundChildSafeTools(
        allDefs: [
          def('bg.spawn'),
          def('bg.cancel'),
          def('notifications.read_recent'),
          def('web.search'),
          def('terminal.run'),
          def('calc.add'),
        ],
        approvable: (toolName) async => toolName != 'terminal.run',
      );

      expect(
        child.map((d) => d.name),
        unorderedEquals(['web.search', 'calc.add']),
      );
    });

    test('bg.*/notifications.* drop structurally even when approvable',
        () async {
      final child = await backgroundChildSafeTools(
        allDefs: [
          def('bg.spawn'),
          def('bg.status'),
          def('notifications.read_recent'),
        ],
        approvable: (_) async => true,
      );

      expect(child, isEmpty,
          reason: 'structural exclusion precedes the toggle verdict');
    });

    test('empty defs.resolve to an empty child set', () async {
      final child = await backgroundChildSafeTools(
        allDefs: const [],
        approvable: (_) async => true,
      );
      expect(child, isEmpty);
    });
  });

  group('runBackgroundTurn (single-run pipeline)', () {
    test('streams one generation and persists user + assistant rows',
        () async {
      final rows = <Message>[];
      final service = _ScriptedChatService([
        _chunks(['Plan: ', 'do it']),
      ]);

      final result = await runBackgroundTurn(
        _spec(
          chatService: service,
          onPersist: rows.add,
          seed: const <Message>[],
          prompt: 'watch the mail',
          toolDefs: const [],
        ),
      );

      expect(result.content, 'Plan: do it');
      expect(result.doneRequested, isFalse);
      expect(result.error, isNull);
      expect(result.aborted, isFalse);

      // The prompt rides the wire as a system context + user row.
      final wire = service.requests.single;
      expect(wire.first.role, MessageRole.system);
      expect(wire.first.content, contains('[BG_DONE]'));
      expect(wire.last.role, MessageRole.user);
      expect(wire.last.content, 'watch the mail');

      // The exchange persists into the hidden task conversation; both rows
      // pass the shared delivered-row wire filter (content non-empty).
      expect(
        rows.map((row) => (row.role, row.content)).toList(),
        containsAllInOrder([
          (MessageRole.user, 'watch the mail'),
          (MessageRole.assistant, 'Plan: do it'),
        ]),
      );
      expect(shouldIncludeMessageInChatContext(rows.last), isTrue);
      for (final row in rows) {
        expect(row.conversationId, 'task-c1');
      }
    });

    test('strip-normalizes final content before persisting + delivering',
        () async {
      final rows = <Message>[];
      final result = await runBackgroundTurn(
        _spec(
          chatService: _ScriptedChatService([_chunks(['done\n[BG_DONE]'])]),
          onPersist: rows.add,
          seed: const <Message>[],
          prompt: 'watch the mail',
          toolDefs: const [],
        ),
      );

      expect(result.content, 'done');
      expect(result.doneRequested, isTrue);
      // The persisted task row carries the STRIPPED content — the marker is
      // protocol, never prose (spec: detection after strip-normalization).
      expect(rows.last.content, 'done');
      expect(rows.last.content, isNot(contains('[BG_DONE]')));
    });

    test('re-runs carry the persisted history before the fresh prompt',
        () async {
      final rows = <Message>[];
      final seed = [
        _row(
          id: 'u-1',
          role: MessageRole.user,
          content: 'watch the mail',
          threadOrder: 0,
        ),
        _row(
          id: 'a-1',
          role: MessageRole.assistant,
          content: 'mail is quiet',
          threadOrder: 1,
        ),
      ];
      final service = _ScriptedChatService([_chunks(['still quiet'])]);

      final spec = _spec(
        chatService: service,
        onPersist: rows.add,
        seed: seed,
        prompt: 'watch the mail',
        toolDefs: const [],
      );
      final result = await runBackgroundTurn(spec);

      expect(result.content, 'still quiet');
      final wire = service.requests.single;
      final nonSystem = wire.where((m) => m.role != MessageRole.system);
      expect(nonSystem, hasLength(3));
      expect(
        nonSystem.map((m) => m.content),
        ['watch the mail', 'mail is quiet', 'watch the mail'],
      );
      expect(nonSystem.last.role, MessageRole.user);
    });

    test('error-then-done is finalized once, never re-finalized by onDone',
        () async {
      final rows = <Message>[];
      // Mirrors the real services' failure shape (fork test fakes): partial
      // content, then the error as a data event, then the stream closes.
      final service = _PartialThenErrorChatService();
      final result = await runBackgroundTurn(
        _spec(
          chatService: service,
          onPersist: rows.add,
          seed: const <Message>[],
          prompt: 'watch the mail',
          toolDefs: const [],
        ),
      );

      expect(result.error, isNotNull);
      expect(result.content, isEmpty);

      // Exactly ONE assistant row was persisted, in the error state — the
      // streamed-close onDone must not re-finalize it as complete.
      final assistantRows =
          rows.where((row) => row.role == MessageRole.assistant);
      expect(assistantRows, hasLength(1));
      expect(assistantRows.single.status, MessageStatus.error);
      expect(assistantRows.single.errorMessage, contains('failed mid-stream'));
    });

    test('empty final reply fails the run (no delivered row)', () async {
      final rows = <Message>[];
      await expectLater(
        runBackgroundTurn(
          _spec(
            chatService: _ScriptedChatService([_chunks([' '])]),
            onPersist: rows.add,
            seed: const <Message>[],
            prompt: 'watch the mail',
            toolDefs: const [],
          ),
        ),
        throwsA(isA<BackgroundRunException>()),
      );
      expect(
        rows.where((row) => row.role == MessageRole.assistant),
        isEmpty,
        reason: 'nothing finalizes for an empty reply',
      );
    });
  });

  group('runBackgroundTurn (tool rounds)', () {
    test('an auto-approvable tool executes through the injected executor',
        () async {
      final rows = <Message>[];
      final executed = <String, Map<String, dynamic>>{};
      final service = _ScriptedChatService([
        _chunks(['checking…'],
            toolCall: ToolCallData(
              tool: 'calc.add',
              arguments: {'a': 1, 'b': 2},
            )),
        _chunks(['the sum is 3']),
      ]);

      final spec = _spec(
        chatService: service,
        onPersist: rows.add,
        seed: const <Message>[],
        prompt: 'add numbers',
        toolDefs: [
          const ToolDefinition(
            name: 'calc.add',
            description: 'add',
            inputSchema: {'type': 'object'},
            providerType: ToolProviderType.builtIn,
          ),
        ],
        toolExecutor: (name, args) async {
          executed[name] = args;
          return const ToolExecutionResult.success('3');
        },
      );
      final result = await runBackgroundTurn(spec);

      expect(executed.keys.single, 'calc.add');
      expect(result.content, 'the sum is 3');

      // The model received the tool result as a MessageRole.tool row paired
      // with the assistant round's tool_calls entry id.
      final wire = service.requests.last;
      final roundAssistant =
          wire.where((m) => m.role == MessageRole.assistant &&
              m.toolCalls != null).single;
      final feedbackRow =
          wire.where((m) => m.role == MessageRole.tool).single;
      expect(feedbackRow.content, '3');
      expect(feedbackRow.toolCallId, roundAssistant.toolCalls!.single.id);
      expect(feedbackRow.toolCallId, isNotEmpty);
      final roundToolCallEntry = roundAssistant.toolCalls!.single;
      expect(roundToolCallEntry.result, '3');

      // Persisted ordering: user, round assistant(toolCalls), tool, final.
      expect(
        rows.map((row) => (row.role, row.content)).toList(),
        containsAllInOrder([
          (MessageRole.user, 'add numbers'),
          (MessageRole.tool, '3'),
          (MessageRole.assistant, 'the sum is 3'),
        ]),
      );
    });

    test('dialog-needing tools return an error string and never execute',
        () async {
      final rows = <Message>[];
      var executorCalls = 0;
      final service = _ScriptedChatService([
        _chunks(
          ['Let me send that mail.'],
          toolCall: ToolCallData(
            tool: 'mail.send',
            arguments: {'to': 'x@example.com'},
          ),
        ),
        _chunks(['I cannot send mail autonomously.']),
      ]);

      final spec = _spec(
        chatService: service,
        onPersist: rows.add,
        seed: const <Message>[],
        prompt: 'send mail',
        // mail.send is STRUCTURALLY out of the snapshot toolset (auto-approve
        // evaluation ran in the UI isolate when the snapshot was taken).
        toolDefs: const [],
        toolExecutor: (name, args) async {
          executorCalls++;
          return const ToolExecutionResult.success('sent');
        },
      );
      final result = await runBackgroundTurn(spec);

      expect(executorCalls, 0, reason: 'dialog tools never execute');
      // The model still gets a readable failure through the tool feedback
      // path — skip-with-error, never a silent drop.
      final feedbackRow =
          service.requests.last.where((m) => m.role == MessageRole.tool).single;
      expect(feedbackRow.content, contains('ERROR:'));
      expect(feedbackRow.content, contains('mail.send'));
      expect(feedbackRow.content, contains('approval'));
      final roundAssistant = service.requests.last
          .where((m) => m.role == MessageRole.assistant && m.toolCalls != null)
          .single;
      expect(feedbackRow.toolCallId, roundAssistant.toolCalls!.single.id);
      expect(result.content, 'I cannot send mail autonomously.');
    });

    test('a mid-run cancel aborts without persisting a final row', () async {
      final rows = <Message>[];
      final service = _ScriptedChatService([
        _chunks(
          ['checking…'],
          toolCall:
              ToolCallData(tool: 'calc.add', arguments: {'a': 1, 'b': 2}),
        ),
      ]);

      final result = await runBackgroundTurn(
        _spec(
          chatService: service,
          onPersist: rows.add,
          seed: const <Message>[],
          prompt: 'add',
          toolDefs: [
            const ToolDefinition(
              name: 'calc.add',
              description: 'add',
              inputSchema: {'type': 'object'},
              providerType: ToolProviderType.builtIn,
            ),
          ],
          toolExecutor: (name, args) async =>
              const ToolExecutionResult.success('3'),
          isCancelled: () async => true, // engine cancel wire flips this
        ),
      );

      expect(result.aborted, isTrue);
      expect(result.content, isEmpty);
      expect(
        rows.where((row) => row.role == MessageRole.assistant),
        isEmpty,
        reason: 'no finalized row lands after an abort',
      );
      expect(service.requests, hasLength(1));
    });
  });

  group('driveBackgroundTaskLoop', () {
    test('single-run: one run, then the engine finalize seam runs', () async {
      final harness = _LoopHarness(loopMinutes: 0, maxRuns: 10);
      harness.turnScript = (runNumber) => _TurnResult(
            content: 'watched once',
            doneRequested: false,
          );

      await driveBackgroundTaskLoop(harness.taskId, seams: harness.seams());

      expect(harness.turnCalls, 1);
      expect(harness.recordedRuns, hasLength(1));
      expect(harness.finalized, hasLength(1));
      expect(harness.finalized.single.$2.content, 'watched once');
      expect(harness.markedFailed, isEmpty);
    });

    test('looping: 3 runs then [BG_DONE] early-finish', () async {
      final harness = _LoopHarness(loopMinutes: 10, maxRuns: 10);
      harness.turnScript = (runNumber) => _TurnResult(
            content: runNumber < 3
                ? 'partial observation $runNumber'
                : 'task concluded\n[BG_DONE]',
            doneRequested: runNumber >= 3,
          );

      await driveBackgroundTaskLoop(harness.taskId, seams: harness.seams());

      // recordRun bumps per run; finalize fired once on the marker run.
      expect(harness.turnCalls, 3);
      expect(harness.recordedRuns, hasLength(3));
      expect(harness.finalized, hasLength(1));
      // The finalize leg receives the STRIPPED content.
      expect(harness.finalized.single.$2.content, 'task concluded');
    });

    test('looping: runs exhaust maxRuns and finish without a marker',
        () async {
      final harness = _LoopHarness(loopMinutes: 10, maxRuns: 3);
      harness.turnScript = (runNumber) =>
          _TurnResult(content: 'observation $runNumber', doneRequested: false);

      await driveBackgroundTaskLoop(harness.taskId, seams: harness.seams());

      expect(harness.turnCalls, 3);
      expect(harness.recordedRuns, hasLength(3));
      expect(harness.finalized, hasLength(1));
    });

    test('a vanished task conversation skips gracefully: markFailed, no run',
        () async {
      final harness = _LoopHarness(loopMinutes: 10, maxRuns: 10);
      harness.conversationMissing = true;

      await driveBackgroundTaskLoop(harness.taskId, seams: harness.seams());

      expect(harness.turnCalls, 0);
      expect(harness.recordedRuns, isEmpty);
      expect(harness.markedFailed, [harness.taskId]);
      expect(harness.finalized, isEmpty);
    });

    test('a DB-cancelled row stops the loop without finalizing', () async {
      final harness = _LoopHarness(loopMinutes: 10, maxRuns: 10);
      harness.turnScript = (runNumber) =>
          _TurnResult(content: 'observation $runNumber', doneRequested: false);
      // The cancel relay writes the DB state after the first run; the loop's
      // authoritative poll then refuses run 2 (DB cancel is authoritative —
      // the wire only shortens the wait).
      harness.cancelAfterTurns = 1;

      await driveBackgroundTaskLoop(harness.taskId, seams: harness.seams());

      expect(harness.turnCalls, 1);
      expect(harness.recordedRuns, hasLength(1));
      expect(harness.finalized, isEmpty);
      expect(harness.markedFailed, isEmpty);
    });

    test('a paused row parks the loop without finalizing (lifecycle pause)',
        () async {
      final harness = _LoopHarness(loopMinutes: 10, maxRuns: 10);
      harness.turnScript = (runNumber) =>
          _TurnResult(content: 'observation $runNumber', doneRequested: false);
      // The pause relay wakes the run and writes the DB state after the
      // first turn; the loop's authoritative poll sees `paused` and parks
      // WITHOUT finalize (a resume starts a FRESH loop instead).
      harness.pauseAfterTurns = 1;

      await driveBackgroundTaskLoop(harness.taskId, seams: harness.seams());

      expect(harness.turnCalls, 1);
      expect(harness.recordedRuns, hasLength(1));
      expect(harness.finalized, isEmpty);
      expect(harness.markedFailed, isEmpty);
      expect(harness.task.state, BackgroundTaskState.paused);
    });

    test('run-exception marks the task failed once', () async {
      final harness = _LoopHarness(loopMinutes: 0, maxRuns: 10);
      harness.turnError = BackgroundRunException('model failed');

      await driveBackgroundTaskLoop(harness.taskId, seams: harness.seams());

      expect(harness.turnCalls, 1);
      expect(harness.recordedRuns, isEmpty);
      expect(harness.finalized, isEmpty);
      expect(harness.markedFailed, [harness.taskId]);
    });

    test('target-unavailable turns stay RUNNING (M7: no markFailed, '
        'resumable)', () async {
      final harness = _LoopHarness(loopMinutes: 0, maxRuns: 10);
      harness.turnCrash =
          BackgroundTargetUnavailableException('no ready model target');

      await driveBackgroundTaskLoop(harness.taskId, seams: harness.seams());

      expect(harness.turnCalls, 1);
      expect(harness.markedFailed, isEmpty,
          reason: 'unreachable target is transient — never a failure commit');
      expect(harness.recordedRuns, isEmpty);
      expect(harness.finalized, isEmpty);
      // inspectRow state unchanged: the row is still running (resumable).
      expect(harness.task.state, BackgroundTaskState.running);
    });
  });
}

// ---------------------------------------------------------------------------
// Fake ChatService classes (fork_chat_notifier_test conventions).
// ---------------------------------------------------------------------------

/// Scripted responses: one script per request. Each script streams message
/// chunks (plus an optional single toolCall) and closes with `done`.
class _ScriptedChatService implements ChatService {
  final List<List<ChatResponse>> scripts;
  final requests = <List<Message>>[];

  _ScriptedChatService(Iterable<List<ChatResponse>> scripts)
      : scripts = List.of(scripts);

  @override
  Stream<ChatResponse> sendMessage({
    required Server server,
    required String modelId,
    required List<Message> messages,
    required ChatParameters params,
    List<McpIntegration>? integrations,
    List<ToolDefinition>? tools,
    bool continueGeneration = false,
  }) async* {
    requests.add(messages);
    final script = scripts.isEmpty ? const <ChatResponse>[] : scripts.removeAt(0);
    yield* Stream.fromIterable(script);
    yield const ChatResponse(type: ChatResponseType.done);
  }

  @override
  void cancelStream() {}
}

/// Mirrors the real services' mid-stream failure shape: partial message
/// content, then the error as a data event, then the stream closes — so the
/// pipeline's onDone-equivalent path must not re-finalize the error row.
class _PartialThenErrorChatService implements ChatService {
  final requests = <List<Message>>[];

  @override
  Stream<ChatResponse> sendMessage({
    required Server server,
    required String modelId,
    required List<Message> messages,
    required ChatParameters params,
    List<McpIntegration>? integrations,
    List<ToolDefinition>? tools,
    bool continueGeneration = false,
  }) async* {
    requests.add(messages);
    yield const ChatResponse(type: ChatResponseType.message, content: 'Hel');
    yield const ChatResponse(
      type: ChatResponseType.error,
      content: 'The model failed mid-stream.',
    );
  }

  @override
  void cancelStream() {}
}

// ---------------------------------------------------------------------------
// Script/spec helpers
// ---------------------------------------------------------------------------

List<ChatResponse> _chunks(
  List<String> parts, {
  ToolCallData? toolCall,
}) {
  return [
    for (final part in parts)
      ChatResponse(type: ChatResponseType.message, content: part),
    if (toolCall != null)
      ChatResponse(type: ChatResponseType.toolCall, toolCall: toolCall),
  ];
}

Server _remoteServer() {
  return Server(
    id: 'srv-1',
    name: 'Lan Server',
    type: ServerType.openAICompatible,
    host: '10.0.0.5',
    port: 1234,
    createdAt: DateTime.utc(2026, 10, 9),
    lastConnectedAt: DateTime.utc(2026, 10, 9),
  );
}

Message _row({
  required String id,
  required MessageRole role,
  required String content,
  required int threadOrder,
}) {
  return Message(
    id: id,
    conversationId: 'task-c1',
    role: role,
    content: content,
    createdAt: DateTime.utc(2026, 10, 9, 12),
    status: MessageStatus.complete,
    threadOrder: threadOrder,
  );
}

BackgroundTask _task({
  String id = 't-1',
  String owner = 'owner-1',
  String taskConversation = 'task-c1',
  int loopMinutes = 0,
  int maxRuns = 10,
  int runCount = 0,
  BackgroundTaskState state = BackgroundTaskState.running,
}) {
  return BackgroundTask(
    id: id,
    ownerConversationId: owner,
    taskConversationId: taskConversation,
    prompt: 'watch the mail',
    loopMinutes: loopMinutes,
    maxRuns: maxRuns,
    runCount: runCount,
    state: state,
    createdAt: DateTime.utc(2026, 10, 9, 12),
  );
}

BackgroundRunSpec _spec({
  required ChatService chatService,
  required void Function(Message row) onPersist,
  required List<Message> seed,
  required String prompt,
  required List<ToolDefinition> toolDefs,
  Future<ToolExecutionResult> Function(String, Map<String, dynamic>)?
  toolExecutor,
  Future<bool> Function()? isCancelled,
}) {
  return BackgroundRunSpec(
    task: _task(),
    prompt: prompt,
    server: _remoteServer(),
    modelId: 'model',
    params: ChatParameters.defaults(),
    toolDefs: toolDefs,
    seedMessages: seed,
    chatService: chatService,
    toolExecutor: toolExecutor,
    persistRow: (row) async => onPersist(row),
    isCancelled: isCancelled ?? (() async => false),
  );
}

class _TurnResult {
  const _TurnResult({required this.content, required this.doneRequested});
  final String content;
  final bool doneRequested;
}

/// In-memory seams for [driveBackgroundTaskLoop], replacing the DB-backed
/// service the engine wires in production.
class _LoopHarness {
  _LoopHarness({required this.loopMinutes, required this.maxRuns});

  final int loopMinutes;
  final int maxRuns;

  final String taskId = 't-1';
  late BackgroundTask task = _task(
    loopMinutes: loopMinutes,
    maxRuns: maxRuns,
  );
  int turnCalls = 0;
  _TurnResult Function(int runNumber)? turnScript;
  BackgroundRunException? turnError;
  /// M7: when set, runTurn throws this (non-BackgroundRunException) error —
  /// the driver's crash-class catch must distinguish resumable crashes.
  Object? turnCrash;
  int? cancelAfterTurns;
  /// Lifecycle pause: when set, the relay-merged DB state reads `paused`
  /// after this many completed turns (the loop must park without finalize).
  int? pauseAfterTurns;
  bool conversationMissing = false;

  final recordedRuns = <String>[];
  final markedFailed = <String>[];
  final finalized = <(BackgroundTask, BackgroundRunResult)>[];
  final canceller = BackgroundRunCanceller();

  BackgroundLoopSeams seams() {
    return BackgroundLoopSeams(
      inspectRow: (id) async {
        if (cancelAfterTurns != null && turnCalls >= cancelAfterTurns!) {
          // The relay wrote the authoritative DB state between runs.
          task = _task(state: BackgroundTaskState.cancelled);
        }
        if (pauseAfterTurns != null && turnCalls >= pauseAfterTurns!) {
          // The pause relay wrote the authoritative DB state between runs.
          task = _task(state: BackgroundTaskState.paused);
        }
        return task;
      },
      conversationExists: (conversationId) async => !conversationMissing,
      recordRun: (id) async {
        recordedRuns.add(id);
        task = _task(
          loopMinutes: task.loopMinutes,
          maxRuns: task.maxRuns,
          runCount: task.runCount + 1,
        );
        return true;
      },
      markFinished: (id, {resultMessageId, ownerMessageId}) async => true,
      markFailed: (id) async {
        markedFailed.add(id);
        return true;
      },
      runTurn: (task) async {
        // count attempts (an erroring turn still burned its slot)
        final runNumber = ++turnCalls;
        final crash = turnCrash;
        if (crash != null) throw crash;
        final error = turnError;
        if (error != null) throw error;
        final script = turnScript!(runNumber);
        return BackgroundRunResult(
          content: script.content,
          doneRequested: script.doneRequested,
        );
      },
      finalize: (task, result) async {
        finalized.add((task, result));
      },
      canceller: canceller,
      waitBetweenRuns: (task, delay) async {},
    );
  }
}
