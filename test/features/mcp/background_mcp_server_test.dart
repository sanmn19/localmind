import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore_for_file: prefer_initializing_formals
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/objectbox.g.dart';
import 'package:localmind/features/chat/data/mcp_client.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/chat/data/models/background_task.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Task 3 of the background sub-agents feature: the in-process
// `local://background` MCP server. Covers registration, the three-tool
// surface (bg.spawn / bg.status / bg.cancel), dispatch through the
// callback-struct services (spawn orchestration + run-request relay), the
// concurrency-cap error string, and status/cancel rendering.
//
// The spawn ORCHESTRATION group (hidden Conversation row stamped
// `isBackground` + BackgroundTaskEntity row, per the fork stamp parity
// ruling) activates the REAL webServerRegistrationProvider wiring over the
// ObjectBox-boundary fakes — the per-file convention (condition-agnostic
// builders + Dart-side re-filtering) follows background_task_service_test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('registration', () {
    test('addBackgroundServer registers local://background with 3 tools',
        () async {
      final manager = McpServerManager();
      expect(manager.hasBackgroundServer(), isFalse);

      await manager.addBackgroundServer(_RecordingServices());

      expect(manager.hasBackgroundServer(), isTrue);
      expect(manager.getServerUrl(bgMcpServerLabel), bgMcpServerUrl);
      expect(
        manager.getServerUrl(bgMcpServerLabel),
        'local://background',
        reason: 'the plan pins the server URL constant exactly',
      );
      expect(manager.hasServer(bgMcpServerLabel), isTrue);
      final toolNames = manager.getTools(bgMcpServerLabel).map((t) => t.name);
      expect(
        toolNames,
        containsAllInOrder(const ['bg.spawn', 'bg.status', 'bg.cancel']),
      );
    });

    test('bg.spawn schema requires the prompt with loop/max options',
        () async {
      final manager = McpServerManager();
      await manager.addBackgroundServer(_RecordingServices());

      final spawn = manager
          .getTools(bgMcpServerLabel)
          .firstWhere((t) => t.name == 'bg.spawn');
      expect(spawn.inputSchema['type'], 'object');
      expect(spawn.inputSchema['required'], ['prompt']);
      final properties = spawn.inputSchema['properties']! as Map;
      expect(properties.keys.toSet(), {'prompt', 'loop_minutes', 'max_runs'});

      final status = manager
          .getTools(bgMcpServerLabel)
          .firstWhere((t) => t.name == 'bg.status');
      expect(status.inputSchema['type'], 'object');

      final cancel = manager
          .getTools(bgMcpServerLabel)
          .firstWhere((t) => t.name == 'bg.cancel');
      expect(cancel.inputSchema['required'], ['task_id']);
    });

    test('re-add replaces the bundle (idempotent semantics)', () async {
      final manager = McpServerManager();
      await manager.addBackgroundServer(_RecordingServices());
      await manager.addBackgroundServer(_RecordingServices());
      expect(manager.hasBackgroundServer(), isTrue);
    });

    test('unregistered server rejects calls and removeServer cleans up',
        () async {
      final manager = McpServerManager();
      expect(
        () => manager.callTool(bgMcpServerLabel, 'bg.status', {}),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            'MCP server not connected: $bgMcpServerLabel',
          ),
        ),
      );
      await manager.addBackgroundServer(_RecordingServices());
      await manager.removeServer(bgMcpServerLabel);
      expect(manager.hasBackgroundServer(), isFalse);
    });
  });

  group('dispatch through the services struct (fakes)', () {
    test('bg.spawn passes args and relays the run request; output renders '
        'task_id with cadence + max runs', () async {
      final services = _RecordingServices(
        spawnResult: BackgroundTask(
          id: 'task-42',
          ownerConversationId: 'owner-1',
          taskConversationId: 'task-conv-42',
          prompt: 'watch the mail',
          loopMinutes: 15,
          maxRuns: 4,
          createdAt: DateTime.utc(2026, 10, 9, 12),
        ),
      );
      expect(services.runRequesterCalls, isEmpty);

      final manager = McpServerManager();
      await manager.addBackgroundServer(services);
      final output = await manager.callTool(
        bgMcpServerLabel,
        'bg.spawn',
        {'prompt': '  watch the mail  ', 'loop_minutes': 15, 'max_runs': 4},
      );

      expect(services.spawnCalls.single.ownerConversationId, 'owner-1');
      expect(services.spawnCalls.single.prompt, 'watch the mail');
      expect(services.spawnCalls.single.loopMinutes, 15);
      expect(services.spawnCalls.single.maxRuns, 4);
      // v1 run-request seam: the handler relays the first run to the
      // engine requester right after a successful spawn.
      expect(services.runRequesterCalls, ['task-42']);
      expect(output, '{task_id: task-42 (loops every 15 min, max 4)}');
    });

    test('bg.spawn single-run render for loop_minutes absent/0', () async {
      final services = _RecordingServices(
        spawnResult: BackgroundTask(
          id: 'task-single',
          ownerConversationId: 'owner-1',
          taskConversationId: 'task-conv-1',
          prompt: 'quick check',
          loopMinutes: 0,
          maxRuns: 10,
          createdAt: DateTime.utc(2026, 10, 9, 12),
        ),
      );
      final manager = McpServerManager();
      await manager.addBackgroundServer(services);

      final output = await manager.callTool(bgMcpServerLabel, 'bg.spawn', {
        'prompt': 'quick check',
      });

      expect(output, '{task_id: task-single (single run, max 10)}');
      expect(services.spawnCalls.single.loopMinutes, isNull);
      expect(services.spawnCalls.single.maxRuns, isNull);
    });

    test('bg.spawn requires a string prompt and integer options', () async {
      final manager = McpServerManager();
      await manager.addBackgroundServer(_RecordingServices());

      await expectLater(
        manager.callTool(bgMcpServerLabel, 'bg.spawn', {}),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            'bg.spawn requires a string prompt',
          ),
        ),
      );
      await expectLater(
        manager.callTool(bgMcpServerLabel, 'bg.spawn', {
          'prompt': 'x',
          'loop_minutes': 'fifteen',
        }),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            'bg.spawn requires an integer loop_minutes',
          ),
        ),
      );
      await expectLater(
        manager.callTool(bgMcpServerLabel, 'bg.spawn', {
          'prompt': 'x',
          'max_runs': 1.5,
        }),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            'bg.spawn requires an integer max_runs',
          ),
        ),
      );
    });

    test('bg.spawn without an active conversation rejects with guidance',
        () async {
      final manager = McpServerManager();
      await manager.addBackgroundServer(_RecordingServices(ownerless: true));
      await expectLater(
        manager.callTool(bgMcpServerLabel, 'bg.spawn', {'prompt': 'x'}),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            'bg.spawn needs an active conversation to own the task',
          ),
        ),
      );
    });

    test('cap failure renders an ERROR string, not an exception', () async {
      final services = _RecordingServices(
        spawnError: StateError(
          'Background task concurrency cap reached (3 running tasks); '
          'cancel one before starting another.',
        ),
      );
      final manager = McpServerManager();
      await manager.addBackgroundServer(services);

      final output = await manager.callTool(
        bgMcpServerLabel,
        'bg.spawn',
        {'prompt': 'one too many'},
      );

      expect(output, contains('ERROR:'));
      expect(output, contains('cap reached (3 running tasks)'));
      expect(services.runRequesterCalls, isEmpty);
    });

    test('bg.status renders owner-scoped lines with state + last activity',
        () async {
      final services = _RecordingServices(
        taskResults: [
          BackgroundTask(
            id: 'task-live',
            ownerConversationId: 'owner-1',
            taskConversationId: 'task-conv-live',
            prompt: 'watch for the invoice reply',
            loopMinutes: 15,
            maxRuns: 10,
            runCount: 3,
            state: BackgroundTaskState.running,
            lastRunAt: DateTime.utc(2026, 10, 9, 12, 34),
            createdAt: DateTime.utc(2026, 10, 9, 12),
          ),
          BackgroundTask(
            id: 'task-done',
            ownerConversationId: 'owner-1',
            taskConversationId: 'task-conv-done',
            prompt: 'summarize',
            loopMinutes: 0,
            maxRuns: 10,
            runCount: 1,
            state: BackgroundTaskState.finished,
            createdAt: DateTime.utc(2026, 10, 9, 11),
          ),
        ],
      );
      final manager = McpServerManager();
      await manager.addBackgroundServer(services);

      final output = await manager.callTool(bgMcpServerLabel, 'bg.status', {});

      expect(services.tasksForCalls, ['owner-1']);
      expect(output, contains('1. running'));
      expect(output, contains('task-live'));
      expect(output, contains('watch for the invoice'));
      expect(output, contains('loops every 15 min'));
      expect(output, contains('3/10'));
      expect(output, contains('2026-10-09T12:34:00'));
      expect(output, contains('2. finished'));
      expect(output, contains('task-done'));
      expect(output, contains('single run'));
      expect(output, contains('not started'));
    });

    test('bg.status renders the empty state', () async {
      final manager = McpServerManager();
      await manager.addBackgroundServer(_RecordingServices());

      final output = await manager.callTool(bgMcpServerLabel, 'bg.status', {});
      expect(output, contains('No background tasks'));
    });

    test('bg.cancel renders cancelled vs already-finished outcomes',
        () async {
      final services = _RecordingServices(
        cancelResults: {'task-live': true, 'task-done': false},
      );
      final manager = McpServerManager();
      await manager.addBackgroundServer(services);

      expect(
        await manager.callTool(bgMcpServerLabel, 'bg.cancel', {
          'task_id': 'task-live',
        }),
        contains('Cancelled'),
      );
      expect(
        await manager.callTool(bgMcpServerLabel, 'bg.cancel', {
          'task_id': 'task-done',
        }),
        contains('already finished'),
      );
      expect(services.cancelCalls, ['task-live', 'task-done']);

      await expectLater(
        manager.callTool(bgMcpServerLabel, 'bg.cancel', {}),
        throwsA(isA<McpException>()),
      );
    });

    test('unknown bg tool names reject with McpException', () async {
      final manager = McpServerManager();
      await manager.addBackgroundServer(_RecordingServices());
      await expectLater(
        manager.callTool(bgMcpServerLabel, 'bg.unknown', {}),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            'Background MCP tool not found: bg.unknown',
          ),
        ),
      );
    });
  });

  group('spawn orchestration (real wiring, fake persistence)', () {
    test('bg.spawn creates the hidden isBackground conversation and the '
        'owned task row (fork stamp parity)', () async {
      final db = _FakeFeaturesDb();
      final container = _wiredContainer(db);
      addTearDown(container.dispose);

      container
          .read(conv.activeConversationIdProvider.notifier)
          .setActiveConversationId('owner-1');
      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      final manager = container.read(mcpServerManagerProvider);
      final output = await manager.callTool(
        bgMcpServerLabel,
        'bg.spawn',
        {'prompt': 'watch for price drops weekly', 'loop_minutes': 60},
      );

      // The hidden task conversation: a REAL conversation row behind the
      // isBackground stamp (fork parity), titled 'BG: <prompt-32>'.
      final bgRows = db.convs.where((c) => c.isBackground).toList();
      expect(bgRows, hasLength(1));
      expect(bgRows.single.isFork, isFalse);
      expect(bgRows.single.title, 'BG: watch for price drops weekly');

      // The anchor row: owner + hidden companion conversation ids stamped.
      final taskRow = db.tasks.single;
      expect(taskRow.ownerConversationId, 'owner-1');
      expect(taskRow.taskConversationId, bgRows.single.id);
      expect(taskRow.prompt, 'watch for price drops weekly');
      expect(taskRow.loopMinutes, 60);
      expect(taskRow.state, BackgroundTaskState.running.name);

      expect(output, contains('{task_id:'));
      expect(output, contains(taskRow.id));
    });

    test('cap failure surfaces the ERROR string and leaves no orphan hidden '
        'conversation', () async {
      final db = _FakeFeaturesDb(
        seedTasks: [_taskEntity(id: 'r-1'), _taskEntity(id: 'r-2'),
          _taskEntity(id: 'r-3')],
      );
      final container = _wiredContainer(db);
      addTearDown(container.dispose);

      container
          .read(conv.activeConversationIdProvider.notifier)
          .setActiveConversationId('owner-1');
      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      final manager = container.read(mcpServerManagerProvider);
      final output = await manager.callTool(
        bgMcpServerLabel,
        'bg.spawn',
        {'prompt': 'one too many'},
      );

      expect(output, contains('ERROR:'));
      expect(output, contains('cap reached (3 running tasks)'));
      // No hidden 'BG:' conversation row dangles after the refused spawn.
      expect(db.convs, isEmpty);
      expect(db.tasks, hasLength(3));
    });

    test('bg.status reads the persisted rows for the active conversation',
        () async {
      final db = _FakeFeaturesDb(
        seedTasks: [
          _taskEntity(
            owner: 'owner-1',
            createdAt: DateTime.utc(2026, 10, 9, 10),
            lastRunAt: DateTime.utc(2026, 10, 9, 10, 5),
          ),
        ],
      );
      final container = _wiredContainer(db);
      addTearDown(container.dispose);

      container
          .read(conv.activeConversationIdProvider.notifier)
          .setActiveConversationId('owner-1');
      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      final manager = container.read(mcpServerManagerProvider);
      final output = await manager.callTool(bgMcpServerLabel, 'bg.status', {});

      expect(output, contains(_taskEntity(owner: 'owner-1').id));
      expect(output, contains('running'));
    });

    test('bg.cancel persists the cancelled state and renders the outcome',
        () async {
      final db = _FakeFeaturesDb(seedTasks: [_taskEntity(id: 'stored-2')]);
      final container = _wiredContainer(db);
      addTearDown(container.dispose);

      container
          .read(conv.activeConversationIdProvider.notifier)
          .setActiveConversationId('owner-1');
      container.listen(webServerRegistrationProvider, (_, _) {});
      await pumpEventQueue();

      final manager = container.read(mcpServerManagerProvider);
      final output = await manager.callTool(
        bgMcpServerLabel,
        'bg.cancel',
        {'task_id': 'stored-2'},
      );

      expect(output, contains('Cancelled'));
      expect(db.tasks.single.state, BackgroundTaskState.cancelled.name);
    });
  });
}

