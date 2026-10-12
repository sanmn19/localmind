import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/storage_providers.dart';
import '../../../core/storage/entities.dart';
import '../../../core/storage/objectbox_store.dart';
import '../../../core/utils/uuid.dart';
import '../../../objectbox.g.dart';
import 'models/background_task.dart';

/// Background sub-agent task constants
/// (docs/specs/2026-10-09-background-subagents.md).
///
/// - [bgLoopMinutesFloor]: recurring tasks must loop every >= 10 minutes;
///   0/absent loopMinutes means single-run.
/// - [bgMaxRunsDefault] / [bgMaxRunsCap]: maxRuns defaults to 10 and is
///   clamped to at most 25.
/// - [bgMaxConcurrentTasks]: createTask refuses to start a new task once
///   this many rows are in the running state.
const int bgLoopMinutesFloor = 10;
const int bgMaxRunsDefault = 10;
const int bgMaxRunsCap = 25;
const int bgMaxConcurrentTasks = 3;

/// Engine-relay seam shape (Task 2 review ruling): a zero-or-nothing closure
/// wired to `cancelRunsFor`/delete cascades; the construction site decides
/// whether it is a genuine engine relay or a no-op.
typedef CancelRequester = void Function(String taskId);

/// CRUD + normalization for background-agent task rows living in the
/// `BackgroundTaskEntity` box (docs/specs/2026-10-09-background-subagents.md).
///
/// Row ownership: a task belongs to the conversation that spawned it
/// (`ownerConversationId`) and writes its turns into a hidden companion
/// conversation row (`isBackground: true`). Deleting an owner conversation
/// cascades its task rows via [deleteTasksOwnedBy]; live-run cancellation is
/// relayed through the [BackgroundTasksService.cancelRunsFor] seam which
/// Task 4 wires to the engine loop (see task-2-report.md).
///
/// ObjectBox-backed CRUD fakes cleanly at the persistence boundary: every
/// static background function re-filters the fetched rows in Dart on top of
/// the pushed-down query condition, mirroring the
/// condition-agnostic-fake convention of fork_service_test.dart.
class BackgroundTasksService {
  /// [_db] may be omitted when only pure normalization is needed
  /// (unit tests); persistence operations then throw [StateError].
  /// [cancelRequester] is the Task 4 engine seam; v1 omits it (no-op).
  BackgroundTasksService([this._db, CancelRequester? cancelRequester])
      : _cancelRequester = cancelRequester;

  final ObjectBoxStore? _db;

  /// Late-bound so the running engine can attach itself after the service
  /// provider was built (Task 4 engine wires [attachCancelRequester]).
  CancelRequester? _cancelRequester;

  /// Engine seam wiring (Task 4): replaces the ctor-time requester with the
  /// live engine hook. Safe to call repeatedly — the newest requester wins.
  void attachCancelRequester(CancelRequester requester) {
    _cancelRequester = requester;
  }

  ObjectBoxStore get _database {
    final db = _db;
    if (db == null) {
      throw StateError(
        'BackgroundTasksService persistence requires a database — construct '
        'via backgroundTasksServiceProvider.',
      );
    }
    return db;
  }

  /// Creates a task row for [taskConversationId], owned by
  /// [ownerConversationId].
  ///
  /// Normalization: absent/zero [loopMinutes] stores 0 (single-run),
  /// positive values below [bgLoopMinutesFloor] are floored to the floor;
  /// [maxRuns] defaults to [bgMaxRunsDefault] and is clamped to
  /// `[1, bgMaxRunsCap]`. Throws [StateError] when
  /// [bgMaxConcurrentTasks] rows are already running.
  Future<BackgroundTask> createTask({
    required String ownerConversationId,
    required String prompt,
    int? loopMinutes,
    int? maxRuns,
    required String taskConversationId,
  }) async {
    final db = _database;
    final input = _CreateTaskInput(
      id: generateUuidV4(),
      ownerConversationId: ownerConversationId,
      taskConversationId: taskConversationId,
      prompt: prompt,
      loopMinutes: normalizeLoopMinutes(loopMinutes),
      maxRuns: normalizeMaxRuns(maxRuns),
      createdAt: DateTime.now(),
    );
    return db.store.runInTransactionAsync(
      TxMode.write,
      _createTaskInBackground,
      input,
    );
  }

