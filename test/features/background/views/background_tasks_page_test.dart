import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/features/models/data/models/model_info.dart';
import 'package:localmind/core/theme/app_theme.dart';
import 'package:localmind/features/background/views/background_tasks_page.dart';
import 'package:localmind/features/chat/data/background_engine.dart';
import 'package:localmind/features/chat/data/background_task_service.dart';
import 'package:localmind/features/chat/data/models/background_task.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/chat/views/components/top_bar/screen_app_bar.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/servers/providers/server_providers.dart'
    as server_providers;
import 'package:localmind/features/chat/providers/model_selection_providers.dart';
import 'package:localmind/l10n/app_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Task 3: the standalone Background tasks page — sections grouped per
/// owner chat in owner-spawn order, pause/resume/stop wired through
/// `backgroundTaskActionsProvider`, the focus param scroll + highlight
/// pulse, the empty state, and the chat top-bar triple-dot menu entry
/// deep-linking `/background?focus=<conversation id>`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('page', () {
    testWidgets('renders sections grouped per owner in owner-spawn order',
        (tester) async {
      // owner-2's task spawned first, so its section must lead.
      final tasks = [
        _task('bg-a', owner: 'owner-2', prompt: 'patrol the mail'),
        _task('bg-b', owner: 'owner-1', prompt: 'summarize the notes'),
        _task('bg-c', owner: 'owner-2', prompt: 'watch the inbox'),
      ];
      await pumpPage(
        tester,
        tasks: tasks,
        conversations: _owners([
          'owner-1',
          'owner-2',
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('background_section_owner-2')),
          findsOneWidget);
      expect(find.byKey(const Key('background_section_owner-1')),
          findsOneWidget);
      expect(find.text('Owner Two'), findsOneWidget);
      expect(find.text('Owner One'), findsOneWidget);
      expect(find.text('patrol the mail'), findsOneWidget);
      expect(find.text('summarize the notes'), findsOneWidget);
      expect(find.text('watch the inbox'), findsOneWidget);

      // Grouped: bg-a lives INSIDE the owner-2 section, bg-b does not.
      final ownerTwo = find.byKey(const Key('background_section_owner-2'));
      expect(
        find.descendant(of: ownerTwo, matching: find.text('patrol the mail')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: ownerTwo, matching: find.text('watch the inbox')),
        findsOneWidget,
      );
      expect(
        find
            .descendant(of: ownerTwo, matching: find.text('summarize the notes')),
        findsNothing,
      );

      // Owner-spawn order: owner-2's section renders above owner-1's.
      expect(
        tester.getTopLeft(find.byKey(const Key('background_section_owner-2'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const Key('background_section_owner-1'))).dy,
        ),
      );
    });

    testWidgets('rows show runs count, single-run marker and last-run stamp',
        (tester) async {
      final tasks = [
        _task('bg-loop',
            loopMinutes: 15, runCount: 2, lastRunAt: DateTime.now()),
        _task('bg-single'),
      ];
      await pumpPage(tester, tasks: tasks);
      await tester.pumpAndSettle();

      expect(find.text('2/10'), findsOneWidget);
      expect(find.text('single run'), findsOneWidget);
      expect(find.textContaining('just now'), findsOneWidget);
      expect(find.text('not run yet'), findsOneWidget);
    });

    testWidgets('long prompts excerpt to 64 flattened chars with an ellipsis',
        (tester) async {
      final longPrompt =
          'watch   the inbox every   fifteen minutes and summarize '
          'everything that piled up overnight into one digest';
      await pumpPage(tester, tasks: [_task('bg-long', prompt: longPrompt)]);
      await tester.pumpAndSettle();

      final excerpt = tester
          .widget<Text>(find.byKey(const Key('background_row_text_bg-long')))
          .data;
      expect(excerpt, endsWith('…'));
      expect(excerpt!.length, 65, reason: '64 chars + the ellipsis');
      expect(excerpt, contains('watch the inbox'),
          reason: 'runs of whitespace flatten to single spaces');
    });

    testWidgets('unknown owner falls back to the deleted-chat header',
        (tester) async {
      final tasks = [_task('bg-orphan', owner: 'gone-chat')];
      await pumpPage(tester, tasks: tasks, conversations: const []);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('background_section_gone-chat')),
        findsOneWidget,
      );
      expect(find.text('Deleted chat'), findsOneWidget);
    });

    testWidgets('shows the empty state when no tasks exist', (tester) async {
      await pumpPage(tester, tasks: const []);
      await tester.pumpAndSettle();

      expect(find.text('No background tasks yet.'), findsOneWidget);
    });

    testWidgets('pause/resume/stop wire through the actions provider',
        (tester) async {
      final (service, _) = await pumpPage(tester, tasks: [
        _task('bg-live', state: BackgroundTaskState.running),
      ]);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('background_pause_bg-live')), findsOneWidget);
      expect(find.byKey(const Key('background_stop_bg-live')), findsOneWidget);
      expect(find.byKey(const Key('background_resume_bg-live')), findsNothing,
          reason: 'resume only applies to paused rows');

      await tester.tap(find.byKey(const Key('background_pause_bg-live')));
      await tester.pumpAndSettle();

      expect(service.pauseCalls, ['bg-live']);
      expect(service.resumeCalls, isEmpty);
      expect(find.text('Paused'), findsOneWidget,
          reason: 'the invalidated provider re-reads the flipped row');

      await tester.tap(find.byKey(const Key('background_resume_bg-live')));
      await tester.pumpAndSettle();

      expect(service.resumeCalls, ['bg-live']);
      expect(find.text('Running'), findsOneWidget,
          reason: 'resume flips back to running after the refresh');

      await tester.pump(500.milliseconds);
      await tester.tap(find.byKey(const Key('background_stop_bg-live')));
      await tester.pumpAndSettle();

      expect(service.cancelCalls, ['bg-live']);
      expect(find.text('Cancelled'), findsOneWidget);
    });

    testWidgets('row buttons disable while an action is pending',
        (tester) async {
      final (service, _) = await pumpPage(tester, tasks: [
        _task('bg-live', state: BackgroundTaskState.running),
      ]);
      await tester.pumpAndSettle();

      // Hold the pause seam open: the row stays pending until released.
      final gate = service.holdPause();
      await tester.tap(find.byKey(const Key('background_pause_bg-live')));
      await tester.pump(50.milliseconds);
      expect(service.pauseCalls, ['bg-live']);

      // Disabled while pending: a second frantic tap must land nothing.
      await tester.tap(
        find.byKey(const Key('background_stop_bg-live')),
        warnIfMissed: false,
      );
      await tester.pump(50.milliseconds);
      expect(service.cancelCalls, isEmpty,
          reason: 'a pending row must not accept another action');

      // Release and settle — the pause commits and drains pending.
      gate.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('Paused'), findsOneWidget);
      expect(
        find.byKey(const Key('background_resume_bg-live')),
        findsOneWidget,
        reason: 're-enabled after the pending window closes',
      );
    });

    testWidgets('focus scrolls the owner section and pulses the highlight',
        (tester) async {
      final tasks = [
        for (var i = 1; i <= 8; i++)
          _task('bg-$i', owner: 'owner-$i', prompt: 'prompt $i'),
      ];
      final (_, highlightOpacity) = await pumpPage(
        tester,
        tasks: tasks,
        conversations:
            _owners([for (var i = 1; i <= 8; i++) 'owner-$i']),
        focus: 'owner-8',
        tallViewport: false,
      );
      // One frame with the data in: the scroll has not started yet.
      final dyBefore = tester
          .getTopLeft(find.byKey(const Key('background_section_owner-8')))
          .dy;
      expect(dyBefore, greaterThan(400),
          reason: 'the focused section must start below the fold');

      // Mid-scroll the highlight pulse is visible.
      await tester.pump(100.milliseconds);
      expect(highlightOpacity(), greaterThan(0.0));

      await tester.pumpAndSettle();

      final dyAfter = tester
          .getTopLeft(find.byKey(const Key('background_section_owner-8')))
          .dy;
      expect(dyAfter, lessThan(dyBefore));
      expect(dyAfter, lessThan(150),
          reason: 'ensureVisible lands the focused section at the fold');
      expect(highlightOpacity(), 0.0, reason: 'the 1.5s pulse fades back out');
    });

    testWidgets('an unknown focus owner is a no-op', (tester) async {
      final tasks = [
        for (var i = 1; i <= 8; i++)
          _task('bg-$i', owner: 'owner-$i', prompt: 'prompt $i'),
      ];
      await pumpPage(
        tester,
        tasks: tasks,
        conversations: _owners([for (var i = 1; i <= 8; i++) 'owner-$i']),
        focus: 'owner-gone',
        tallViewport: false,
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('background_section_owner-gone')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('background_focus_highlight')),
        findsNothing,
      );
      final dy = tester
          .getTopLeft(find.byKey(const Key('background_section_owner-1')))
          .dy;
      expect(dy, greaterThan(0), reason: 'no scroll of the focused kind');
    });
  });

  group('chat menu', () {
    testWidgets(
        'triple-dot menu has the Background tasks entry and deep-links the '
        'route with the active conversation id as focus', (tester) async {
      String? capturedFocusValue;
      String? capturedFocusGet() => capturedFocusValue;
      final router = _menuRouter(
        onPage: (focus) => capturedFocusValue = focus,
        child: BackgroundTasksPage,
      );

      _menuConversation = Conversation(
        id: 'conv-1',
        title: 'Conv One',
        createdAt: _fixture,
        updatedAt: _fixture,
      );
      final (service, _) = await _pumpMenuHarness(
        tester,
        router,
        pageOverrides: _pageOverrides(
          tasks: [_task('bg-menu', owner: 'conv-1', prompt: 'watch it')],
          conversations: _owners(['conv-1']),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('chat_more_menu')));
      await tester.pumpAndSettle();

      expect(find.text('Background tasks'), findsOneWidget);

      await tester.tap(find.text('Background tasks'));
      await tester.pumpAndSettle();

      expect(capturedFocusGet(), 'conv-1');
      expect(find.text('watch it'), findsOneWidget,
          reason: 'the page mounts with the focus param routed through');
      expect(
        find.byKey(const Key('background_section_conv-1')),
        findsOneWidget,
      );
      expect(service.pauseCalls, isEmpty);
    });

    testWidgets(
        'the menu pushes without a focus param when no conversation is open',
        (tester) async {
      String? capturedFocusValue;
      String? capturedFocusGet() => capturedFocusValue;
      final router = _menuRouter(
        onPage: (focus) => capturedFocusValue = focus,
        child: BackgroundTasksPage,
      );

      _menuConversation = null;
      _lastOverridesService = null;
      await _pumpMenuHarness(tester, router, pageOverrides: const []);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('chat_more_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Background tasks'));
      await tester.pumpAndSettle();

      expect(capturedFocusGet(), isNull);
      expect(find.byKey(const Key('background_empty_state')), findsOneWidget,
          reason: 'a plausible page mounts at /background with empty tasks');
    });
  });
}

