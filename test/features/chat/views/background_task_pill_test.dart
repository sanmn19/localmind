import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/background_task_service.dart';
import 'package:localmind/features/chat/data/models/background_task.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/data/tools/tool_event.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/chat/views/components/background_task_pill.dart';
import 'package:localmind/features/chat/views/components/chat_bubble/tool_bubble/tool_timeline.dart';
import 'package:localmind/l10n/app_localizations.dart';

// Task 4: the inline background-task pill — ToolTimeline renders a compact
// pill row above the bg.spawn tool row for every task owned by the displayed
// conversation; the pill routes pause/resume/stop through the SAME
// backgroundTaskActionsProvider closures as the page/card rows, disables its
// buttons while an action is in flight, and disappears (seam + widget) once
// the service flips the task terminal.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('seam: pill renders above the bg.spawn tool row while running',
      (tester) async {
    final service = _FakeBgService([_task('t1')]);
    final harness = _PillHarness(service);
    await harness.pumpTimeline(tester, events: [_spawnEvent('t1')]);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('background_pill_t1')), findsOneWidget);
    expect(find.text('Background task'), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
    expect(find.textContaining('watch the inbox for new'), findsOneWidget);
    expect(find.byKey(const Key('background_pill_pause_t1')), findsOneWidget);
    expect(find.byKey(const Key('background_pill_stop_t1')), findsOneWidget);
    expect(
      find.byKey(const Key('background_pill_resume_t1')),
      findsNothing,
      reason: 'running exposes pause, not resume',
    );
  });

  testWidgets('seam: pill hidden for terminal tasks and omitted for '
      'bg.status rows even when their text mentions a task_id', (tester) async {
    final service = _FakeBgService([
      _task('t1', state: BackgroundTaskState.cancelled),
    ]);
    final harness = _PillHarness(service);
    await harness.pumpTimeline(
      tester,
      events: [
        _spawnEvent('t1'),
        _statusEvent('t1'),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('background_pill_t1')), findsNothing);
    expect(find.text('Background task'), findsNothing);
  });

  testWidgets('seam: pill hidden when the task belongs to another '
      'conversation', (tester) async {
    final service = _FakeBgService([
      _task('t1', owner: 'owner-2'),
    ]);
    final harness = _PillHarness(service);
    await harness.pumpTimeline(tester, events: [_spawnEvent('t1')]);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('background_pill_t1')), findsNothing);
  });

  testWidgets('widget: pill hidden while the task id is unknown', (tester) async {
    final harness = _PillHarness(_FakeBgService(const []));
    await harness.pumpPill(tester, taskId: 't1');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('background_pill_t1')), findsNothing);
  });

  testWidgets('widget: all pill buttons disable while an action is in flight',
      (tester) async {
    final gate = Completer<bool>();
    final harness = _PillHarness(
      _FakeBgService([_task('t1')]),
      extraOverrides: [
        backgroundTaskActionsProvider.overrideWith(
          (ref) => BackgroundTaskActions(
            pause: (_) => gate.future,
            resume: (_) async => false,
            stop: (_) async => false,
          ),
        ),
      ],
    );
    await harness.pumpPill(tester, taskId: 't1');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('background_pill_pause_t1')));
    await tester.pump();

    expect(
      _onPressed(find.byKey(const Key('background_pill_pause_t1')), tester),
      isNull,
      reason: 'pause disables itself while its request is in flight',
    );
    expect(
      _onPressed(find.byKey(const Key('background_pill_stop_t1')), tester),
      isNull,
      reason: 'stop disables while the row has an action in flight',
    );

    gate.complete(true);
    await tester.pumpAndSettle();
  });

  testWidgets('widget: pause routes through backgroundTaskActionsProvider and '
      'flips the rendered chip to Paused', (tester) async {
    final service = _FakeBgService([_task('t1')]);
    final harness = _PillHarness(service);
    await harness.pumpPill(tester, taskId: 't1');
    await tester.pumpAndSettle();
    expect(find.text('Running'), findsOneWidget);

    await tester.tap(find.byKey(const Key('background_pill_pause_t1')));
    await tester.pumpAndSettle();

    expect(service.pauseCalls, ['t1']);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Running'), findsNothing);
    expect(find.byKey(const Key('background_pill_resume_t1')), findsOneWidget);
    expect(find.byKey(const Key('background_pill_pause_t1')), findsNothing);
    expect(find.byKey(const Key('background_pill_stop_t1')), findsOneWidget);
  });

  testWidgets('widget: stop routes through the actions provider and the pill '
      'disappears once the terminal flip invalidates', (tester) async {
    final service = _FakeBgService([_task('t1')]);
    final harness = _PillHarness(service);
    await harness.pumpPill(tester, taskId: 't1');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('background_pill_stop_t1')));
    await tester.pumpAndSettle();

    expect(service.cancelCalls, ['t1']);
    expect(find.byKey(const Key('background_pill_t1')), findsNothing);
  });
}

