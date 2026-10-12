import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Message;

import '../../../core/models/enums.dart';
import '../../../core/utils/uuid.dart';
import '../../servers/data/models/server.dart';
import 'background_runner.dart';
import 'background_task_service.dart' show bgMaxConcurrentTasks;
import 'chat_service.dart';
import 'models/background_task.dart';
import 'models/chat_parameters.dart';
import 'models/message.dart';
import 'tools/tool_definition.dart';

/// UI-isolate-resolved snapshot for background runs. Built ONCE per engine
/// activation (not per run — the value is the state the OWNING chat saw at
/// spawn; cheap re-resolve on engine (re)attach instead).
class BackgroundRunSnapshot {
  const BackgroundRunSnapshot({
    required this.server,
    required this.modelId,
    required this.params,
    required this.toolDefs,
  });

  final Server server;
  final String modelId;
  final ChatParameters params;
  final List<ToolDefinition> toolDefs;
}

/// Closure surface of the run engine — everything the engine touches arrives
/// resolved by the caller (production: riverpod wiring in tooling_providers;
/// tests: plain captures). No riverpod import here by design.
typedef BackgroundTaskById = Future<BackgroundTask?> Function(String taskId);
typedef BackgroundRunningTasks = Future<List<BackgroundTask>> Function();
typedef BackgroundRecordRun = Future<bool> Function(String taskId);
typedef BackgroundMarkFinished =
    Future<bool> Function(
      String taskId, {
      String? resultMessageId,
      String? ownerMessageId,
    });
typedef BackgroundMarkFailed = Future<bool> Function(String taskId);
typedef BackgroundConversationExists =
    Future<bool> Function(String conversationId);
typedef BackgroundConversationTitle =
    Future<String?> Function(String conversationId);
typedef BackgroundBuildSnapshot = Future<BackgroundRunSnapshot> Function();
typedef BackgroundLoadRows =
    Future<List<Message>> Function(String conversationId);
typedef BackgroundPersistRow = Future<void> Function(Message row);
typedef BackgroundExecuteTool =
    Future<ToolExecutionResult> Function(
      String toolName,
      Map<String, dynamic> arguments,
    );
typedef BackgroundChatServiceFor = ChatService Function(Server server);
typedef BackgroundNotifyResult =
    Future<void> Function(
      String ownerTitle,
      BackgroundTask task,
      String content,
    );

/// The background run engine (UI-side coordinator).
///
/// Owns the in-flight loop registry, the cancel wire (flag + live-stream
/// close), and the finalize contract (result row into the owner
/// conversation + anchor id bookkeeping + notification + UI touch). The
/// per-run generation/tool machinery lives in `background_runner.dart` and
/// does the actual work against injected services.
class BackgroundRunEngine {
  BackgroundRunEngine({
    required this.taskById,
    required this.runningTasks,
    required this.recordRun,
    required this.markFinished,
    required this.markFailed,
    required this.conversationExists,
    required this.conversationTitle,
    required this.buildRunSnapshot,
    required this.loadRows,
    required this.persistRow,
    required this.executeTool,
    required this.chatServiceFor,
    required this.notifyResult,
    this.onEngineTouched = _touchNone,
    this.onTurnObserved,
  });

  final BackgroundTaskById taskById;
  final BackgroundRunningTasks runningTasks;
  final BackgroundRecordRun recordRun;
  final BackgroundMarkFinished markFinished;
  final BackgroundMarkFailed markFailed;
  final BackgroundConversationExists conversationExists;
  final BackgroundConversationTitle conversationTitle;
  final BackgroundBuildSnapshot buildRunSnapshot;
  final BackgroundLoadRows loadRows;
  final BackgroundPersistRow persistRow;
  final BackgroundExecuteTool executeTool;
  final BackgroundChatServiceFor chatServiceFor;
  final BackgroundNotifyResult notifyResult;
  final void Function() onEngineTouched;
  final void Function(BackgroundTask task)? onTurnObserved;

  final BackgroundRunCanceller _canceller = BackgroundRunCanceller();
  final Map<String, Future<void>> _activeLoops = {};
  final Map<String, ChatService> _liveServices = {};
  bool _disposed = false;

  static void _touchNone() {}

  /// Schedules a task's run driver. Throws [StateError] when the app-wide
  /// engine cap is reached (mirrors createTask's guard so spawn failure via
  /// a saturated engine is a real error the tool render shows).
  void requestRun(String taskId) {
    if (_disposed) {
      throw StateError('The background run engine is disposed.');
    }
    if (_activeLoops.containsKey(taskId)) return;
    if (_activeLoops.length >= bgMaxConcurrentTasks) {
      throw StateError(
        'Background task concurrency cap reached ($bgMaxConcurrentTasks '
        'running); cancel one first.',
      );
    }
    final future = driveBackgroundTaskLoop(taskId, seams: _seams())
        .whenComplete(() {
      _activeLoops.remove(taskId);
    });
    _activeLoops[taskId] = future;
    onEngineTouched();
  }