/// Fake callback-struct bundle driving the manager-level dispatch tests.
/// Function-typed struct fields are overridden with recording GETTERS (a
/// field's implicit getter may be overridden by a concrete getter; methods
/// would conflict).
class _RecordingServices implements BackgroundServices {
  _RecordingServices({
    BackgroundTask? spawnResult,
    StateError? spawnError,
    List<BackgroundTask> taskResults = const [],
    Map<String, bool> cancelResults = const {},
    bool ownerless = false,
  }) : _spawnResult = spawnResult,
       _spawnError = spawnError,
       _taskResults = taskResults,
       _cancelResults = cancelResults,
       _ownerless = ownerless;

  final BackgroundTask? _spawnResult;
  final StateError? _spawnError;
  final List<BackgroundTask> _taskResults;
  final Map<String, bool> _cancelResults;
  final bool _ownerless;

  final spawnCalls = <_SpawnArgs>[];
  final tasksForCalls = <String>[];
  final cancelCalls = <String>[];
  final runRequesterCalls = <String>[];

  @override
  Future<BackgroundTask> Function({
    required String ownerConversationId,
    required String prompt,
    int? loopMinutes,
    int? maxRuns,
  }) get spawn =>
      ({required String ownerConversationId, required String prompt,
          int? loopMinutes, int? maxRuns}) {
        spawnCalls.add(
          _SpawnArgs(
            ownerConversationId: ownerConversationId,
            prompt: prompt,
            loopMinutes: loopMinutes,
            maxRuns: maxRuns,
          ),
        );
        final error = _spawnError;
        if (error != null) throw error;
        return Future.value(_spawnResult!);
      };

