import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as flutter_local_notifications;
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/chat/data/background_engine.dart';
import 'package:localmind/features/chat/data/background_runner.dart'
    show bgRunnerSystemPrompt;
import 'package:localmind/features/chat/data/background_task_service.dart'
    show bgResumeNoticeContent;
import 'package:localmind/features/chat/data/chat_service.dart';
import 'package:localmind/features/chat/data/models/background_task.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/mcp_integration.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/utils/message_variants.dart';
import 'package:localmind/features/servers/data/models/server.dart';

// Task 4's engine wiring: the requester seam relays run requests with the
// task row's EXPLICIT ids (never an active-conversation read at run time),
// the cancel wire cancels the live loop, finishing appends the
// owner-conversation result row + posts the local notification (plugin
// method channel mocked), a saturated engine refuses further schedules the
// same way createTask does, and abort/dangling paths leave zero delivered
// rows.
//
// Every ObjectBox/riverpod-backed dependency arrives as a closure so the
// host toolchain never loads libobjectbox.so (probe convention documented in
// fork_service_test.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('requestRun relays the run with the row’s explicit ids', () async {
    final harness = _EngineHarness();
    final engine = harness.buildEngine();
    addTearDown(engine.dispose);

    engine.requestRun('t-1');
    await engine.waitForIdle();

    expect(harness.turnedTasks.single.id, 't-1');
    expect(harness.turnedTasks.single.ownerConversationId, 'owner-1');
    expect(harness.turnedTasks.single.taskConversationId, 'task-c1');
    expect(harness.ownerRows, hasLength(1));
    expect(harness.markedFinishedIds, ['t-1']);
  });

  test('cancel wire cancels the live loop — no finalize afterwards',
      () async {
    final harness = _EngineHarness();
    final engine = harness.buildEngine(hangingChatService: true);
    addTearDown(engine.dispose);

    engine.requestRun('t-1');
    engine.cancelRunsFor('t-1');
    await engine.waitForIdle();

    // The runner aborted the pending generation (stream cancelled, cancel
    // flag set); the authoritative poll had already seen the cancelled row,
    // so nothing finalizes: no owner row, no notification, no run count.
    expect(harness.turnedTasks, hasLength(1));
    expect(harness.recordedRuns, isEmpty);
    expect(harness.markedFinishedIds, isEmpty);
    expect(harness.ownerRows, isEmpty);
    expect(harness.notified, isEmpty);
  });

  test('a paused row parks the loop without finalize; a resumed requestRun '
      'starts clean past the stale pause-relay flag', () async {
    final harness = _EngineHarness();
    final engine = harness.buildEngine();
    addTearDown(engine.dispose);

    harness.forcedRowState = BackgroundTaskState.paused;
    engine.requestRun('t-1');
    await engine.waitForIdle();

    // The driver's authoritative poll sees paused and parks WITHOUT any
    // finalize/failure: no owner row, no notification, no run movement.
    expect(harness.turnedTasks, isEmpty);
    expect(harness.recordedRuns, isEmpty);
    expect(harness.markedFailedIds, isEmpty);
    expect(harness.markedFinishedIds, isEmpty);
    expect(harness.ownerRows, isEmpty);
    expect(harness.notified, isEmpty);

    // RESUME: the service flipped the row back to running; the bridge
    // enqueues engine.requestRun. The pause relay FLAGGED the canceller
    // earlier in the pause path — the fresh loop must start with a clean
    // cancel state, or it would abort before its first turn.
    engine.cancelRunsFor('t-1'); // stale pause-relay flag
    harness.forcedRowState = BackgroundTaskState.running;
    engine.requestRun('t-1');
    await engine.waitForIdle();

    expect(harness.turnedTasks, hasLength(1));
    expect(harness.turnedTasks.single.state, BackgroundTaskState.running);
    expect(harness.markedFinishedIds, ['t-1']);
    expect(harness.ownerRows, hasLength(1));
  });

  test('a LIVE looping task parks subsecond when the pause relay fires '
      'mid-stream; a resumed enqueue lands fresh', () async {
    final harness = _EngineHarness();
    final engine = harness.buildEngine(hangingChatService: true);
    addTearDown(engine.dispose);
    harness.rowLoopMinutes = 10; // LIVE looping task, run 1 in flight.

    engine.requestRun('t-1');
    expect(
      engine.requestRun('t-1'),
      isFalse,
      reason: 'the registry still holds the live loop — bool pin',
    );

    // pauseTask order: the relay wakes the live stream FIRST, the flip
    // makes the authoritative row paused (relayed + flipped mid-run).
    engine.cancelRunsFor('t-1');
    harness.forcedRowState = BackgroundTaskState.paused;
    final watch = Stopwatch()..start();
    await engine.waitForIdle().timeout(const Duration(seconds: 3));
    watch.stop();

    // Subsecond removal pin (Task-1 review #1): the parked loop's future
    // leaves the registry within a second — this is exactly what makes a
    // resumed requestRun no longer no-op.
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(harness.turnedTasks, hasLength(1));
    expect(harness.recordedRuns, isEmpty);
    expect(harness.markedFinishedIds, isEmpty);
    expect(harness.ownerRows, isEmpty);
    expect(harness.notified, isEmpty);

    // RESUME: the service flipped the row back to running; the fresh
    // enqueue must LAND (the registry entry is gone).
    harness.forcedRowState = BackgroundTaskState.running;
    harness.rowLoopMinutes = 0; // resumed leg: single-run shape
    harness.hangingRuns = 0; // the resumed run completes its stream
    expect(engine.requestRun('t-1'), isTrue);
    await engine.waitForIdle().timeout(const Duration(seconds: 3));

    expect(harness.turnedTasks, hasLength(2));
    expect(harness.markedFinishedIds, ['t-1']);
    expect(harness.ownerRows, hasLength(1));
  });

  test('a resumed run\'s wire carries the paused + resumed notice rows in '
      'order before the run prompt (loadRows closure capture pin, '
      'Task-1 review #3)', () async {
    final harness = _EngineHarness();
    final engine = harness.buildEngine();
    addTearDown(engine.dispose);

    // The hidden task thread exactly as the pause/resume notices left it:
    // two USER-role rows injected by the noticeSink, riding every resumed
    // run's context (the child must see its own pause history).
    harness.persistedRows.addAll([
      Message(
        id: 'a-earlier',
        conversationId: 'task-c1',
        role: MessageRole.assistant,
        content: 'Watching.',
        createdAt: DateTime.utc(2026, 10, 12, 9),
        status: MessageStatus.complete,
        isActiveVariant: true,
        threadOrder: 1,
      ),
      Message(
        id: 'n-paused',
        conversationId: 'task-c1',
        role: MessageRole.user,
        content: 'Background task paused by user at 09:55',
        createdAt: DateTime.utc(2026, 10, 12, 9, 55),
        status: MessageStatus.complete,
        isActiveVariant: true,
        threadOrder: 2,
      ),
      Message(
        id: 'n-resumed',
        conversationId: 'task-c1',
        role: MessageRole.user,
        content: bgResumeNoticeContent,
        createdAt: DateTime.utc(2026, 10, 12, 9, 58),
        status: MessageStatus.complete,
        isActiveVariant: true,
        threadOrder: 3,
      ),
    ]);

    engine.requestRun('t-1');
    await engine.waitForIdle();

    final wire = harness.chatServices.single.requests.single;
    expect(wire, hasLength(5), reason: 'system + 3 task rows + run prompt');
    expect(
      wire.map((row) => row.content).toList(),
      [
        bgRunnerSystemPrompt,
        'Watching.',
        'Background task paused by user at 09:55',
        bgResumeNoticeContent,
        'watch the mail', // the run prompt row, ALWAYS last.
      ],
    );
  });

  test('finish appends the owner row, stores ids, posts the notification',
      () async {
    final harness = _EngineHarness();
    final engine = harness.buildEngine();
    addTearDown(engine.dispose);

    engine.requestRun('t-1');
    await engine.waitForIdle();

    // Owner row format contract: `Background task result (<taskId>): <text>`.
    final row = harness.ownerRows.single;
    expect(row.conversationId, 'owner-1');
    expect(row.role, MessageRole.assistant);
    expect(row.content, 'Background task result (t-1): watched!');
    expect(shouldIncludeMessageInChatContext(row), isTrue);

    // The anchor row carries both ids: resultMessageId = the owner result
    // row, ownerMessageId = the task conversation's final assistant row.
    expect(harness.finishedIds.single.taskId, 't-1');
    expect(harness.finishedIds.single.resultMessageId, row.id);
    final taskAssistantRows = harness.persistedRows
        .where(
          (r) =>
              r.conversationId == 'task-c1' &&
              r.role == MessageRole.assistant,
        )
        .toList();
    expect(taskAssistantRows, isNotEmpty);
    expect(
      harness.finishedIds.single.ownerMessageId,
      taskAssistantRows.last.id,
    );

    // Notification: titled with the OWNER conversation, body the final text.
    expect(harness.notified.single.ownerTitle, 'Owner Chat');
    expect(harness.notified.single.content, 'watched!');
  });

  test('requestRun beyond the engine cap throws (propagates as spawn '
      'failure), mirroring createTask', () {
    final harness = _EngineHarness();
    final engine = harness.buildEngine(hangingChatService: true);
    addTearDown(engine.dispose);

    engine.requestRun('t-1');
    engine.requestRun('t-2');
    engine.requestRun('t-3');
    expect(
      () => engine.requestRun('t-4'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('concurrency cap reached (3'),
        ),
      ),
    );
  });

  test('a vanished task conversation marks the task failed, never runs',
      () async {
    final harness = _EngineHarness();
    harness.existsByConversation = (_) async => false;
    final engine = harness.buildEngine();
    addTearDown(engine.dispose);

    engine.requestRun('t-1');
    await engine.waitForIdle();

    expect(harness.turnedTasks, isEmpty);
    expect(harness.markedFailedIds, ['t-1']);
    expect(harness.ownerRows, isEmpty);
    expect(harness.notified, isEmpty);
  });

  test('a no-ready-model StateError stays RUNNING, resumable (M7)', () async {
    final harness = _EngineHarness();
    harness.snapshotError =
        StateError('No ready model target for background sub-agent runs.');
    final engine = harness.buildEngine();
    addTearDown(engine.dispose);

    engine.requestRun('t-1');
    await engine.waitForIdle();

    // One turn attempt, then the driver returns WITHOUT markFailed: the row
    // keeps its running state so a later engine pass resumes it.
    expect(harness.turnedTasks, hasLength(1));
    expect(harness.markedFailedIds, isEmpty);
    expect(harness.recordedRuns, isEmpty);
    expect(harness.markedFinishedIds, isEmpty);
    expect(harness.ownerRows, isEmpty);
    expect(harness.notified, isEmpty);
  });

  test('BgNotificationPayload parses our tap payloads only', () {
    expect(BgNotificationPayload.tryParse('bg-task-result|owner-1'), 'owner-1');
    expect(
      BgNotificationPayload.tryParse('bg-task-result|c-with|pipe?'),
      'c-with|pipe?',
      reason: 'everything after the prefix is the id token',
    );
    expect(BgNotificationPayload.tryParse(null), isNull);
    expect(BgNotificationPayload.tryParse(''), isNull);
    expect(BgNotificationPayload.tryParse('other-source|owner-1'), isNull);
    expect(BgNotificationPayload.tryParse('bg-task-result|'), isNull);
    expect(
      BgNotificationPayload.compose('owner-1'),
      'bg-task-result|owner-1',
    );
  });

  test('bgResultNotificationId is stable and stays in the 31-bit range',
      () {
    final task = _task();
    final first = bgResultNotificationId(task);
    // Stability pin: same task id → same notification slot, so an updated
    // result re-addresses the same notification instead of stacking a new one.
    expect(first, bgResultNotificationId(task));
    expect(first, greaterThanOrEqualTo(0));
    expect(first, lessThanOrEqualTo(0x7fffffff));
  });

  test('owner result row anchors onto the active timeline tail '
      '(C1: live + reopened render)', () async {
    final harness = _EngineHarness()
      ..ownerSeedRows = [
        Message(
          id: 'u-1',
          conversationId: 'owner-1',
          role: MessageRole.user,
          content: 'watch the mail',
          createdAt: DateTime.utc(2026, 10, 9, 12),
          status: MessageStatus.complete,
          threadOrder: 0,
        ),
        Message(
          id: 'a-1',
          conversationId: 'owner-1',
          role: MessageRole.assistant,
          content: 'mail is quiet',
          createdAt: DateTime.utc(2026, 10, 9, 12, 1),
          status: MessageStatus.complete,
          threadOrder: 1,
          // A real persisted row keeps its ancestor: proper agent-linked
          // timeline [user → assistant], NOT a second independent root.
          parentMessageId: 'u-1',
        ),
      ];
    final engine = harness.buildEngine();
    addTearDown(engine.dispose);

    engine.requestRun('t-1');
    await engine.waitForIdle();

    final bgRow = harness.ownerRows.single;
    // Anchored onto the resolved tail, not an independent root.
    expect(bgRow.parentMessageId, 'a-1');
    expect(bgRow.threadOrder, 2);
    expect(bgRow.isActiveVariant, isTrue);
    expect(bgRow.status, MessageStatus.complete);

    // LIVE semantics: the real resolver renders the seeded timeline with the
    // background result row LAST.
    final live = MessageVariants.resolveActiveTimeline(
      [...harness.ownerSeedRows, bgRow],
    );
    expect(live.first.id, 'u-1');
    expect(live[1].id, 'a-1');
    expect(live.last.id, bgRow.id);

    // REOPENED semantics: re-resolving the full persisted picture (row
    // already in the store, parent chain read back from the DB) resolves to
    // the identical timeline ending on the result row.
    final reopened = MessageVariants.resolveActiveTimeline([
      ...harness.ownerSeedRows,
      Message(
        id: bgRow.id,
        conversationId: bgRow.conversationId,
        role: bgRow.role,
        content: bgRow.content,
        createdAt: bgRow.createdAt,
        status: bgRow.status,
        isActiveVariant: true,
        parentMessageId: bgRow.parentMessageId,
        threadOrder: bgRow.threadOrder,
      ),
    ]);
    expect(reopened.last.id, bgRow.id);

    // The anchor row id the task commits is the row that renders last.
    expect(harness.finishedIds.single.resultMessageId, bgRow.id);
  });

  test('owner row on an empty timeline is a root at order 0 (C1 edge)',
      () async {
    final harness = _EngineHarness();
    final engine = harness.buildEngine();
    addTearDown(engine.dispose);

    engine.requestRun('t-1');
    await engine.waitForIdle();

    final bgRow = harness.ownerRows.single;
    expect(bgRow.parentMessageId, isNull);
    expect(bgRow.threadOrder, 0);
    final timeline = MessageVariants.resolveActiveTimeline([bgRow]);
    expect(timeline.single.id, bgRow.id);
  });

  test('BackgroundResultNotifier posts via flutter_local_notifications '
      '(mocked plugin channel)', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final calls = <MethodCall>[];
    // Host-test registration: the app's generated plugin registrant is not
    // part of a bare flutter_test harness, so point the platform interface
    // at the method-channel implementation the mock below intercepts.
    flutter_local_notifications.FlutterLocalNotificationsPlatform.instance =
        flutter_local_notifications.AndroidFlutterLocalNotificationsPlugin();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async {
        calls.add(call);
        return true;
      },
    );

    final notifier = BackgroundResultNotifier();
    await notifier.post(
      ownerTitle: 'Owner Chat',
      task: _task(),
      content: 'the summer is over',
    );

    final show = calls.where((call) => call.method == 'show').single;
    expect(show.arguments['title'], 'Owner Chat');
    expect(show.arguments['body'], contains('the summer is over'));
    // Tap routing payload (review I3): 'bg-task-result|<ownerConversationId>'.
    expect(show.arguments['payload'], 'bg-task-result|owner-1');

    // Channel creation: the results channel runs silent-enough (no sound,
    // no vibration); the quiet foreground channel comes along for the
    // keep-alive StatusBar notification.
    final channelCalls = calls
        .where((call) => call.method == 'createNotificationChannel')
        .toList();
    final channels =
        channelCalls.map((call) => call.arguments['id'] as String).toList();
    expect(channels, contains('localmind_bg_tasks'));
    final resultsChannel = channelCalls.firstWhere(
      (call) => call.arguments['id'] == 'localmind_bg_tasks',
    );
    expect(resultsChannel.arguments['playSound'], isFalse);
    expect(resultsChannel.arguments['enableVibration'], isFalse);
    expect(channels, contains('localmind_fg_service'));
  });
}

