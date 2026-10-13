import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/objectbox.g.dart';
import 'package:localmind/features/ask_local/data/ask_local_conversation_service.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';

// Task 1 of the ask-local-overlay feature: the `specialKind` conversation
// marker plus the Ask Local conversation service's resolve-or-create
// contract (transactional first-wins, legacy-title stamping).
//
// ObjectBox-backed operations run against the native libobjectbox.so, which
// the host unit-test toolchain does not ship (probe convention documented in
// fork_service_test.dart) — persistence is faked at the ObjectBoxStore
// boundary here; real-box semantics are covered by mapping round-trip tests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AskLocalConversationService.ensure', () {
    test('creates once and returns the SAME id across repeat calls', () async {
      final db = _FakeAskLocalDb([]);
      final service = AskLocalConversationService(db);

      final first = await service.ensure();
      final second = await service.ensure();
      final third = await service.ensure();

      expect(first.id, second.id);
      expect(second.id, third.id);
      expect(db.conversations, hasLength(1));

      final row = db.conversations.single;
      expect(row.id, first.id);
      expect(row.title, askLocalConversationTitle);
      expect(row.specialKind, askLocalConversationKind);
      expect(row.isArchived, isFalse);
      expect(first.specialKind, askLocalConversationKind);
      expect(first.title, askLocalConversationTitle);
      expect(first.isArchived, isFalse);
    });

    test('stamps the specialKind marker on ensure', () async {
      final db = _FakeAskLocalDb([]);
      final service = AskLocalConversationService(db);

      final ensured = await service.ensure();

      expect(db.conversations.single.specialKind, askLocalConversationKind);
      expect(ensured.specialKind, askLocalConversationKind);
    });

    test(
      'legacy tolerance: a conversation titled Ask Local with a null marker '
      'gets stamped, not duplicated',
      () async {
        final legacy = ConversationEntity(
          id: 'legacy-1',
          title: askLocalConversationTitle,
          createdAt: DateTime.utc(2026, 10, 1),
          updatedAt: DateTime.utc(2026, 10, 1),
          isArchived: true,
        );
        final db = _FakeAskLocalDb([legacy]);
        final service = AskLocalConversationService(db);

        final ensured = await service.ensure();
        final again = await service.ensure();

        expect(ensured.id, 'legacy-1');
        expect(again.id, 'legacy-1');
        expect(db.conversations, hasLength(1));
        expect(legacy.specialKind, askLocalConversationKind);
      },
    );

    test('legacy stamping picks the oldest titled row deterministically',
        () async {
      final older = ConversationEntity(
        id: 'legacy-old',
        title: askLocalConversationTitle,
        createdAt: DateTime.utc(2026, 10, 1),
        updatedAt: DateTime.utc(2026, 10, 1),
      );
      final newer = ConversationEntity(
        id: 'legacy-new',
        title: askLocalConversationTitle,
        createdAt: DateTime.utc(2026, 10, 2),
        updatedAt: DateTime.utc(2026, 10, 2),
      );
      final db = _FakeAskLocalDb([newer, older]);
      final service = AskLocalConversationService(db);

      final ensured = await service.ensure();

      expect(ensured.id, 'legacy-old');
      expect(older.specialKind, askLocalConversationKind);
      expect(newer.specialKind, isNull);
    });

    test('legacy stamping ignores temporary chats', () async {
      final temp = ConversationEntity(
        id: 'legacy-temp',
        title: askLocalConversationTitle,
        createdAt: DateTime.utc(2026, 10, 1),
        updatedAt: DateTime.utc(2026, 10, 1),
        isTemporary: true,
      );
      final db = _FakeAskLocalDb([temp]);
      final service = AskLocalConversationService(db);

      final ensured = await service.ensure();

      expect(ensured.id, isNot('legacy-temp'));
      expect(ensured.isTemporary, isFalse);
      expect(ensured.specialKind, askLocalConversationKind);
      expect(temp.specialKind, isNull);
      expect(db.conversations.map((c) => c.id), contains('legacy-temp'));
    });

    test('legacy stamping un-archives the stamped row', () async {
      final archived = ConversationEntity(
        id: 'legacy-archived',
        title: askLocalConversationTitle,
        createdAt: DateTime.utc(2026, 10, 1),
        updatedAt: DateTime.utc(2026, 10, 1),
        isArchived: true,
      );
      final db = _FakeAskLocalDb([archived]);
      final service = AskLocalConversationService(db);

      final ensured = await service.ensure();

      expect(ensured.id, 'legacy-archived');
      expect(ensured.isArchived, isFalse);
      expect(archived.isArchived, isFalse);
    });

    test('legacy stamping breaks equal-createdAt ties by id', () async {
      final tieB = ConversationEntity(
        id: 'tie-b',
        title: askLocalConversationTitle,
        createdAt: DateTime.utc(2026, 10, 5),
        updatedAt: DateTime.utc(2026, 10, 5),
      );
      final tieA = ConversationEntity(
        id: 'tie-a',
        title: askLocalConversationTitle,
        createdAt: DateTime.utc(2026, 10, 5),
        updatedAt: DateTime.utc(2026, 10, 5),
      );
      final db = _FakeAskLocalDb([tieB, tieA]);
      final service = AskLocalConversationService(db);

      final ensured = await service.ensure();

      expect(ensured.id, 'tie-a');
      expect(tieA.specialKind, askLocalConversationKind);
      expect(tieB.specialKind, isNull);
    });

    test('unrelated rows are never stamped or duped', () async {
      final other = ConversationEntity(
        id: 'c-other',
        title: 'Regular chat',
        createdAt: DateTime.utc(2026, 10, 3),
        updatedAt: DateTime.utc(2026, 10, 3),
      );
      final db = _FakeAskLocalDb([other]);
      final service = AskLocalConversationService(db);

      final ensured = await service.ensure();

      expect(other.specialKind, isNull);
      expect(db.conversations.map((c) => c.id), containsAll(['c-other']));
      expect(
        db.conversations
            .where((c) => c.specialKind == askLocalConversationKind),
        hasLength(1),
      );
      expect(ensured.id, isNot('c-other'));
    });

    test('ensure without a database throws StateError', () async {
      final service = AskLocalConversationService();

      await expectLater(service.ensure(), throwsStateError);
    });
  });

  group('Conversation.specialKind marker', () {
    test('defaults null; copyWith preserves on plain copies', () {
      final c = _conversation();
      expect(c.specialKind, isNull);
      expect(c.copyWith().specialKind, isNull);
    });

    test('copyWith sets specialKind and clearSpecialKind clears it', () {
      final marked = _conversation().copyWith(
        specialKind: askLocalConversationKind,
      );
      expect(marked.specialKind, askLocalConversationKind);

      final cleared = marked.copyWith(clearSpecialKind: true);
      expect(cleared.specialKind, isNull);

      final untouched = marked.copyWith().specialKind;
      expect(untouched, askLocalConversationKind);
    });

    test('ConversationEntity fromDomain/toDomain round-trips specialKind', () {
      final marked = _conversation(specialKind: askLocalConversationKind);
      final entity = ConversationEntity.fromDomain(marked);
      expect(entity.internalId, 0);
      final back = entity.toDomain();
      expect(back.specialKind, askLocalConversationKind);
      expect(back.title, marked.title);
      expect(back.id, marked.id);
      expect(back.createdAt, marked.createdAt);
      expect(back.updatedAt, marked.updatedAt);

      final unmarkedBack = ConversationEntity.fromDomain(_conversation())
          .toDomain();
      expect(unmarkedBack.specialKind, isNull);
    });
  });
}