  /// Schedules every still-running task (bootstrap/startup resume path).
  Future<void> resumePending() async {
    final pending = await runningTasks();
    for (final task in pending.take(bgMaxConcurrentTasks)) {
      requestRun(task.id);
    }
  }

  /// Turn off the live run for [taskId]: flag + close its stream if in
  /// flight. The DB state flip is BackgroundTasksService.cancelTask's job.
  void cancelRunsFor(String taskId) {
    _canceller.request(taskId);
    _liveServices[taskId]?.cancelStream();
  }

  /// Resolves when every scheduled driver settles.
  Future<void> waitForIdle() => Future.wait(List.of(_activeLoops.values));

  void cancelAll() {
    for (final taskId in List.of(_activeLoops.keys)) {
      cancelRunsFor(taskId);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelAll();
  }

  BackgroundLoopSeams _seams() {
    return BackgroundLoopSeams(
      inspectRow: taskById,
      conversationExists: conversationExists,
      recordRun: (id) async {
        final ok = await recordRun(id);
        onEngineTouched();
        return ok;
      },
      markFinished: (id, {resultMessageId, ownerMessageId}) async {
        final ok = await markFinished(
          id,
          resultMessageId: resultMessageId,
          ownerMessageId: ownerMessageId,
        );
        onEngineTouched();
        return ok;
      },
      markFailed: (id) async {
        final ok = await markFailed(id);
        onEngineTouched();
        return ok;
      },
      runTurn: _runTurn,
      finalize: _finalizeFinished,
      waitBetweenRuns: (task, delay) =>
          _canceller.sleep(task.id, delay),
      canceller: _canceller,
    );
  }

  Future<BackgroundRunResult> _runTurn(BackgroundTask task) async {
    onTurnObserved?.call(task);
    final snapshot = await buildRunSnapshot();
    final rows = await loadRows(task.taskConversationId);
    final chatService = chatServiceFor(snapshot.server);
    _liveServices[task.id] = chatService;
    try {
      return await runBackgroundTurn(
        BackgroundRunSpec(
          task: task,
          prompt: task.prompt,
          server: snapshot.server,
          modelId: snapshot.modelId,
          params: snapshot.params,
          toolDefs: snapshot.toolDefs,
          seedMessages: rows,
          chatService: chatService,
          toolExecutor: executeTool,
          persistRow: persistRow,
          isCancelled: () async => _canceller.isRequested(task.id),
          cancelWatch: () => _canceller.watch(task.id),
        ),
      );
    } finally {
      _liveServices.remove(task.id);
    }
  }

  Future<void> _finalizeFinished(
    BackgroundTask task,
    BackgroundRunResult result,
  ) async {
    final ownerRow = Message(
      id: generateUuidV4(),
      conversationId: task.ownerConversationId,
      role: MessageRole.assistant,
      content: bgResultRowContent(task.id, result.content),
      createdAt: DateTime.now(),
      status: MessageStatus.complete,
      isActiveVariant: true,
    );
    await persistRow(ownerRow);
    await markFinished(
      task.id,
      resultMessageId: ownerRow.id,
      ownerMessageId: result.finalAssistantMessageId,
    );
    final ownerTitle = await conversationTitle(task.ownerConversationId);
    await notifyResult(ownerTitle ?? '', task, result.content);
    onEngineTouched();
  }
}

/// Channel ids for background-task notifications (results + quiet foreground
/// keep-alive).
const bgResultsChannelId = 'localmind_bg_tasks';
const localmindFgServiceChannelId = 'localmind_fg_service';

/// Posts result notifications through flutter_local_notifications with the
/// quiet channel contract (silent channels — looping tasks post often).
class BackgroundResultNotifier {
  final FlutterLocalNotificationsPlugin _plugin;

  BackgroundResultNotifier({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  Future<void> _initialize() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        bgResultsChannelId,
        'Background task results',
        description: 'LocalMind background sub-agent task results.',
        playSound: false,
        enableVibration: false,
      ),
    );
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        localmindFgServiceChannelId,
        'LocalMind background service',
        playSound: false,
        enableVibration: false,
      ),
    );
  }

  /// Posts the delivered result notification for a finished task.
  Future<void> post({
    required String ownerTitle,
    required BackgroundTask task,
    required String content,
  }) async {
    await _initialize();
    await _plugin.show(
      id: _notificationIdFor(task),
      title: ownerTitle,
      body: 'Background task result:\n$content',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          bgResultsChannelId,
          'Background task results',
          channelDescription: 'LocalMind background sub-agent task results.',
          playSound: false,
          enableVibration: false,
        ),
      ),
    );
  }

  int _notificationIdFor(BackgroundTask task) => task.id.hashCode & 0x7fffffff;
}