// ---------------------------------------------------------------------------
// Engine fakes
// ---------------------------------------------------------------------------

class _EngineHarness {
  // Run records — snapshots of what the engine wrote through its seams.
  final List<BackgroundTask> turnedTasks = [];

  /// Rows the engine wrote into the OWNER conversation.
  List<Message> get ownerRows =>
      persistedRows
          .where(
            (row) =>
                row.conversationId == 'owner-1' &&
                row.role == MessageRole.assistant,
          )
          .toList();

  final List<String> recordedRuns = [];
  final List<String> markedFinishedIds = [];
  final List<String> markedFailedIds = [];
  final List<({
    String taskId,
    String? resultMessageId,
    String? ownerMessageId,
  })>
      finishedIds = [];
  final List<({String ownerTitle, BackgroundTask task, String content})>
      notified = [];
  final List<Message> persistedRows = [];

  Future<bool> Function(String conversationId)? existsByConversation;

  /// M7: when set, buildRunSnapshot throws this error (StateError shape for
  /// the no-ready-model case).
  Object? snapshotError;

  /// Lifecycle pause: forces every inspectRow hit to report this state.
  BackgroundTaskState? forcedRowState;

  /// The authoritative row's loop shape (mutable mid-test: the pause-abort
  /// test parks a LOOPING live row, then resumes a single-run fresh leg).
  int rowLoopMinutes = 0;