final DateTime _fixture = DateTime.utc(2026, 10, 9);

BackgroundTask _task(
  String id, {
  String owner = 'owner-1',
  BackgroundTaskState state = BackgroundTaskState.running,
  String prompt = 'watch the inbox',
  int loopMinutes = 0,
  int runCount = 0,
  DateTime? lastRunAt,
}) {
  return BackgroundTask(
    id: id,
    ownerConversationId: owner,
    taskConversationId: 'task-conv-$id',
    prompt: prompt,
    loopMinutes: loopMinutes,
    maxRuns: 10,
    runCount: runCount,
    state: state,
    lastRunAt: lastRunAt,
    createdAt: DateTime.utc(2026, 10, 9, 12),
  );
}

List<Conversation> _owners(List<String> ids) {
  return [
    for (final id in ids)
      Conversation(
        id: id,
        title: switch (id) {
          'owner-1' => 'Owner One',
          'owner-2' => 'Owner Two',
          _ => 'Chat $id',
        },
        createdAt: _fixture,
        updatedAt: _fixture,
      ),
  ];
}

GoRouter _menuRouter({
  required void Function(String? focus) onPage,
  required Type child,
}) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: ScreenAppBar(
            activeConversation: _menuConversation,
            isDark: false,
            hasPersonas: false,
            isTemporary: false,
            hasMessages: false,
            onMenuAction: (_) {},
            onPersonaPicker: () {},
            onChatModeAction: () {},
            onModelPicker: () {},
          ),
        ),
      ),
      GoRoute(
        path: '/background',
        builder: (context, state) {
          // Mirrors the app.dart route's query-parameter plumbing.
          onPage(state.uri.queryParameters['focus']);
          return const _BgMenuPageTarget();
        },
      ),
    ],
  );
}