Conversation _conversation({String? specialKind}) {
  return Conversation(
    id: 'c1',
    title: 'Test conv',
    createdAt: DateTime.utc(2026, 10, 8, 10),
    updatedAt: DateTime.utc(2026, 10, 8, 10),
    specialKind: specialKind,
  );
}

/// Persistence-boundary fake: a [Store]-bridging [ObjectBoxStore] double.
/// The bridge runs transaction callbacks inline against the row lists, so
/// every service static is exercised without libobjectbox.so (fixture
/// style follows background_task_service_test.dart).
class _FakeAskLocalDb extends Fake implements ObjectBoxStore {
  _FakeAskLocalDb(this.conversations) {
    for (var i = 0; i < conversations.length; i++) {
      if (conversations[i].internalId == 0) conversations[i].internalId = i + 1;
    }
  }

  final List<ConversationEntity> conversations;

  @override
  Store get store => _FakeTxStore(conversations);

  @override
  Box<ConversationEntity> get conversationBox =>
      _FakeConversationBox(conversations);
}

class _FakeTxStore extends Fake implements Store {
  _FakeTxStore(this.rows);

  final List<ConversationEntity> rows;

  @override
  Future<R> runInTransactionAsync<R, T>(
    TxMode mode,
    R Function(Store, T) fn,
    T args,
  ) async => fn(this, args);

  @override
  Box<T> box<T>() => _FakeConversationBox(rows) as Box<T>;
}

class _FakeConversationBox extends Fake implements Box<ConversationEntity> {
  _FakeConversationBox(this.rows);

  final List<ConversationEntity> rows;

  @override
  QueryBuilder<ConversationEntity> query(
          [Condition<ConversationEntity>? qc]) =>
      _FakeQueryBuilder<ConversationEntity>(rows);

  @override
  int put(ConversationEntity entity, {PutMode mode = PutMode.put}) {
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
