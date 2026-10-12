import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/objectbox.g.dart';
import 'package:localmind/features/chat/data/background_task_service.dart';
import 'package:localmind/features/chat/data/models/background_task.dart';
import 'package:localmind/features/conversations/data/message_search_service.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:shared_preferences/shared_preferences.dart';

// Task 2 of the background sub-agents feature: BackgroundTasksService CRUD +
// normalization rules, state-transition idempotency, the delete-state cascade
// seam, and the exclusions keeping hidden background-task conversations out
// of history and message search.
//
// ObjectBox-backed operations run against the native libobjectbox.so, which
// the host unit-test toolchain does not ship (probe convention documented in
// fork_service_test.dart) — persistence is faked at the ObjectBoxStore
// boundary here; real-box semantics are covered by mapping round-trip tests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundTaskEntity.toDomain (T1 review ruling)', () {
    test('unknown state strings map to failed, never running', () {
      final task = _entity(state: 'corrupted-row').toDomain();
      expect(task.state, BackgroundTaskState.failed);
    });

    test('documented state names round-trip', () {
      for (final s in BackgroundTaskState.values) {
        expect(_entity(state: s.name).toDomain().state, s);
      }
    });
  });

  group('BackgroundTasksService.createTask', () {
    test('floors sub-10 loop minutes; absent/0 means single-run', () async {
      final db = _FakeTasksDb([]);
      final service = BackgroundTasksService(db);

      // Cap hygiene: each probe task is finished before the next is
      // created, so the 3-running concurrency cap never trips mid-test.
      Future<BackgroundTask> probe({
        required String taskId,
        int? loopMinutes,
      }) async {
        final task = await service.createTask(
          ownerConversationId: 'c1',
          prompt: 'watch',
          loopMinutes: loopMinutes,
          taskConversationId: 'c-$taskId',
        );
        await service.markFinished(task.id);
        return task;
      }

      final absent = await probe(taskId: 'p-absent');
      expect(absent.loopMinutes, 0);

      final zero = await probe(taskId: 'p-zero', loopMinutes: 0);
      expect(zero.loopMinutes, 0);

      final three = await probe(taskId: 'p-three', loopMinutes: 3);
      expect(three.loopMinutes, 10);

      final fifteen = await probe(taskId: 'p-fifteen', loopMinutes: 15);
      expect(fifteen.loopMinutes, 15);
    });

    test('clamps maxRuns: default 10, cap 25, floor 1', () async {
      final db = _FakeTasksDb([]);
      final service = BackgroundTasksService(db);

      // Cap hygiene: finish each probe before creating the next.
      Future<BackgroundTask> probe(int? maxRuns, String key) async {
        final task = await service.createTask(
          ownerConversationId: 'c1',
          prompt: 'watch',
          maxRuns: maxRuns,
          taskConversationId: 'c-$key',
        );
        await service.markFinished(task.id);
        return task;
      }

      expect((await probe(null, 'd1')).maxRuns, 10);
      expect((await probe(0, 'd2')).maxRuns, 1);
      expect((await probe(5, 'd3')).maxRuns, 5);
      expect((await probe(30, 'd4')).maxRuns, 25);
      expect((await probe(25, 'd5')).maxRuns, 25);
    });

    test('throws StateError once bgMaxConcurrentTasks tasks are running',
        () async {
      final db = _FakeTasksDb([
        _entity(id: 't-1', state: 'running'),
        _entity(id: 't-2', state: 'running'),
        _entity(id: 't-3', state: 'running'),
      ]);
      final service = BackgroundTasksService(db);

      await expectLater(
        service.createTask(
          ownerConversationId: 'c1',
          prompt: 'watch',
          taskConversationId: 'c-run-4',
        ),
        throwsStateError,
      );
      expect(db.rowCount(), 3);
    });

    test('terminal rows do not count toward the concurrency cap', () async {
      final db = _FakeTasksDb([
        _entity(id: 't-1', state: 'running'),
        _entity(id: 't-2', state: 'cancelled'),
        _entity(id: 't-3', state: 'finished'),
        _entity(id: 't-4', state: 'failed'),
      ]);
      final service = BackgroundTasksService(db);

      final task = await service.createTask(
        ownerConversationId: 'c1',
        prompt: 'watch',
        taskConversationId: 'c-run-5',
      );
      expect(task.state, BackgroundTaskState.running);
      expect(db.rowCount(), 5);
    });
  });

  group('state transitions', () {
    test('cancelTask is idempotent once cancelled', () async {
      final cancellations = <String>[];
      final db = _FakeTasksDb([_entity(id: 't-1', state: 'running')]);
      final service = BackgroundTasksService(
        db,
        (taskId) => cancellations.add(taskId),
      );

      expect(await service.cancelTask('t-1'), isTrue);
      expect(await service.cancelTask('t-1'), isTrue);

      final stored = db.rows.single;
      expect(stored.state, BackgroundTaskState.cancelled.name);
      // Review I1: cancelTask relays the cancel REQUEST before the write —
      // once per call (idempotent DB state, but a live generator must wake
      // on every cancel attempt even if the write fails).
      expect(cancellations, ['t-1', 't-1']);
    });

    test('cancelTask relays to the live engine BEFORE the write (I1)',
        () async {
      final relays = <String>[];
      final db = _FailingWriteTasksDb(
        [_entity(id: 't-live', taskConversation: 'c-live')],
      );
      final service = BackgroundTasksService(db, relays.add);

      // The write fails hard, yet the relay already fired — a live
      // generator wakes regardless of DB outcome.
      await expectLater(
        service.cancelTask('t-live'),
        throwsStateError,
      );
      expect(relays, ['t-live']);
    });

    test('cancelTask on terminal/unknown rows still relays (no-op engine '
        'side), refuses the state regression', () async {
      final relays = <String>[];
      final db = _FakeTasksDb([
        _entity(id: 't-done', state: 'finished'),
        _entity(id: 't-fail', state: 'failed'),
      ]);
      final service = BackgroundTasksService(db, relays.add);

      expect(await service.cancelTask('t-done'), isFalse);
      expect(await service.cancelTask('t-fail'), isFalse);
      expect(await service.cancelTask('t-missing'), isFalse);
      expect(relays, ['t-done', 't-fail', 't-missing']);
      expect(db.rows.map((e) => e.state).toSet(), {'finished', 'failed'});
    });

    test('markFinished sets ids; second call keeps the first ids', () async {
      final db = _FakeTasksDb([_entity(id: 't-1', state: 'running')]);
      final service = BackgroundTasksService(db);

      expect(
        await service.markFinished(
          't-1',
          resultMessageId: 'm-first',
          ownerMessageId: 'm-owner',
        ),
        isTrue,
      );
      expect(
        await service.markFinished('t-1', resultMessageId: 'm-second'),
        isTrue,
      );

      final stored = db.rows.single;
      expect(stored.state, BackgroundTaskState.finished.name);
      expect(stored.resultMessageId, 'm-first');
      expect(stored.ownerMessageId, 'm-owner');
    });

    test('markFinished on cancelled/unknown → false', () async {
      final db = _FakeTasksDb([_entity(id: 't-c', state: 'cancelled')]);
      final service = BackgroundTasksService(db);

      expect(await service.markFinished('t-c'), isFalse);
      expect(await service.markFinished('t-missing'), isFalse);
      expect(db.rows.single.state, BackgroundTaskState.cancelled.name);
    });
  });

  group('queries', () {
    test('tasksFor is owner-scoped and createdAt-sorted oldest-first',
        () async {
      final db = _FakeTasksDb([
        _entity(
          id: 't-late',
          owner: 'c2',
          createdAt: DateTime.utc(2026, 10, 9, 12),
        ),
        _entity(id: 't-second', owner: 'c1', createdAt: DateTime.utc(2026, 10, 9, 11)),
        _entity(id: 't-first', owner: 'c1', createdAt: DateTime.utc(2026, 10, 9, 10)),
      ]);
      final service = BackgroundTasksService(db);

      final mine = await service.tasksFor('c1');
      expect(mine.map((t) => t.id), ['t-first', 't-second']);
      expect(await service.tasksFor('c-empty'), isEmpty);
    });

    test('runningCount counts running rows only', () async {
      final db = _FakeTasksDb([
        _entity(id: 't-1', state: 'running'),
        _entity(id: 't-2', state: 'cancelled'),
        _entity(id: 't-3', state: 'failed'),
        _entity(id: 't-4', owner: 'c2', state: 'running'),
      ]);
      final service = BackgroundTasksService(db);

      expect(await service.runningCount(), 2);
    });
  });

  group('delete cascade', () {
    test('deleteTasksOwnedBy removes owner rows and relays cancel requests',
        () async {
      final cancellations = <String>[];
      final db = _FakeTasksDb([
        _entity(id: 't-1', internalId: 1),
        _entity(id: 't-2', owner: 'c2', internalId: 2),
      ]);
      final service = BackgroundTasksService(
        db,
        (taskId) => cancellations.add(taskId),
      );

      expect(await service.deleteTasksOwnedBy('c1'), isTrue);
      expect(db.rows.map((e) => e.id), ['t-2']);
      expect(cancellations, ['t-1']);

      // Idempotent: the second sweep has nothing left to remove.
      expect(await service.deleteTasksOwnedBy('c1'), isFalse);
      expect(cancellations, ['t-1']);
    });

    test('deleteAllTasks wipes the whole table and relays every removed id '
        '(M8)', () async {
      final cancellations = <String>[];
      final db = _FakeTasksDb([
        _entity(id: 't-1', owner: 'c1', internalId: 1),
        _entity(id: 't-2', owner: 'c2', internalId: 2),
      ]);
      final service = BackgroundTasksService(db, cancellations.add);

      expect(await service.deleteAllTasks(), isTrue);
      expect(db.rows, isEmpty);
      expect(cancellations, containsAll(['t-1', 't-2']));
      expect(cancellations, hasLength(2));

      // Idempotent: an empty table is a no-op.
      expect(await service.deleteAllTasks(), isFalse);
      expect(cancellations, hasLength(2));
    });
  });

  group('exclusions', () {
    test('filteredConversationsProvider hides background rows too', () async {
      SharedPreferences.setMockInitialValues({});
      final rows = [
        _conversation('keep-1'),
        _conversation('bgt-1', isBackground: true),
        _conversation('fork-1', isFork: true),
      ];
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          conv.conversationsProvider.overrideWith(() => _Seeded(rows)),
        ],
      );
      addTearDown(container.dispose);

      await container.read(conv.conversationsProvider.future);
      final filtered = container.read(conv.filteredConversationsProvider).value!;
      expect(filtered.map((c) => c.id), ['keep-1']);
    });

    test('search parcel covers fork + background flags + tasks table',
        () async {
      final db = _FakeTasksDb(
        [_entity(id: 't-1', taskConversation: 'c-task-1', state: 'running')],
        conversations: [
          ConversationEntity(
            id: 'c-normal',
            title: 'Normal',
            createdAt: DateTime.utc(2026, 10, 9),
            updatedAt: DateTime.utc(2026, 10, 9),
          ),
          ConversationEntity(
            id: 'c-run-1',
            title: 'BG',
            createdAt: DateTime.utc(2026, 10, 9),
            updatedAt: DateTime.utc(2026, 10, 9),
            isBackground: true,
          ),
          ConversationEntity(
            id: 'c-fork-1',
            title: 'Fork',
            createdAt: DateTime.utc(2026, 10, 9),
            updatedAt: DateTime.utc(2026, 10, 9),
            isFork: true,
          ),
        ],
        messages: [
          MessageEntity(
            id: 'm-hidden',
            conversationUid: 'c-task-1',
            roleIndex: MessageRole.user.index,
            content: 'needle in the task chat',
            createdAt: DateTime.utc(2026, 10, 9, 12),
            statusIndex: 1,
          ),
          MessageEntity(
            id: 'm-visible',
            conversationUid: 'c-normal',
            roleIndex: MessageRole.user.index,
            content: 'needle in the own chat',
            createdAt: DateTime.utc(2026, 10, 9, 12, 1),
            statusIndex: 1,
          ),
        ],
      );
      final service = MessageSearchService();

      final exclude = service.hiddenConversationIds(db);
      expect(
        exclude,
        containsAll(['c-fork-1', 'c-run-1', 'c-task-1']),
        reason:
            'fork rows, background-flagged rows and live task-conversation ids '
            'all join the exclusion parcel',
      );

      final hits = service.searchMessages(
        db,
        query: 'needle',
        excludedConversationIds: exclude,
      );
      expect(hits, hasLength(1));
      expect(hits.single.conversationId, 'c-normal');
    });
  });

  group('BackgroundTasksService engine lifecycle (Task 4 additive seam)', () {
    test('taskById resolves a row by its task id and misses unknown ids',
        () async {
      final db = _FakeTasksDb([_entity(id: 't-1', taskConversation: 'c-t1')]);
      final service = BackgroundTasksService(db);

      final found = await service.taskById('t-1');
      expect(found, isNotNull);
      expect(found!.taskConversationId, 'c-t1');
      expect(await service.taskById('nope'), isNull);
    });

    test('recordRun bumps runCount + lastRunAt only on running rows',
        () async {
      final first = _entity(id: 't-run', taskConversation: 'c-run');
      final db = _FakeTasksDb([first, _entity(id: 't-done', taskConversation: 'c-d')]);
      final service = BackgroundTasksService(db);
      await service.markFinished('t-done');

      expect(await service.recordRun('t-run'), isTrue);
      final runRow = await service.taskById('t-run');
      expect(runRow!.runCount, 1);
      expect(runRow.lastRunAt, isNotNull);

      // Finished/failed/cancelled rows are terminal: no run-count movement.
      expect(await service.recordRun('t-done'), isFalse);
      final doneRow = await service.taskById('t-done');
      expect(doneRow!.runCount, 0);
      expect(doneRow.lastRunAt, isNull);
    });

    test('markFailed moves running→failed once and refuses other states',
        () async {
      final db = _FakeTasksDb([
        _entity(id: 't-fail', taskConversation: 'c-f'),
        _entity(id: 't-canc', taskConversation: 'c-x'),
      ]);
      final service = BackgroundTasksService(db);
      await service.cancelTask('t-canc');

      expect(await service.markFailed('t-fail'), isTrue);
      expect((await service.taskById('t-fail'))!.state, BackgroundTaskState.failed);
      expect(await service.markFailed('t-fail'), isFalse);
      expect(await service.markFailed('t-canc'), isFalse);
      expect(await service.markFailed('unknown'), isFalse);
    });

    test('cancelRunsFor relays the late-attached engine requester', () {
      final relayed = <String>[];
      final service = BackgroundTasksService();
      // v1: requester is absent — nothing explodes.
      service.cancelRunsFor('t-1');
      service.attachCancelRequester(relayed.add);
      service.cancelRunsFor('t-2');
      expect(relayed, ['t-2']);
    });
  });

  group('pause/resume lifecycle (bg lifecycle upgrade, Task 1)', () {
    test('pause flips running→paused and injects the pause notice via the '
        'sink', () async {
      final notices = <({String taskId, String content})>[];
      final db = _FakeTasksDb([_entity(id: 't-p', taskConversation: 'c-tp')]);
      final service = BackgroundTasksService(db)
        ..setNoticeSink(
          (taskId, content) async =>
              notices.add((taskId: taskId, content: content)),
        );

      expect(await service.pauseTask('t-p'), isTrue);
      expect(
        (await service.taskById('t-p'))!.state,
        BackgroundTaskState.paused,
      );
      expect(notices, hasLength(1));
      expect(notices.single.taskId, 't-p');
      // Verbatim template: `Background task paused by user at <HH:MM>`.
      expect(
        notices.single.content,
        matches(RegExp(r'^Background task paused by user at \d{2}:\d{2}$')),
      );
    });

    test('pause relays the cancel requester BEFORE the write (I1 mirror)',
        () async {
      final relays = <String>[];
      final db = _FailingWriteTasksDb([
        _entity(id: 't-live', taskConversation: 'c-live'),
      ]);
      final service = BackgroundTasksService(db, relays.add);

      await expectLater(service.pauseTask('t-live'), throwsStateError);
      expect(relays, ['t-live']);
    });

    test('pause is idempotent: re-pause returns true without a duplicate '
        'notice row', () async {
      final notices = <String>[];
      final db = _FakeTasksDb([_entity(id: 't-p', taskConversation: 'c-tp')]);
      final service = BackgroundTasksService(db)
        ..setNoticeSink((taskId, content) async => notices.add(content));

      expect(await service.pauseTask('t-p'), isTrue);
      expect(await service.pauseTask('t-p'), isTrue);
      expect(notices, hasLength(1));
    });

    test('resume flips paused→running, injects the verbatim resume notice '
        'and NEVER relays cancels', () async {
      final relays = <String>[];
      final notices = <String>[];
      final db = _FakeTasksDb(
        [_entity(id: 't-r', taskConversation: 'c-tr', state: 'paused')],
      );
      final service = BackgroundTasksService(db, relays.add)
        ..setNoticeSink((taskId, content) async => notices.add(content));

      expect(await service.resumeTask('t-r'), isTrue);
      expect(
        (await service.taskById('t-r'))!.state,
        BackgroundTaskState.running,
      );
      expect(
        notices.single,
        'Background task resumed — continue from where this task left off.',
      );
      expect(
        relays,
        isEmpty,
        reason: 'resume must only flip + notice; enqueuing is the caller',
      );
    });

    test('resume is idempotent on running rows: true, no notice', () async {
      final notices = <String>[];
      final db = _FakeTasksDb([_entity(id: 't-r', taskConversation: 'c-tr')]);
      final service = BackgroundTasksService(db)
        ..setNoticeSink((taskId, content) async => notices.add(content));

      expect(await service.resumeTask('t-r'), isTrue);
      expect(notices, isEmpty);
      expect(
        (await service.taskById('t-r'))!.state,
        BackgroundTaskState.running,
      );
    });

    test('terminal/unknown rows refuse pause and resume without notices',
        () async {
      final notices = <String>[];
      final db = _FakeTasksDb([
        _entity(id: 't-fin', state: 'finished', taskConversation: 'c-f'),
        _entity(id: 't-fail', state: 'failed', taskConversation: 'c-x'),
        _entity(id: 't-canc', state: 'cancelled', taskConversation: 'c-c'),
      ]);
      final service = BackgroundTasksService(db)
        ..setNoticeSink((taskId, content) async => notices.add(content));

      for (final id in ['t-fin', 't-fail', 't-canc', 't-missing']) {
        expect(await service.pauseTask(id), isFalse, reason: id);
        expect(await service.resumeTask(id), isFalse, reason: id);
      }
      expect(notices, isEmpty);
    });

    test('stop from paused: cancelTask flips paused→cancelled', () async {
      final db = _FakeTasksDb(
        [_entity(id: 't-p', taskConversation: 'c-tp', state: 'paused')],
      );
      final service = BackgroundTasksService(db);

      expect(await service.cancelTask('t-p'), isTrue);
      expect(
        (await service.taskById('t-p'))!.state,
        BackgroundTaskState.cancelled,
      );
      // Terminal now: resume refuses.
      expect(await service.resumeTask('t-p'), isFalse);
    });

    test('parked (paused) rows accept no run bookkeeping and no finish',
        () async {
      final db = _FakeTasksDb([_entity(id: 't-p', taskConversation: 'c-tp')]);
      final service = BackgroundTasksService(db);

      expect(await service.recordRun('t-p'), isTrue);
      await service.pauseTask('t-p');
      expect(await service.recordRun('t-p'), isFalse);
      expect(await service.markFinished('t-p'), isFalse);
      expect(await service.markFailed('t-p'), isFalse);
      expect(
        (await service.taskById('t-p'))!.state,
        BackgroundTaskState.paused,
      );
      expect((await service.taskById('t-p'))!.runCount, 1);
    });

    test('an absent notice sink never blocks transitions', () async {
      final db = _FakeTasksDb(
        [_entity(id: 't-p', taskConversation: 'c-tp', state: 'paused')],
      );
      final service = BackgroundTasksService(db);

      expect(await service.pauseTask('t-p'), isTrue);
      expect(await service.resumeTask('t-p'), isTrue);
    });

    test('a THROWING notice sink never surfaces: committed flips still '
        'return true (Task-1 review #2)', () async {
      final db = _FakeTasksDb([
        _entity(id: 't-pause', taskConversation: 'c-sp'),
        _entity(id: 't-resume', taskConversation: 'c-sr', state: 'paused'),
      ]);
      final service = BackgroundTasksService(db)
        ..setNoticeSink((taskId, content) async {
          throw StateError('notice row write exploded');
        });

      // The state flip is already committed — a sink failure is caught and
      // logged (Log.error), never propagated as a transition failure.
      expect(await service.pauseTask('t-pause'), isTrue);
      expect(
        (await service.taskById('t-pause'))!.state,
        BackgroundTaskState.paused,
      );
      expect(await service.resumeTask('t-resume'), isTrue);
      expect(
        (await service.taskById('t-resume'))!.state,
        BackgroundTaskState.running,
      );
    });
  });
}