Conversation? _menuConversation;

/// Page-facing fake over [BackgroundTasksService]: in-memory rows with
/// pause/resume/stop recording the calls and flipping row state so the
/// invalidated providers observe the transition.
class _PageBgService extends Fake implements BackgroundTasksService {
  _PageBgService() : tasks = <BackgroundTask>[];

  final List<BackgroundTask> tasks;
  final pauseCalls = <String>[];
  final resumeCalls = <String>[];
  final cancelCalls = <String>[];

  Completer<bool>? _pauseGate;

  /// Arms a gate so the NEXT pauseTask call stays pending until released.
  Completer<bool> holdPause() {
    _pauseGate = Completer<bool>();
    return _pauseGate!;
  }

  @override
  Future<List<BackgroundTask>> tasksFor(String ownerConversationId) async =>
      tasks
          .where((t) => t.ownerConversationId == ownerConversationId)
          .toList();

  @override
  Future<List<BackgroundTask>> allTasks() async => tasks;

  @override
  Future<BackgroundTask?> taskById(String taskId) async {
    for (final task in tasks) {
      if (task.id == taskId) return task;
    }
    return null;
  }

  void _flip(String taskId, BackgroundTaskState state) {
    for (var i = 0; i < tasks.length; i++) {
      if (tasks[i].id == taskId) {
        tasks[i] = BackgroundTask(
          id: tasks[i].id,
          ownerConversationId: tasks[i].ownerConversationId,
          taskConversationId: tasks[i].taskConversationId,
          prompt: tasks[i].prompt,
          loopMinutes: tasks[i].loopMinutes,
          maxRuns: tasks[i].maxRuns,
          runCount: tasks[i].runCount,
          state: state,
          lastRunAt: tasks[i].lastRunAt,
          createdAt: tasks[i].createdAt,
          resultMessageId: tasks[i].resultMessageId,
          ownerMessageId: tasks[i].ownerMessageId,
        );
      }
    }
  }