  @override
  Future<List<BackgroundTask>> Function(String) get tasksFor => (owner) {
        tasksForCalls.add(owner);
        return Future.value(_taskResults);
      };

  @override
  Future<bool> Function(String) get cancelTask => (taskId) {
        cancelCalls.add(taskId);
        return Future.value(_cancelResults[taskId] ?? false);
      };

  @override
  void Function(String taskId)? get runRequester => runRequesterCalls.add;

  @override
  String? Function()? get currentOwnerConversationId =>
      _ownerless ? null : () => 'owner-1';
}

class _SpawnArgs {
  _SpawnArgs({
    required this.ownerConversationId,
    required this.prompt,
    required this.loopMinutes,
    required this.maxRuns,
  });

  final String ownerConversationId;
  final String prompt;
  final int? loopMinutes;
  final int? maxRuns;
}

// ---------------------------------------------------------------------------
// Spawn-orchestration harness: the REAL webServerRegistrationProvider
// wiring over an ObjectBox-boundary fake store.
// ---------------------------------------------------------------------------

/// Conversations notifier keeping the real create/delete heritage, with a
/// seeded build (the fake store answers the state reloads).
class _SpawnConversations extends conv.ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => const [];
}

class _BgOnSettings extends SettingsNotifier {
  @override
  AppSettings build() => AppSettings(backgroundTasksEnabled: true);
}

