import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/objectbox.g.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';

// Task 1 of the background lifecycle upgrade: the notice-row writer behind
// `BackgroundTasksService.setNoticeSink`. The pause/resume rows must land as
// USER-role rows (system role is FORBIDDEN for injected rows — the LM-Studio
// service folds the first system row into its prompt) at the task thread's
// next free thread order, on the SAME MessageEntity path the engine result
// rows use, and must pass shouldIncludeMessageInChatContext so they ride the
// wire on every subsequent run (the child sees its own pause history).
//
// Persistence fakes at the ObjectBoxStore boundary (fork_service_test probe
// convention) so the host toolchain never loads libobjectbox.so.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('notice rows persist user-role with a continuing threadOrder',
      () async {
    final db = _FakeNoticeDb([
      MessageEntity(
        id: 'm-prompt',
        conversationUid: 'c-task',
        roleIndex: MessageRole.user.index,
        content: 'watch the mail',
        createdAt: DateTime.utc(2026, 10, 12, 9),
        statusIndex: MessageStatus.complete.index,
        threadOrder: 0,
      ),
      MessageEntity(
        id: 'm-reply',
        conversationUid: 'c-task',
        roleIndex: MessageRole.assistant.index,
        content: 'Watching.',
        createdAt: DateTime.utc(2026, 10, 12, 9, 1),
        statusIndex: MessageStatus.complete.index,
        threadOrder: 1,
      ),
    ]);

    await persistBackgroundNoticeRow(
      db,
      'c-task',
      'Background task paused by user at 14:31',
    );
    await persistBackgroundNoticeRow(
      db,
      'c-task',
      'Background task resumed — continue from where this task left off.',
    );

    final notices = db.messages
        .where((row) => row.id != 'm-prompt' && row.id != 'm-reply')
        .toList();
    expect(notices, hasLength(2));
    for (final row in notices) {
      expect(row.conversationUid, 'c-task');
      // User role only: the service folds away injected system rows.
      expect(row.roleIndex, MessageRole.user.index);
      expect(row.isActiveVariant, isTrue);
      expect(row.statusIndex, MessageStatus.complete.index);
      // Wire-safe: the row rider re-enters every subsequent run's context.
      expect(shouldIncludeMessageInChatContext(row.toDomain()), isTrue);
    }
    final domainContents = notices.map((row) => row.toDomain().content);
    expect(
      domainContents,
      containsAllInOrder(<String>[
        'Background task paused by user at 14:31',
        'Background task resumed — continue from where this task left off.',
      ]),
    );
    expect(
      notices.map((row) => row.threadOrder).toList()..sort(),
      [2, 3],
      reason: 'threadOrder continues past the task thread tail (max + 1)',
    );
    expect(notices.map((row) => row.id).toSet(), hasLength(2),
        reason: 'row ids are unique v4s, never reused');
  });

  test('an empty task thread lands the notice at threadOrder 0', () async {
    final db = _FakeNoticeDb(<MessageEntity>[]);
    await persistBackgroundNoticeRow(
      db,
      'c-task',
      'Background task paused by user at 14:31',
    );
    expect(db.messages, hasLength(1));
    expect(db.messages.single.threadOrder, 0);
    expect(db.messages.single.roleIndex, MessageRole.user.index);
    expect(
      db.messages.single.content,
      'Background task paused by user at 14:31',
    );
  });
}

/// Persistence-boundary fake: a [Store]-bridging [ObjectBoxStore] double
/// carrying only the message box the notice writer touches.
class _FakeNoticeDb extends Fake implements ObjectBoxStore {
  _FakeNoticeDb(this.messages);

  final List<MessageEntity> messages;

  @override
  Box<MessageEntity> get messageBox => _FakeMessageBox(messages);
}

class _FakeMessageBox extends Fake implements Box<MessageEntity> {
  _FakeMessageBox(this.rows);

  final List<MessageEntity> rows;

  @override
  QueryBuilder<MessageEntity> query([Condition<MessageEntity>? qc]) =>
      _FakeQueryBuilder<MessageEntity>(rows);

  @override
  int put(MessageEntity entity, {PutMode mode = PutMode.put}) {
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