  /// All tasks owned by [ownerConversationId], oldest first.
  Future<List<BackgroundTask>> tasksFor(String ownerConversationId) async {
    final db = _database;
    return db.store.runInTransactionAsync(
      TxMode.read,
      _tasksForInBackground,
      ownerConversationId,
    );
  }

  /// Rows currently in the running state, across all owners.
  Future<int> runningCount() async {
    final db = _database;
    return db.store.runInTransactionAsync(
      TxMode.read,
      _runningCountInBackground,
      null,
    );
  }

  /// Marks [taskId] cancelled. Idempotent: cancelling an already-cancelled
  /// task returns true without re-writing; finished/failed rows are
  /// terminal and refuse the regression (false); unknown ids return false.
  Future<bool> cancelTask(String taskId) async {
    final db = _database;
    return db.store.runInTransactionAsync(
      TxMode.write,
      _cancelTaskInBackground,
      taskId,
    );
  }

  /// Marks [taskId] finished. Idempotent: the first recorded
  /// [resultMessageId]/[ownerMessageId] win; calls on already-finished rows
  /// return true without overwriting the ids, calls on
  /// cancelled/failed/unknown rows return false.
  Future<bool> markFinished(
    String taskId, {
    String? resultMessageId,
    String? ownerMessageId,
  }) async {
    final db = _database;
    return db.store.runInTransactionAsync(
      TxMode.write,
      _markFinishedInBackground,
      _FinishInput(
        taskId: taskId,
        resultMessageId: resultMessageId,
        ownerMessageId: ownerMessageId,
      ),
    );
  }

  /// Deletes every task owned by [ownerConversationId]. Deletes the rows
  /// first, then relays one [cancelRunsFor] request per removed task id so
  /// live loops wind down through the engine seam.
  Future<bool> deleteTasksOwnedBy(String ownerConversationId) async {
    final db = _database;
    final removedIds = await db.store.runInTransactionAsync(
      TxMode.write,
      _deleteTasksOwnedInBackground,
      ownerConversationId,
    );
    for (final id in removedIds) {
      _cancelRequester?.call(id);
    }
    return removedIds.isNotEmpty;
  }

  /// Resolves one task row by its unique task id (authoritative state
  /// inspection seam for the engine's per-step polls).
  Future<BackgroundTask?> taskById(String taskId) async {
    final db = _database;
    return db.store.runInTransactionAsync(
      TxMode.read,
      _taskByIdInBackground,
      taskId,
    );
  }

  /// Records one engine run for [taskId]: bumps [BackgroundTask.runCount]
  /// and stamps `lastRunAt`. Only rows in the running state accept a run
  /// record (terminal rows are committed); returns whether the run counted.
  Future<bool> recordRun(String taskId) async {
    final db = _database;
    return db.store.runInTransactionAsync(
      TxMode.write,
      _recordRunInBackground,
      taskId,
    );
  }

  /// Marks [taskId] failed on an unhandled engine error. Only a running row
  /// moves to failed (terminal states stay committed); unknown ids return
  /// false.
  Future<bool> markFailed(String taskId) async {
    final db = _database;
    return db.store.runInTransactionAsync(
      TxMode.write,
      _markFailedInBackground,
      taskId,
    );
  }

  /// Relays a live-run cancel request for [taskId] to the engine
  /// (Task 4 seam). v1: injected requester is absent → no-op.
  void cancelRunsFor(String taskId) => _cancelRequester?.call(taskId);

  static int normalizeLoopMinutes(int? loopMinutes) {
    if (loopMinutes == null || loopMinutes <= 0) return 0;
    return loopMinutes < bgLoopMinutesFloor ? bgLoopMinutesFloor : loopMinutes;
  }