ProviderContainer _wiredContainer(_FakeFeaturesDb db) {
  SharedPreferences.setMockInitialValues({});
  return ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      packageInfoProvider.overrideWith(
        (ref) async => PackageInfo(
          appName: 'LocalMind',
          packageName: 'test',
          version: '1.0.0',
          buildNumber: '1',
        ),
      ),
      settingsProvider.overrideWith(() => _BgOnSettings()),
      conv.conversationsProvider.overrideWith(() => _SpawnConversations()),
    ],
  );
}

/// Persistence-boundary fake covering the three boxes the spawn
/// orchestration touches (BackgroundTaskEntity / ConversationEntity /
/// MessageEntity). Conditions are ignored (fork convention), so correctness
/// rests on the Dart-side re-filters inside the services.
class _FakeFeaturesDb extends Fake implements ObjectBoxStore {
  _FakeFeaturesDb({List<BackgroundTaskEntity> seedTasks = const []})
      : tasks = List.of(seedTasks),
        convs = [],
        msgs = [] {
    for (var i = 0; i < tasks.length; i++) {
      if (tasks[i].internalId == 0) tasks[i].internalId = i + 1;
    }
  }

  final List<BackgroundTaskEntity> tasks;
  final List<ConversationEntity> convs;
  final List<MessageEntity> msgs;

