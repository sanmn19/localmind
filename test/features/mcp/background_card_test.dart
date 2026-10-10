import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/theme/app_theme.dart';
import 'package:localmind/features/chat/data/background_task_service.dart';
import 'package:localmind/features/chat/data/models/background_task.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/mcp/views/mcp_tools_screen.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/l10n/app_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Task 3: the Background card on the MCP tools screen — settings toggle
// persistence, per-open-conversation task rows fed by
// BackgroundTasksService.tasksFor through backgroundTaskRowsProvider, the
// cancel button calling cancelTask, and the cap-note row.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<(ProviderContainer, _SpySettingsNotifier, _CardBgService)>
      pumpCardHarness(
    WidgetTester tester, {
    bool backgroundTasksEnabled = false,
    List<Conversation>? conversations,
    List<BackgroundTask>? tasks,
  }) async {
    final chatRows =
        conversations ?? [Conversation(id: 'owner-1', title: 'Owner Chat', createdAt: _fixture, updatedAt: _fixture)];
    // The test font draws every glyph a full em wide; give rows room.
    tester.view.physicalSize = const Size(700, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final spy = _SpySettingsNotifier(
      initialBackgroundTasks: backgroundTasksEnabled,
    );
    final service = _CardBgService(tasks ?? []);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        packageInfoProvider.overrideWith(
          (ref) async => PackageInfo(
            appName: 'LocalMind',
            packageName: 'test',
            version: '1.0.0',
            buildNumber: '1',
          ),
        ),
        settingsProvider.overrideWith(() => spy),
        availableToolsProvider.overrideWith((ref) => Future.value(const [])),
        conv.conversationsProvider.overrideWith(
          () => _CardConversations(chatRows),
        ),
        backgroundTasksServiceProvider.overrideWith((ref) => service),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadTheme(
          data: AppTheme.lightShadTheme,
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: McpToolsScreen()),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return (container, spy, service);
  }

  testWidgets('toggle flips backgroundTasksEnabled via the settings notifier',
      (tester) async {
    final (container, spy, service) = await pumpCardHarness(tester);
    await tester.pumpAndSettle();

    expect(find.text('Background tasks'), findsOneWidget);
    expect(spy.setBackgroundTasksEnabledCalls, isEmpty);
    expect(
      container.read(settingsProvider).backgroundTasksEnabled,
      isFalse,
    );

    await tester.tap(find.byKey(const Key('background_tasks_toggle')));
    await tester.pumpAndSettle();

    expect(spy.setBackgroundTasksEnabledCalls, contains(true));
    expect(
      container.read(settingsProvider).backgroundTasksEnabled,
      isTrue,
      reason: 'spy settings notifier must hold backgroundTasksEnabled: true',
    );
  });

  testWidgets('task rows render state chips with owner titles and the cancel '
      'button calls the service', (tester) async {
    final tasks = [
      _task('bg-live', prompt: 'watch the inbox',
          state: BackgroundTaskState.running),
      _task('bg-done', prompt: 'summarize the notes',
          state: BackgroundTaskState.finished),
    ];
    final (_, spy, service) = await pumpCardHarness(
      tester,
      backgroundTasksEnabled: true,
      tasks: tasks,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('background_task_row_bg-live')), findsOneWidget);
    expect(find.byKey(const Key('background_task_row_bg-done')), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Finished'), findsOneWidget);
    expect(find.text('watch the inbox'), findsOneWidget);
    expect(find.text('summarize the notes'), findsOneWidget);
    expect(find.text('Owner Chat'), findsNWidgets(2));
    expect(find.byKey(const Key('background_cancel_bg-live')), findsOneWidget);
    expect(find.byKey(const Key('background_cancel_bg-done')), findsOneWidget);
    expect(spy.setBackgroundTasksEnabledCalls, isEmpty);
    expect(service.cancelCalls, isEmpty);
    expect(find.text('Cancel task'), findsNothing,
        reason: 'tooltips do not render as text before hover');

    // Tapping cancel calls the service for the RUNNING row and the row
    // flips to cancelled on the next refresh.
    await tester.tap(find.byKey(const Key('background_cancel_bg-live')));
    await tester.pumpAndSettle();

    expect(service.cancelCalls, ['bg-live']);
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.byKey(const Key('background_task_row_bg-live')), findsOneWidget);
  });

  testWidgets('shows the empty label when no conversation owns tasks',
      (tester) async {
    await pumpCardHarness(tester);
    await tester.pumpAndSettle();

    expect(find.text('No background tasks yet.'), findsOneWidget);
    expect(find.byKey(const Key('background_tasks_toggle')), findsOneWidget);
  });

  testWidgets('the cap note row is always rendered', (tester) async {
    await pumpCardHarness(tester);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('At most 3'),
      findsOneWidget,
      reason: 'the cap note explains the 3-running limit up front',
    );
    expect(find.textContaining('10 minutes'), findsOneWidget);
  });
}

final DateTime _fixture = DateTime.utc(2026, 10, 9);

BackgroundTask _task(
  String id, {
  required BackgroundTaskState state,
  String owner = 'owner-1',
  String prompt = 'watch the inbox',
}) {
  return BackgroundTask(
    id: id,
    ownerConversationId: owner,
    taskConversationId: 'task-conv-$id',
    prompt: prompt,
    loopMinutes: 0,
    maxRuns: 10,
    state: state,
    createdAt: DateTime.utc(2026, 10, 9, 12),
  );
}

/// Card-facing fake over [BackgroundTasksService]: tasksFor answers from an
/// in-memory list; cancelTask records and flips the row so the invalidated
/// rows provider observes the cancelled state.
class _CardBgService extends Fake implements BackgroundTasksService {
  _CardBgService(this.tasks);

  final List<BackgroundTask> tasks;
  final cancelCalls = <String>[];

  @override
  Future<List<BackgroundTask>> tasksFor(String ownerConversationId) async {
    return tasks
        .where((t) => t.ownerConversationId == ownerConversationId)
        .toList();
  }

  @override
  Future<bool> cancelTask(String taskId) async {
    cancelCalls.add(taskId);
    for (var i = 0; i < tasks.length; i++) {
      if (tasks[i].id == taskId) {
        tasks[i] = tasks[i].copyTask(state: BackgroundTaskState.cancelled);
      }
    }
    return true;
  }
}

class _CardConversations extends conv.ConversationsNotifier {
  _CardConversations(this.rows);

  final List<Conversation> rows;

  @override
  Future<List<Conversation>> build() async => rows;
}

class _SpySettingsNotifier extends SettingsNotifier {
  _SpySettingsNotifier({this.initialBackgroundTasks = false});

  final bool initialBackgroundTasks;

  final setBackgroundTasksEnabledCalls = <bool>[];

  @override
  AppSettings build() =>
      AppSettings(backgroundTasksEnabled: initialBackgroundTasks);

  @override
  void setBackgroundTasksEnabled(bool value) {
    setBackgroundTasksEnabledCalls.add(value);
    super.setBackgroundTasksEnabled(value);
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
