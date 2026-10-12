import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as flutter_local_notifications;
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/chat/data/background_engine.dart';
import 'package:localmind/features/chat/data/chat_service.dart';
import 'package:localmind/features/chat/data/models/background_task.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/mcp_integration.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
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

  BackgroundTask buildEngineRow(String taskId) => BackgroundTask(
        id: taskId,
        ownerConversationId: 'owner-1',
        taskConversationId: 'task-c1',
        prompt: 'watch the mail',
        loopMinutes: 0,
        maxRuns: 10,
        state: BackgroundTaskState.running,
        createdAt: DateTime.utc(2026, 10, 9, 12),
      );

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
      buildRunSnapshot: () async => BackgroundRunSnapshot(
        server: _remoteServer(),
        modelId: 'model',
        params: ChatParameters.defaults(),
        toolDefs: const [],
      ),
      loadRows: (conversationId) async => persistedRows
          .where((row) => row.conversationId == conversationId)
          .toList(),
      persistRow: (row) async => persistedRows.add(row),
      executeTool: (name, args) async =>
          const ToolExecutionResult.failure('no executor in this test'),
      chatServiceFor: (server) => hangingChatService
          ? _HangingChatService()
          : _ScriptedChatService(),
      notifyResult: (ownerTitle, task, content) async {
        notified.add((
          ownerTitle: ownerTitle,
          task: task,
          content: content,
        ));
      },
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