  @override
  Store get store => _FakeBackgroundStore(this);

  @override
  Box<ConversationEntity> get conversationBox => _ConvBox(convs);

  @override
  Box<MessageEntity> get messageBox => _MsgBox(msgs);
}

class _FakeBackgroundStore extends Fake implements Store {
  _FakeBackgroundStore(this.db);

  final _FakeFeaturesDb db;

  @override
  Future<R> runInTransactionAsync<R, T>(
    TxMode mode,
    R Function(Store, T) fn,
    T arg,
  ) async => fn(this, arg);

  @override
  Box<T> box<T>() {
    if (T == BackgroundTaskEntity) return _TaskBox(db.tasks) as Box<T>;
    if (T == ConversationEntity) return _ConvBox(db.convs) as Box<T>;
    if (T == MessageEntity) return _MsgBox(db.msgs) as Box<T>;
    throw UnimplementedError('box<$T> is not faked');
  }
}

class _TaskBox extends Fake implements Box<BackgroundTaskEntity> {
  _TaskBox(this.rows);

  final List<BackgroundTaskEntity> rows;

  @override
  QueryBuilder<BackgroundTaskEntity> query([
    Condition<BackgroundTaskEntity>? qc,
  ]) {
    return _FakeQueryBuilder<BackgroundTaskEntity>(rows);
  }