dynamic _onPressed(Finder finder, WidgetTester tester) =>
    tester.widget<IconButton>(finder).onPressed;

DateTime get _fixture => DateTime.utc(2026, 10, 12);

BackgroundTask _task(
  String id, {
  BackgroundTaskState state = BackgroundTaskState.running,
  String owner = 'owner-1',
  String prompt = 'watch the inbox for new mail',
}) =>
    BackgroundTask(
      id: id,
      ownerConversationId: owner,
      taskConversationId: 'task-conv-$id',
      prompt: prompt,
      loopMinutes: 0,
      maxRuns: 10,
      runCount: 0,
      state: state,
      createdAt: _fixture,
    );

ToolEvent _spawnEvent(String taskId) => ToolEvent(
      eventId: 'evt-spawn-$taskId.0',
      timestamp: _fixture,
      status: ToolEventStatus.completed,
      toolName: 'bg.spawn',
      providerType: ToolProviderType.mcp,
      arguments: {
        'prompt': 'watch the inbox',
        'loop_minutes': 0,
        'max_runs': 3,
      },
      result: '{task_id: $taskId (single run, max 3)}',
    );

ToolEvent _statusEvent(String taskId) => ToolEvent(
      eventId: 'evt-status-$taskId.0',
      timestamp: _fixture,
      status: ToolEventStatus.completed,
      toolName: 'bg.status',
      providerType: ToolProviderType.mcp,
      result: '1. running: "watch the inbox"\n'
          '   task_id: $taskId — single run, 0/10 runs, not started',
    );

class _PillHarness {
  _PillHarness(this.service, {this.extraOverrides = const []});

  final _FakeBgService service;
  final List<dynamic> extraOverrides;

  Widget _scope({required Widget child}) => ProviderScope(
        overrides: [
          backgroundTasksServiceProvider.overrideWith((ref) => service),
          ...extraOverrides,
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        ),
      );

  Future<void> pumpTimeline(
    WidgetTester tester, {
    required List<ToolEvent> events,
    String viewedConversation = 'owner-1',
  }) async {
    await tester.pumpWidget(
      _scope(
        child: ToolTimeline(
          events: events,
          ownerConversationId: viewedConversation,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> pumpPill(
    WidgetTester tester, {
    required String taskId,
  }) async {
    await tester.pumpWidget(
      _scope(child: BackgroundTaskPill(taskId: taskId, owner: 'owner-1')),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Pill-facing fake over [BackgroundTasksService]: tasks answer from an
/// in-memory list; pause/resume/stop record and flip so the invalidated
/// backgroundPageTasksProvider observes the transitions.
class _FakeBgService extends Fake implements BackgroundTasksService {
  _FakeBgService(this.tasks);

  final List<BackgroundTask> tasks;
  final pauseCalls = <String>[];
  final resumeCalls = <String>[];
  final cancelCalls = <String>[];

  @override
  Future<List<BackgroundTask>> allTasks() async => List.of(tasks);

  @override
  Future<bool> pauseTask(String taskId) async {
    pauseCalls.add(taskId);
    _flip(taskId, BackgroundTaskState.paused);
    return true;
  }

  @override
  Future<bool> resumeTask(String taskId) async {
    resumeCalls.add(taskId);
    _flip(taskId, BackgroundTaskState.running);
    return true;
  }

  @override
  Future<bool> cancelTask(String taskId) async {
    cancelCalls.add(taskId);
    _flip(taskId, BackgroundTaskState.cancelled);
    return true;
  }

  void _flip(String taskId, BackgroundTaskState state) {
    for (var i = 0; i < tasks.length; i++) {
      if (tasks[i].id == taskId) {
        tasks[i] = tasks[i].copyTask(state: state);
      }
    }
  }
}

extension _BackgroundTaskCopy on BackgroundTask {
  BackgroundTask copyTask({required BackgroundTaskState state}) =>
      BackgroundTask(
        id: id,
        ownerConversationId: ownerConversationId,
        taskConversationId: taskConversationId,
        prompt: prompt,
        loopMinutes: loopMinutes,
        maxRuns: maxRuns,
        runCount: runCount,
        state: state,
        lastRunAt: lastRunAt,
        createdAt: createdAt,
        resultMessageId: resultMessageId,
        ownerMessageId: ownerMessageId,
      );
}