  @override
  Future<bool> pauseTask(String taskId) async {
    pauseCalls.add(taskId);
    final gate = _pauseGate;
    if (gate != null) {
      _pauseGate = null;
      final paused = await gate.future;
      if (!paused) return false;
    }
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
}

/// Records requestRun relays so the page tests can pin the resume bridge
/// without booting the real engine.
class _FakeEngine extends Fake implements BackgroundRunEngine {
  final requestRunCalls = <String>[];

  @override
  bool requestRun(String taskId) {
    requestRunCalls.add(taskId);
    return true;
  }
}

class _PageConversations extends conv.ConversationsNotifier {
  _PageConversations(this.rows);

  final List<Conversation> rows;

  @override
  Future<List<Conversation>> build() async => rows;
}

class _StubActiveServer extends server_providers.ActiveServerNotifier {
  @override
  Server? build() => null;
}

class _StubConnectionStatus extends server_providers.ConnectionStatusNotifier {
  @override
  ConnectionStatus build() => ConnectionStatus.disconnected;
}

class _StubSelectedModel extends SelectedModelNotifier {
  @override
  ModelInfo? build() => null;
}

double _highlightOpacity(WidgetTester tester) {
  final highlight = find.byKey(const Key('background_focus_highlight'));
  if (highlight.evaluate().isEmpty) return 0.0;
  final container = tester.widget<Container>(highlight.first);
  final decoration = container.decoration! as BoxDecoration;
  final border = decoration.border! as Border;
  return border.top.color.a;
}

Widget _wrapped(Widget child) {
  return ShadTheme(
    data: AppTheme.lightShadTheme,
    child: MaterialApp(
      theme: AppTheme.lightTheme,
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

/// Pumps the BackgroundTasksPage directly (no router) with a fake service
/// + fake engine + conversation mirror; returns the fake service and a
/// getter for the focused section's highlight opacity.
Future<(_PageBgService, double Function())> pumpPage(
  WidgetTester tester, {
  required List<BackgroundTask> tasks,
  List<Conversation> conversations = const [],
  String? focus,
  bool tallViewport = true,
}) async {
  tester.view.physicalSize = Size(700, tallViewport ? 2400 : 560);
  tester.view.devicePixelRatio = 1;
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final service = _PageBgService()..tasks.addAll(tasks);
  final overrides = [
    sharedPreferencesProvider.overrideWithValue(prefs),
    ..._pageOverrides(
      tasks: tasks,
      conversations: conversations,
      service: service,
    ),
  ];

  await tester.pumpWidget(
    ProviderScope(
      overrides: [ ...overrides ],
      child: _wrapped(
        Scaffold(body: BackgroundTasksPage(focusOwnerId: focus)),
      ),
    ),
  );
  await tester.pump();
  return (service, () => _highlightOpacity(tester));
}

// ---------------------------------------------------------------------------
// Harness plumbing (controller-finished)
// ---------------------------------------------------------------------------

/// The most recently built fake service (pageOverrides stashes it) so the
/// menu harness can return the SAME instance its overrides installed.
_PageBgService? _lastOverridesService;

List _pageOverrides({
  required List<BackgroundTask> tasks,
  required List<Conversation> conversations,
  _PageBgService? service,
}) {
  final effectiveService = service ?? (_PageBgService()..tasks.addAll(tasks));
  _lastOverridesService = effectiveService;
  return [
    backgroundTasksServiceProvider.overrideWith((_) => effectiveService),
    backgroundEngineProvider.overrideWith((_) => _FakeEngine()),
    conv.conversationsProvider.overrideWith(
      () => _PageConversations(conversations),
    ),
    server_providers.activeServerProvider.overrideWith(
      () => _StubActiveServer(),
    ),
    selectedModelProvider.overrideWith(() => _StubSelectedModel()),
    server_providers.connectionStatusProvider.overrideWith(() => _StubConnectionStatus()),
  ];
}

String? _menuRouterFocusState;

class _BgMenuPageTarget extends ConsumerWidget {
  const _BgMenuPageTarget();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const BackgroundTasksPage(focusOwnerId: null);
  }
}

Future<(_PageBgService, String? Function())> _pumpMenuHarness(
  WidgetTester tester,
  GoRouter router, {
  required List pageOverrides,
}) async {
  tester.view.physicalSize = const Size(700, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  String? capturedFocusFn() => _menuRouterFocusState;
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        ...pageOverrides,
      ],
      child: ShadTheme(
        data: AppTheme.lightShadTheme,
        child: MaterialApp.router(
          theme: AppTheme.lightTheme,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    ),
  );
  final service = _lastOverridesService ?? (_PageBgService()..tasks.addAll(const []));
  return (service, capturedFocusFn);
}