BackgroundTaskEntity _entity({
  String id = 't-1',
  String owner = 'c1',
  String taskConversation = 'c-task-x',
  String state = 'running',
  int internalId = 0,
  DateTime? createdAt,
}) {
  return BackgroundTaskEntity(
    internalId: internalId,
    id: id,
    ownerConversationId: owner,
    taskConversationId: taskConversation,
    prompt: 'p',
    loopMinutes: 0,
    maxRuns: 10,
    state: state,
    createdAt: createdAt ?? DateTime.utc(2026, 10, 9),
  );
}

Conversation _conversation(
  String id, {
  bool isFork = false,
  bool isBackground = false,
  bool isTemporary = false,
}) {
  return Conversation(
    id: id,
    title: 'c-$id',
    createdAt: DateTime.utc(2026, 10, 9),
    updatedAt: DateTime.utc(2026, 10, 9),
    forkOfMessageId: isFork ? 'a-1' : null,
    forkSpan: isFork ? '{"text":"x"}' : null,
    isFork: isFork,
    isBackground: isBackground,
    isTemporary: isTemporary,
  );
}

class _Seeded extends conv.ConversationsNotifier {
  _Seeded(this.rows);

  final List<Conversation> rows;

  @override
  Future<List<Conversation>> build() async => rows;
}