  static int normalizeMaxRuns(int? maxRuns) {
    if (maxRuns == null) return bgMaxRunsDefault;
    if (maxRuns < 1) return 1;
    return maxRuns > bgMaxRunsCap ? bgMaxRunsCap : maxRuns;
  }

  static BackgroundTask _createTaskInBackground(
    Store store,
    _CreateTaskInput input,
  ) {
    final box = store.box<BackgroundTaskEntity>();
    final query = box
        .query(
          BackgroundTaskEntity_.state.equals(BackgroundTaskState.running.name),
        )
        .build();
    final fetched = query.find();
    query.close();

    final running = fetched
        .where((row) => row.state == BackgroundTaskState.running.name)
        .length;
    if (running >= bgMaxConcurrentTasks) {
      throw StateError(
        'Background task concurrency cap reached ($bgMaxConcurrentTasks '
        'running tasks); cancel one before starting another.',
      );
    }

    final task = BackgroundTask(
      id: input.id,
      ownerConversationId: input.ownerConversationId,
      taskConversationId: input.taskConversationId,
      prompt: input.prompt,
      loopMinutes: input.loopMinutes,
      maxRuns: input.maxRuns,
      createdAt: input.createdAt,
    );
    box.put(BackgroundTaskEntity.fromDomain(task));
    return task;
  }

  static List<BackgroundTask> _tasksForInBackground(
    Store store,
    String ownerConversationId,
  ) {
    final box = store.box<BackgroundTaskEntity>();
    final query = box
        .query(
          BackgroundTaskEntity_.ownerConversationId
              .equals(ownerConversationId),
        )
        .build();
    final rows = query.find();
    query.close();

    final tasks = rows
        .where((row) => row.ownerConversationId == ownerConversationId)
        .map((row) => row.toDomain())
        .toList()
      ..sort((a, b) {
        final byDate = a.createdAt.compareTo(b.createdAt);
        if (byDate != 0) return byDate;
        return a.id.compareTo(b.id);
      });
    return tasks;
  }

  static int _runningCountInBackground(Store store, void _) {
    final box = store.box<BackgroundTaskEntity>();
    final query = box
        .query(
          BackgroundTaskEntity_.state.equals(BackgroundTaskState.running.name),
        )
        .build();
    final rows = query.find();
    query.close();
    return rows
        .where((row) => row.state == BackgroundTaskState.running.name)
        .length;
  }

  static bool _cancelTaskInBackground(Store store, String taskId) {
    final box = store.box<BackgroundTaskEntity>();
    final query = box.query(BackgroundTaskEntity_.id.equals(taskId)).build();
    final fetched = query.find();
    query.close();
    // Dart-side id filter keeps the condition-agnostic persistence fakes
    // authoritative (mirrors findFirst usage).
    final matches = fetched.where((row) => row.id == taskId).toList();
    if (matches.isEmpty) return false;
    final entity = matches.first;

    final current = _stateFromName(entity.state);
    switch (current) {
      case BackgroundTaskState.cancelled:
        return true; // idempotent re-cancel
      case BackgroundTaskState.running:
        entity.state = BackgroundTaskState.cancelled.name;
        box.put(entity);
        return true;
      case BackgroundTaskState.finished:
      case BackgroundTaskState.failed:
        return false; // terminal states refuse the regression
    }
  }

  static bool _markFinishedInBackground(Store store, _FinishInput input) {
    final box = store.box<BackgroundTaskEntity>();
    final query = box.query(BackgroundTaskEntity_.id.equals(input.taskId)).build();
    final fetched = query.find();
    query.close();
    final matches = fetched.where((row) => row.id == input.taskId).toList();
    if (matches.isEmpty) return false;
    final entity = matches.first;

    final current = _stateFromName(entity.state);
    switch (current) {
      case BackgroundTaskState.finished:
        return true; // idempotent: keep the first recorded ids
      case BackgroundTaskState.running:
        entity.state = BackgroundTaskState.finished.name;
        entity.resultMessageId = input.resultMessageId;
        entity.ownerMessageId = input.ownerMessageId;
        box.put(entity);
        return true;
      case BackgroundTaskState.cancelled:
      case BackgroundTaskState.failed:
        return false;
    }
  }