  @override
  int put(BackgroundTaskEntity entity, {PutMode mode = PutMode.put}) {
    final index = entity.internalId == 0
        ? -1
        : rows.indexWhere((row) => row.internalId == entity.internalId);
    if (index >= 0) {
      rows[index] = entity;
    } else {
      rows.add(entity);
    }
    return 1;
  }

  @override
  int removeMany(List<int> ids) {
    final before = rows.length;
    rows.removeWhere((row) => ids.contains(row.internalId));
    return before - rows.length;
  }
}

class _ConvBox extends Fake implements Box<ConversationEntity> {
  _ConvBox(this.rows);
  final List<ConversationEntity> rows;

  @override
  int put(ConversationEntity entity, {PutMode mode = PutMode.put}) {
    if (entity.internalId == 0) {
      entity.internalId = rows.length + 1;
    }
    final index = rows.indexWhere((row) => row.internalId == entity.internalId);
    if (index >= 0) {
      rows[index] = entity;
    } else {
      rows.add(entity);
    }
    return 1;
  }

  @override
  List<ConversationEntity> getAll() => List.of(rows);

  @override
  QueryBuilder<ConversationEntity> query([
    Condition<ConversationEntity>? qc,
  ]) {
    return _FakeQueryBuilder<ConversationEntity>(rows);
  }

  @override
  int removeMany(List<int> ids) {
    final before = rows.length;
    rows.removeWhere((row) => ids.contains(row.internalId));
    return before - rows.length;
  }
}

class _MsgBox extends Fake implements Box<MessageEntity> {
  _MsgBox(this.rows);

  final List<MessageEntity> rows;

  @override
  QueryBuilder<MessageEntity> query([Condition<MessageEntity>? qc]) {
    return _FakeQueryBuilder<MessageEntity>(rows);
  }

  @override
  int removeMany(List<int> ids) {
    final before = rows.length;
    rows.removeWhere((row) => ids.contains(row.internalId));
    return before - rows.length;
  }
}

class _FakeQueryBuilder<T> extends Fake implements QueryBuilder<T> {
  _FakeQueryBuilder(this.rows);

  final List<T> rows;

  @override
  Query<T> build() => _FakeQuery<T>(rows);

  void close() {}
}

class _FakeQuery<T> extends Fake implements Query<T> {
  _FakeQuery(this.rows);

  final List<T> rows;

  @override
  List<T> find() => List.of(rows);

  @override
  T? findFirst() => rows.isEmpty ? null : rows.first;

  @override
  List<int> findIds() =>
      rows.map((row) => (row as dynamic).internalId as int).toList();

  @override
  void close() {}
}

BackgroundTaskEntity _taskEntity({
  String id = 't-1',
  String owner = 'c1',
  String state = 'running',
  DateTime? createdAt,
  DateTime? lastRunAt,
}) {
  return BackgroundTaskEntity(
    id: id,
    ownerConversationId: owner,
    taskConversationId: 'c-task-$id',
    prompt: 'watch the price',
    loopMinutes: 15,
    maxRuns: 10,
    state: state,
    lastRunAt: lastRunAt,
    createdAt: createdAt ?? DateTime.utc(2026, 10, 9),
  );
}