  /// Every [ChatService] the engine built for a run (wire capture seams).
  final List<_ScriptedChatService> chatServices = [];

  /// With [buildEngine]'s `hangingChatService`, runs consume this budget;
  /// null (default) means every run hangs. The pause/resume test spends the
  /// budget on run 1 so the resumed leg completes its scripted run.
  int? hangingRuns;

  BackgroundTask buildEngineRow(String taskId) => BackgroundTask(
        id: taskId,
        ownerConversationId: 'owner-1',
        taskConversationId: 'task-c1',
        prompt: 'watch the mail',
        loopMinutes: rowLoopMinutes,
        maxRuns: 10,
        state: forcedRowState ?? BackgroundTaskState.running,
        createdAt: DateTime.utc(2026, 10, 9, 12),
      );

  /// Seeded owner-conversation rows the resolver reads (stands in for the
  /// DB rows the production wiring loads via _backgroundRows).
  List<Message> ownerSeedRows = [];

  /// Engine seam wiring for the C1 owner-row contract: runs the REAL
  /// [MessageVariants.resolveActiveTimeline] over the persisted owner rows —
  /// exactly the logic the production _ownerTimelineTail helper uses.
  Future<({String? parentMessageId, int nextThreadOrder})>
      resolveOwnerTail(String ownerConversationId) async {
    final rows = [
      ...ownerSeedRows,
      ...persistedRows.where((row) => row.conversationId == ownerConversationId),
    ];
    final timeline = MessageVariants.resolveActiveTimeline(rows);
    final nextThreadOrder = rows.isEmpty
        ? 0
        : rows.map((row) => row.threadOrder).reduce((a, b) => a > b ? a : b) + 1;
    return (
      parentMessageId: timeline.isEmpty ? null : timeline.last.id,
      nextThreadOrder: nextThreadOrder,
    );
  }

