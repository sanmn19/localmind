import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/services/data_backup_service.dart';
import 'package:localmind/core/services/message_save_service.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/providers/chat_notifier.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/objectbox.g.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keeps updatedAt through the entity round-trip', () {
    final message = Message(
      id: 'm1',
      conversationId: 'c1',
      role: MessageRole.assistant,
      content: 'Hi',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 5),
    );
    final entity = MessageEntity.fromDomain(message);
    expect(entity.updatedAt, message.updatedAt);
    expect(entity.toDomain().updatedAt, message.updatedAt);
    expect(entity.toDomain().effectiveUpdatedAt, message.updatedAt);
  });

  test('falls back to createdAt when a stored message has no updatedAt', () {
    final entity = MessageEntity(
      id: 'm2',
      conversationUid: 'c1',
      roleIndex: 1,
      content: 'Old',
      createdAt: DateTime.utc(2026, 1, 1),
      statusIndex: 0,
    );
    expect(entity.toDomain().updatedAt, isNull);
    expect(entity.toDomain().effectiveUpdatedAt, DateTime.utc(2026, 1, 1));
  });

  test('export writes the effective updatedAt', () {
    final stamped = MessageEntity.fromDomain(
      Message(
        id: 'm1',
        conversationId: 'c1',
        role: MessageRole.assistant,
        content: 'New',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 5),
      ),
    );
    final legacy = MessageEntity.fromDomain(
      Message(
        id: 'm2',
        conversationId: 'c1',
        role: MessageRole.user,
        content: 'Old',
        createdAt: DateTime.utc(2026, 1, 2),
      ),
    );
    final store = _FakeStore({
      MessageEntity: _FakeBox<MessageEntity>([stamped, legacy], (m) => m.id),
    });

    final payload =
        jsonDecode(DataBackupService().exportConversationsAsJson(store))
            as Map<String, dynamic>;
    final messages = (payload['messages'] as List)
        .cast<Map<String, dynamic>>()
        .asMap();

    expect(
      messages[0]!['updatedAt'],
      DateTime.utc(2026, 1, 1, 0, 0, 5).toIso8601String(),
    );
    expect(
      messages[1]!['updatedAt'],
      DateTime.utc(2026, 1, 2).toIso8601String(),
    );
  });

  test('import falls back to createdAt when updatedAt is absent', () async {
    _mockDocumentsDirectory();
    final conversations = _FakeBox<ConversationEntity>([
      ConversationEntity.fromDomain(
        Conversation(
          id: 'c1',
          title: 'Chat',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      ),
    ], (c) => c.id);
    final messages = _FakeBox<MessageEntity>([], (m) => m.id);
    final store = _FakeStore({
      ConversationEntity: conversations,
      MessageEntity: messages,
    });

    await DataBackupService().importFromJson(
      store,
      jsonEncode({
        'conversations': [
          {
            'id': 'c1',
            'title': 'Chat',
            'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
            'updatedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          },
        ],
        'messages': [
          {
            'id': 'm1',
            'conversationId': 'c1',
            'role': 'assistant',
            'content': 'Hi',
            'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          },
          {
            'id': 'm2',
            'conversationId': 'c1',
            'role': 'assistant',
            'content': 'New',
            'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
            'updatedAt': DateTime.utc(2026, 1, 1, 0, 0, 5).toIso8601String(),
          },
          {
            'id': 'm3',
            'conversationId': 'c1',
            'role': 'user',
            'content': 'Corrupt',
            'createdAt': DateTime.utc(2026, 1, 2).toIso8601String(),
            'updatedAt': 'not-a-timestamp',
          },
        ],
      }),
    );

    final imported = {for (final m in messages.rows) m.id: m};
    expect(imported['m1']!.updatedAt, DateTime.utc(2026, 1, 1));
    expect(imported['m2']!.updatedAt, DateTime.utc(2026, 1, 1, 0, 0, 5));
    expect(imported['m3']!.updatedAt, DateTime.utc(2026, 1, 2));
  });

  test('enqueue stamps the saved message with a completion time', () async {
    final box = _FakeBox<MessageEntity>([], (m) => m.id);
    final store = _FakeStore({
      MessageEntity: box,
      ConversationEntity: _FakeBox<ConversationEntity>([], (c) => c.id),
    });
    final service = MessageSaveService(_FakeDb(store));
    addTearDown(service.dispose);

    final before = DateTime.now();
    service.enqueue(
      Message(
        id: 'm1',
        conversationId: 'c1',
        role: MessageRole.assistant,
        content: 'Hi',
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );
    await service.flush();

    final saved = box.rows.single;
    expect(saved.updatedAt, isNotNull);
    expect(saved.updatedAt!.isBefore(before), isFalse);
    expect(saved.toDomain().effectiveUpdatedAt, saved.updatedAt);
  });

  test('the final full-row save keeps the checkpoint timestamp', () async {
    final box = _FakeBox<MessageEntity>([], (m) => m.id);
    final store = _FakeStore({
      MessageEntity: box,
      ConversationEntity: _FakeBox<ConversationEntity>([], (c) => c.id),
    });
    final db = _FakeDb(store);
    final service = MessageSaveService(db);
    addTearDown(service.dispose);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        chatProvider.overrideWith(_TestChatNotifier.new),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(chatProvider.notifier);

    service.enqueue(
      Message(
        id: 'm1',
        conversationId: 'c1',
        role: MessageRole.assistant,
        content: 'partial',
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );
    await service.flush();
    final checkpoint = box.rows.single;
    expect(checkpoint.content, 'partial');
    expect(checkpoint.updatedAt, isNotNull);

    await notifier.debugSaveMessageForTest(
      Message(
        id: 'm1',
        conversationId: 'c1',
        role: MessageRole.assistant,
        content: 'done',
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );

    final saved = box.rows.single;
    expect(saved.content, 'done');
    expect(saved.updatedAt, isNotNull);
  });

  test('a null-stamp full-row save does not clear an existing stamp', () {
    final stamp = DateTime.utc(2026, 1, 1, 0, 0, 5);
    final box = _FakeBox<MessageEntity>([
      MessageEntity(
        id: 'm1',
        conversationUid: 'c1',
        roleIndex: MessageRole.assistant.index,
        content: 'old',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: stamp,
        statusIndex: MessageStatus.complete.index,
      ),
    ], (m) => m.id);
    final store = _FakeStore({
      MessageEntity: box,
      ConversationEntity: _FakeBox<ConversationEntity>([], (c) => c.id),
    });

    ChatNotifier.debugSaveMessageInBackgroundForTest(
      store,
      Message(
        id: 'm1',
        conversationId: 'c1',
        role: MessageRole.assistant,
        content: 'edited',
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );

    final saved = box.rows.single;
    expect(saved.content, 'edited');
    expect(saved.updatedAt, stamp);
  });

  test('a null-stamp checkpoint does not clear an existing stamp', () {
    final stamp = DateTime.utc(2026, 1, 1, 0, 0, 5);
    final box = _FakeBox<MessageEntity>([
      MessageEntity(
        id: 'm1',
        conversationUid: 'c1',
        roleIndex: MessageRole.assistant.index,
        content: 'old',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: stamp,
        statusIndex: MessageStatus.complete.index,
      ),
    ], (m) => m.id);
    final store = _FakeStore({
      MessageEntity: box,
      ConversationEntity: _FakeBox<ConversationEntity>([], (c) => c.id),
    });

    MessageSaveService.debugWriteBatchForTest(store, [
      Message(
        id: 'm1',
        conversationId: 'c1',
        role: MessageRole.assistant,
        content: 'edited',
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    ]);

    final saved = box.rows.single;
    expect(saved.content, 'edited');
    expect(saved.updatedAt, stamp);
  });
}

void _mockDocumentsDirectory() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'getApplicationDocumentsDirectory') {
      return '/tmp/localmind-test-documents';
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

class _FakeStore extends Fake implements Store {
  _FakeStore(this._boxes);

  final Map<Type, Object> _boxes;

  @override
  Box<T> box<T>() {
    final existing = _boxes[T];
    if (existing != null) return existing as Box<T>;
    final created = _FakeBox<T>();
    _boxes[T] = created;
    return created;
  }

  @override
  Future<R> runInTransactionAsync<R, T>(
    TxMode mode,
    R Function(Store, T) fn,
    T arg,
  ) async => fn(this, arg);
}

class _FakeBox<T> extends Fake implements Box<T> {
  _FakeBox([List<T>? items, String Function(T)? idOf]) : _idOf = idOf {
    for (final item in items ?? <T>[]) {
      _rows[_idOf!(item)] = item;
    }
  }

  final String Function(T)? _idOf;
  final Map<String, T> _rows = {};

  List<T> get rows => _rows.values.toList();

  @override
  List<T> getAll() => _rows.values.toList();

  @override
  QueryBuilder<T> query([Condition<T>? qc]) => _FakeQueryBuilder<T>(this);

  @override
  int put(T object, {PutMode mode = PutMode.put}) {
    _rows[_idOf!(object)] = object;
    return 1;
  }
}

class _FakeQueryBuilder<T> extends Fake implements QueryBuilder<T> {
  _FakeQueryBuilder(this._box);

  final _FakeBox<T> _box;

  @override
  Query<T> build() => _FakeQuery<T>(_box);
}

class _FakeQuery<T> extends Fake implements Query<T> {
  _FakeQuery(this._box);

  final _FakeBox<T> _box;

  @override
  T? findFirst() => _box.rows.isEmpty ? null : _box.rows.first;

  @override
  void close() {}
}

class _FakeDb extends Fake implements ObjectBoxStore {
  _FakeDb(this._store);

  final _FakeStore _store;

  @override
  Store get store => _store;
}

class _TestChatNotifier extends ChatNotifier {
  @override
  ChatState build() => const ChatState();
}