/// Persistence-boundary fake: a [Store]-bridging [ObjectBoxStore] double.
/// The bridge runs transaction callbacks inline against the row lists, so
/// every service static is exercised without libobjectbox.so (fixture
/// style follows fork_service_test.dart).
class _FakeTasksDb extends Fake implements ObjectBoxStore {
  _FakeTasksDb(
    this.rows, {
    this.conversations = const [],
    this.messages = const [],
  }) {
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].internalId == 0) rows[i].internalId = i + 1;
    }
  }

  final List<BackgroundTaskEntity> rows;
  final List<ConversationEntity> conversations;
  final List<MessageEntity> messages;

  int rowCount() => rows.length;

  @override
  Store get store => _FakeTxStore(rows);

  @override
  Box<ConversationEntity> get conversationBox =>
      _FakeEntityBox<ConversationEntity>(conversations);

  @override
  Box<MessageEntity> get messageBox => _FakeEntityBox<MessageEntity>(messages);
}

class _FakeTxStore extends Fake implements Store {
  _FakeTxStore(this.taskRows);

  final List<BackgroundTaskEntity> taskRows;

  @override
  Future<R> runInTransactionAsync<R, T>(
    TxMode mode,
    R Function(Store, T) fn,
    T args,
  ) async => fn(this, args);

