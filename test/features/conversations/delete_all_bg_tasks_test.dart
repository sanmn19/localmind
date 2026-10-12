import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/features/chat/data/background_task_service.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/objectbox.g.dart';

// Review M8: ConversationsNotifier.deleteAll must lift the WHOLE background
// task table (including rows whose owner conversation row is already gone)
// before wiping messages/conversations, and wake each live loop through the
// engine cancel seam.
//
// House fake convention: the persistence boundary is a Fake ObjectBoxStore
// double run inline (fork_service_test.dart style) — no libobjectbox.so in
// the host toolchain.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('deleteAll wipes task rows (+ cancel relays) then messages/conversations',
      () async {
    final cancellations = <String>[];
    final db = _WipeDb(
      taskRows: [
        BackgroundTaskEntity(
          id: 't-1',
          ownerConversationId: 'owner-1',
          taskConversationId: 'bg-1',
          prompt: 'p',
          loopMinutes: 0,
          maxRuns: 10,
          state: 'running',
          createdAt: DateTime.utc(2026, 10, 9),
        ),
        BackgroundTaskEntity(
          id: 't-dangling',
          ownerConversationId: 'owner-vanished',
          taskConversationId: 'bg-2',
          prompt: 'p',
          loopMinutes: 0,
          maxRuns: 10,
          state: 'running',
          createdAt: DateTime.utc(2026, 10, 9),
        ),
      ],
      conversations: [
        ConversationEntity(
          id: 'owner-1',
          title: 'Owner',
          createdAt: DateTime.utc(2026, 10, 9),
          updatedAt: DateTime.utc(2026, 10, 9),
        ),
      ],
      messages: [
        MessageEntity(
          id: 'm-1',
          conversationUid: 'owner-1',
          roleIndex: MessageRole.user.index,
          content: 'hello',
          createdAt: DateTime.utc(2026, 10, 9),
          statusIndex: MessageStatus.complete.index,
        ),
      ],
    );
    final service = BackgroundTasksService(db, cancellations.add);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backgroundTasksServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);

    // The notification/tap wiring reads pre-wipe state: both rows resident.
    expect(db.taskRows, hasLength(2));
    expect(db.messages, hasLength(1));

    await container.read(conv.conversationsProvider.future);
    await container.read(conv.conversationsProvider.notifier).deleteAll();

    // The task table is swept entirely — the dangling-owner row too.
    expect(db.taskRows, isEmpty);
    // Each removed task id woke the engine cancel seam.
    expect(cancellations, containsAll(['t-1', 't-dangling']));
    expect(cancellations, hasLength(2));

    // Then the wipe proceeds (task rows were the only thing between).
    expect(db.messages, isEmpty);
    expect(db.conversations, isEmpty);
    expect(container.read(conv.conversationsProvider).value ?? [], isEmpty);
  });
}

class _WipeDb extends Fake implements ObjectBoxStore {
  _WipeDb({
    required this.taskRows,
    required this.conversations,
    required this.messages,
  });

  final List<BackgroundTaskEntity> taskRows;
  final List<ConversationEntity> conversations;
  final List<MessageEntity> messages;

  @override
  Store get store => _WipeTxStore(this);

  @override
  Box<ConversationEntity> get conversationBox =>
      _WipeBox<ConversationEntity>(conversations);

  @override
  Box<MessageEntity> get messageBox => _WipeBox<MessageEntity>(messages);
}

class _WipeTxStore extends Fake implements Store {
  _WipeTxStore(this.db);

  final _WipeDb db;

  @override
  Future<R> runInTransactionAsync<R, T>(
    TxMode mode,
    R Function(Store, T) fn,
    T args,
  ) async => fn(this, args);

  @override
  Box<T> box<T>() {
    if (T == BackgroundTaskEntity) {
      return _WipeBox<T>(db.taskRows as List<T>);
    }
    if (T == ConversationEntity) {
      return _WipeBox<T>(db.conversations as List<T>);
    }
    if (T == MessageEntity) {
      return _WipeBox<T>(db.messages as List<T>);
    }
    throw UnimplementedError('unmapped box type $T');
  }
}

class _WipeBox<T> extends Fake implements Box<T> {
  _WipeBox(this.rows);

  final List<T> rows;

  @override
  QueryBuilder<T> query([Condition<T>? qc]) => _WipeQueryBuilder<T>(rows);

  @override
  List<T> getAll() => List.of(rows);

  @override
  int put(T entity, {PutMode mode = PutMode.put}) {
    rows.add(entity);
    return 1;
  }

  @override
  int removeMany(List<int> ids) {
    final before = rows.length;
    final keep = rows
        .where((row) => !ids.contains((row as dynamic).internalId as int))
        .toList();
    rows
      ..clear()
      ..addAll(keep);
    return before - rows.length;
  }

  @override
  int removeAll() {
    final removed = rows.length;
    rows.clear();
    return removed;
  }
}

class _WipeQueryBuilder<T> extends Fake implements QueryBuilder<T> {
  _WipeQueryBuilder(this.rows);

  final List<T> rows;

  @override
  Query<T> build() => _WipeQuery<T>(rows);
}

class _WipeQuery<T> extends Fake implements Query<T> {
  _WipeQuery(this.rows);

  final List<T> rows;

  @override
  List<T> find() => List.of(rows);

  @override
  T? findFirst() => rows.isEmpty ? null : rows.first;

  @override
  void close() {}
}