  BackgroundRunEngine buildEngine({bool hangingChatService = false}) {
    return BackgroundRunEngine(
      taskById: (taskId) async =>
          taskId.startsWith('t-') ? buildEngineRow(taskId) : null,
      runningTasks: () async => [
        buildEngineRow('t-1'),
        buildEngineRow('t-2'),
      ],
      recordRun: (taskId) async {
        recordedRuns.add(taskId);
        return true;
      },
      markFinished: (taskId, {resultMessageId, ownerMessageId}) async {
        markedFinishedIds.add(taskId);
        finishedIds.add((
          taskId: taskId,
          resultMessageId: resultMessageId,
          ownerMessageId: ownerMessageId,
        ));
        return true;
      },
      markFailed: (taskId) async {
        markedFailedIds.add(taskId);
        return true;
      },
      conversationExists:
          existsByConversation ??
          (conversationId) async =>
              conversationId == 'task-c1' || conversationId == 'owner-1',
      conversationTitle: (conversationId) async =>
          conversationId == 'owner-1' ? 'Owner Chat' : null,
      buildRunSnapshot: () async {
        final error = snapshotError;
        if (error != null) throw error;
        return BackgroundRunSnapshot(
          server: _remoteServer(),
          modelId: 'model',
          params: ChatParameters.defaults(),
          toolDefs: const [],
        );
      },
      loadRows: (conversationId) async => persistedRows
          .where((row) => row.conversationId == conversationId)
          .toList(),
      persistRow: (row) async => persistedRows.add(row),
      executeTool: (name, args) async =>
          const ToolExecutionResult.failure('no executor in this test'),
      chatServiceFor: (server) {
        if (hangingChatService && hangingRuns != 0) {
          hangingRuns = hangingRuns! - 1;
          return _HangingChatService();
        }
        final service = _ScriptedChatService();
        chatServices.add(service);
        return service;
      },
      notifyResult: (ownerTitle, task, content) async {
        notified.add((
          ownerTitle: ownerTitle,
          task: task,
          content: content,
        ));
      },
      ownerTailResolver: resolveOwnerTail,
      onEngineTouched: () {},
      onTurnObserved: turnedTasks.add,
    );
  }
}

