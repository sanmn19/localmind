import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart';
import 'package:localmind/objectbox.g.dart';

// Regression: two state reloads can overlap (message completion, title,
// smart replies, cloud sync). A read that started before a chat was created
// used to land last and replace the list that already contained that chat:
// the row existed in ObjectBox but the chat was missing from history until
// the next rebuild. The notifier now tags every load with a revision and
// re-reads when a newer mutation landed meanwhile.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a stale reload cannot drop a chat created while it was reading',
    () async {
      final existing = ConversationEntity(
        id: 'existing',
        title: 'Existing chat',
        createdAt: DateTime.utc(2026, 11, 27),
        updatedAt: DateTime.utc(2026, 11, 27),
      );
      final db = _RaceDb(conversations: [existing], messages: []);
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      await container.read(conversationsProvider.future);

      // Hold the next reload's read, snapshotting the box before the new chat
      // exists — exactly what a slow in-flight reload carries.
      final gate = Completer<void>();
      final readStarted = Completer<void>();
      db.gateNextRead(gate.future, readStarted);

      final staleReload = container
          .read(conversationsProvider.notifier)
          .updatePreview(
            'existing',
            'new preview',
            DateTime.utc(2026, 11, 27, 1),
          );
      await readStarted.future;

      final created = await container
          .read(conversationsProvider.notifier)
          .createConversation(title: 'created during reload');

      gate.complete();
      await staleReload;

      final state = container.read(conversationsProvider).value!;
      expect(state.map((c) => c.id), contains(created.id));
      expect(state.map((c) => c.id), contains(existing.id));
    },
  );
}

class _RaceDb extends Fake implements ObjectBoxStore {
  _RaceDb({required this.conversations, required this.messages});

  final List<ConversationEntity> conversations;
  final List<MessageEntity> messages;
  final List<ForkAnchorEntity> anchors = [];

  Future<void>? _nextReadGate;
  Completer<void>? _started;

  void gateNextRead(Future<void> gate, Completer<void> started) {
    _nextReadGate = gate;
    _started = started;
  }

  @override
  Store get store => _RaceStore(this);

  @override
  Box<ConversationEntity> get conversationBox =>
      _RaceBox<ConversationEntity>(conversations);

  @override
  Box<MessageEntity> get messageBox => _RaceBox<MessageEntity>(messages);

  Future<void>? takeReadGate() {
    final gate = _nextReadGate;
    _nextReadGate = null;
    if (gate != null) {
      _started?.complete();
      _started = null;
    }
    return gate;
  }
}

class _RaceStore extends Fake implements Store {
  _RaceStore(this.db);

  final _RaceDb db;

  @override
  Future<R> runInTransactionAsync<R, T>(
    TxMode mode,
    R Function(Store, T) fn,
    T args,
  ) async {
    if (mode == TxMode.write) return fn(this, args);
    final gate = db.takeReadGate();
    if (gate == null) return fn(this, args);
    // Snapshot BEFORE waiting: the stale list a slow read would assign.
    final snapshot = List<ConversationEntity>.of(db.conversations);
    await gate;
    return fn(_SnapshotStore(db, snapshot), args);
  }

  @override
  Box<T> box<T>() {
    if (T == ConversationEntity) {
      return _RaceBox<ConversationEntity>(db.conversations) as Box<T>;
    }
    if (T == MessageEntity) {
      return _RaceBox<MessageEntity>(db.messages) as Box<T>;
    }
    if (T == ForkAnchorEntity) {
      return _RaceBox<ForkAnchorEntity>(db.anchors) as Box<T>;
    }
    throw UnimplementedError('unmapped box type $T');
  }
}

class _SnapshotStore extends Fake implements Store {
  _SnapshotStore(this.db, this.conversations);

  final _RaceDb db;
  final List<ConversationEntity> conversations;

  @override
  Box<T> box<T>() {
    if (T == ConversationEntity) {
      return _RaceBox<ConversationEntity>(conversations) as Box<T>;
    }
    if (T == MessageEntity) {
      return _RaceBox<MessageEntity>(db.messages) as Box<T>;
    }
    if (T == ForkAnchorEntity) {
      return _RaceBox<ForkAnchorEntity>(db.anchors) as Box<T>;
    }
    throw UnimplementedError('unmapped box type $T');
  }
}

class _RaceBox<T> extends Fake implements Box<T> {
  _RaceBox(this.rows);

  final List<T> rows;

  @override
  List<T> getAll() => List<T>.of(rows);

  @override
  QueryBuilder<T> query([Condition<T>? qc]) => _RaceQueryBuilder<T>(rows);

  @override
  int put(T entity, {PutMode mode = PutMode.put}) {
    if (entity is ConversationEntity) {
      final index = rows.indexWhere(
        (row) => row is ConversationEntity && row.id == entity.id,
      );
      if (index >= 0) {
        rows[index] = entity;
      } else {
        if (entity.internalId == 0) entity.internalId = rows.length + 1;
        rows.add(entity);
      }
      return entity.internalId;
    }
    rows.add(entity);
    return rows.length;
  }
}

class _RaceQueryBuilder<T> extends Fake implements QueryBuilder<T> {
  _RaceQueryBuilder(this.rows);

  final List<T> rows;

  @override
  Query<T> build() => _RaceQuery<T>(rows);
}

class _RaceQuery<T> extends Fake implements Query<T> {
  _RaceQuery(this.rows);

  final List<T> rows;

  @override
  T? findFirst() => rows.isEmpty ? null : rows.first;

  @override
  List<T> find() => List<T>.of(rows);

  @override
  void close() {}
}