  static BackgroundTask? _taskByIdInBackground(Store store, String taskId) {
    final box = store.box<BackgroundTaskEntity>();
    final query = box.query(BackgroundTaskEntity_.id.equals(taskId)).build();
    final fetched = query.find();
    query.close();
    final matches = fetched.where((row) => row.id == taskId).toList();
    return matches.isEmpty ? null : matches.first.toDomain();
  }

  static bool _recordRunInBackground(Store store, String taskId) {
    final entity = _runningEntityIfExists(store, taskId);
    if (entity == null) return false;
    entity.runCount += 1;
    entity.lastRunAt = DateTime.now();
    store.box<BackgroundTaskEntity>().put(entity);
    return true;
  }

  static bool _markFailedInBackground(Store store, String taskId) {
    final entity = _runningEntityIfExists(store, taskId);
    if (entity == null) return false;
    entity.state = BackgroundTaskState.failed.name;
    store.box<BackgroundTaskEntity>().put(entity);
    return true;
  }

  /// Id-matched, running-state-checked entity load (Dart-side filters keep
  /// the condition-agnostic fakes authoritative — see task-2-report.md).
  static BackgroundTaskEntity? _runningEntityIfExists(
    Store store,
    String taskId,
  ) {
    final box = store.box<BackgroundTaskEntity>();
    final query = box.query(BackgroundTaskEntity_.id.equals(taskId)).build();
    final fetched = query.find();
    query.close();
    final matches =
        fetched.where((row) => row.id == taskId).toList();
    if (matches.isEmpty) return null;
    final entity = matches.first;
    if (_stateFromName(entity.state) != BackgroundTaskState.running) {
      return null;
    }
    return entity;
  }

  static List<String> _deleteTasksOwnedInBackground(
    Store store,
    String ownerConversationId,
  ) {
    final box = store.box<BackgroundTaskEntity>();
    final query = box
        .query(
          BackgroundTaskEntity_.ownerConversationId
              .equals(ownerConversationId),
        )
        .build();
    final rows = query.find();
    query.close();

    final owned = rows
        .where((row) => row.ownerConversationId == ownerConversationId)
        .toList();
    if (owned.isEmpty) return const [];

    box.removeMany(owned.map((row) => row.internalId).toList());
    return owned.map((row) => row.id).toList();
  }

  /// Same mapping rule the entity enforces (T1 review ruling): unknown
  /// stored state names degrade to failed, never to running.
  static BackgroundTaskState _stateFromName(String name) =>
      BackgroundTaskState.values.firstWhere(
        (s) => s.name == name,
        orElse: () => BackgroundTaskState.failed,
      );
}

/// Db-wired [BackgroundTasksService] for the app. Live-run cancellation is
/// not wired until Task 4's engine lands — v1 leaves the requester absent
/// (cancelRunsFor relays to a no-op).
final backgroundTasksServiceProvider = Provider<BackgroundTasksService>((ref) {
  return BackgroundTasksService(ref.watch(databaseProvider));
});

class _CreateTaskInput {
  _CreateTaskInput({
    required this.id,
    required this.ownerConversationId,
    required this.taskConversationId,
    required this.prompt,
    required this.loopMinutes,
    required this.maxRuns,
    required this.createdAt,
  });

  final String id;
  final String ownerConversationId;
  final String taskConversationId;
  final String prompt;
  final int loopMinutes;
  final int maxRuns;
  final DateTime createdAt;
}

class _FinishInput {
  _FinishInput({
    required this.taskId,
    required this.resultMessageId,
    required this.ownerMessageId,
  });

  final String taskId;
  final String? resultMessageId;
  final String? ownerMessageId;
}