/// Never yields on its own; closing via [cancelStream] ends the stream —
/// mirrors how the engine's cancel relay turns the wire off mid-generation.
class _HangingChatService implements ChatService {
  StreamController<ChatResponse>? _controller;

  @override
  Stream<ChatResponse> sendMessage({
    required Server server,
    required String modelId,
    required List<Message> messages,
    required ChatParameters params,
    List<McpIntegration>? integrations,
    List<ToolDefinition>? tools,
    bool continueGeneration = false,
  }) {
    _controller = StreamController<ChatResponse>();
    return _controller!.stream;
  }

  @override
  void cancelStream() {
    unawaited(_controller?.close());
  }
}

class _ScriptedChatService implements ChatService {
  /// Per-request wire capture (the resumed-run history pin reads these).
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
    yield const ChatResponse(type: ChatResponseType.message);
    yield const ChatResponse(
      type: ChatResponseType.message,
      content: 'watched!',
    );
    yield const ChatResponse(type: ChatResponseType.done);
  }

  @override
  void cancelStream() {}
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

BackgroundTask _task() => BackgroundTask(
      id: 't-1',
      ownerConversationId: 'owner-1',
      taskConversationId: 'task-c1',
      prompt: 'watch the mail',
      loopMinutes: 0,
      maxRuns: 10,
      state: BackgroundTaskState.running,
      createdAt: DateTime.utc(2026, 10, 9, 12),
    );