  @override
  Box<T> box<T>() => _FakeTaskBox(taskRows) as Box<T>;
}

/// Args-failing store: every write transaction throws — pins the I1
/// relay-before-write ordering on cancelTask.
class _FailingWriteTasksDb extends _FakeTasksDb {
  _FailingWriteTasksDb(super.rows);

  @override
  Store get store => _FailingTxStore(rows);
}

class _FailingTxStore extends _FakeTxStore {
  _FailingTxStore(super.taskRows);

  @override
  Future<R> runInTransactionAsync<R, T>(
    TxMode mode,
    R Function(Store, T) fn,
    T args,
  ) async {
    throw StateError('simulated write failure');
  }
}

class _FakeTaskBox extends Fake implements Box<BackgroundTaskEntity> {
  _FakeTaskBox(this.rows);

  final List<BackgroundTaskEntity> rows;

  @override
  QueryBuilder<BackgroundTaskEntity> query(
          [Condition<BackgroundTaskEntity>? qc]) =>
      _FakeQueryBuilder<BackgroundTaskEntity>(rows);

  @override
  int put(BackgroundTaskEntity entity, {PutMode mode = PutMode.put}) {
    final existingIndex = entity.internalId == 0
        ? -1
        : rows.indexWhere((row) => row.internalId == entity.internalId);
    if (existingIndex >= 0) {
      rows[existingIndex] = entity;
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

class _FakeEntityBox<T> extends Fake implements Box<T> {
  _FakeEntityBox(this.rows);

  final List<T> rows;

  @override
  QueryBuilder<T> query([Condition<T>? qc]) => _FakeQueryBuilder<T>(rows);
}

class _FakeQueryBuilder<T> extends Fake implements QueryBuilder<T> {
  _FakeQueryBuilder(this.rows);

  final List<T> rows;

  @override
  Query<T> build() => _FakeQuery<T>(rows);
}

class _FakeQuery<T> extends Fake implements Query<T> {
  _FakeQuery(this.rows);

  final List<T> rows;

  @override
  List<T> find() => List.of(rows);

  @override
  T? findFirst() => rows.isEmpty ? null : rows.first;

  @override
  void close() {}
}
