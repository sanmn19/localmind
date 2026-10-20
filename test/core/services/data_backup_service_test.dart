import 'dart:convert';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/services/data_backup_service.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/memories/data/models/memory.dart';
import 'package:localmind/features/personas/data/models/persona.dart';
import 'package:localmind/objectbox.g.dart';

void main() {
  test('conversation exports include the referenced folder metadata', () {
    final folder = ConversationFolderEntity(
      id: 'folder-1',
      name: 'Inbox',
      sortOrder: 3,
      createdAt: DateTime.utc(2026, 7, 5),
    );
    final otherFolder = ConversationFolderEntity(
      id: 'folder-2',
      name: 'Archive',
      sortOrder: 9,
      createdAt: DateTime.utc(2026, 7, 4),
    );
    final conversation = ConversationEntity.fromDomain(
      Conversation(
        id: 'conv-1',
        title: 'Exported Chat',
        createdAt: DateTime.utc(2026, 7, 5),
        updatedAt: DateTime.utc(2026, 7, 5),
        folderId: folder.id,
      ),
    );
    final otherConversation = ConversationEntity.fromDomain(
      Conversation(
        id: 'conv-2',
        title: 'Different Chat',
        createdAt: DateTime.utc(2026, 7, 5),
        updatedAt: DateTime.utc(2026, 7, 5),
        folderId: otherFolder.id,
      ),
    );

    final store = _FakeStore({
      ConversationEntity: _FakeBox([conversation, otherConversation]),
      MessageEntity: _FakeBox<MessageEntity>(const []),
      PersonaEntity: _FakeBox<PersonaEntity>(const []),
      SavedMessageEntity: _FakeBox<SavedMessageEntity>(const []),
      SavedMessageFolderEntity: _FakeBox<SavedMessageFolderEntity>(const []),
      ServerEntity: _FakeBox<ServerEntity>(const []),
      ConversationFolderEntity: _FakeBox([folder, otherFolder]),
    });

    final service = DataBackupService();

    final allExport =
        jsonDecode(service.exportConversationsAsJson(store))
            as Map<String, dynamic>;
    expect(
      (allExport['conversationFolders'] as List)
          .cast<Map<String, dynamic>>()
          .map((folder) => folder['id'])
          .toSet(),
      {folder.id, otherFolder.id},
    );

    final singleExport =
        jsonDecode(service.exportConversationAsJson(store, conversation.id))
            as Map<String, dynamic>;
    expect(
      (singleExport['conversationFolders'] as List)
          .cast<Map<String, dynamic>>()
          .single['id'],
      folder.id,
    );

    final filteredExport =
        jsonDecode(
              service.exportConversationsForIdsAsJson(store, {
                otherConversation.id,
              }),
            )
            as Map<String, dynamic>;
    expect(
      (filteredExport['conversationFolders'] as List)
          .cast<Map<String, dynamic>>()
          .single['id'],
      otherFolder.id,
    );
  });

  test('cloud export excludes temporary chats, built-ins, and secrets', () async {
    final persistent = ConversationEntity.fromDomain(
      Conversation(
        id: 'persistent',
        title: 'Persistent',
        createdAt: DateTime.utc(2026, 7, 10),
        updatedAt: DateTime.utc(2026, 7, 10),
      ),
    );
    final temporary = ConversationEntity.fromDomain(
      Conversation(
        id: 'temporary',
        title: 'Temporary',
        createdAt: DateTime.utc(2026, 7, 10),
        updatedAt: DateTime.utc(2026, 7, 10),
        isTemporary: true,
      ),
    );
    MessageEntity message(String id, String conversationId) =>
        MessageEntity.fromDomain(
          Message(
            id: id,
            conversationId: conversationId,
            role: MessageRole.assistant,
            content: 'Hello',
            createdAt: DateTime.utc(2026, 7, 10),
            inputTokenCount: 4,
            tokensPerSecond: 12.5,
            ttftMs: 100,
            stopReason: 'stop',
            contentTokenCount: 2,
          ),
        );
    final builtIn = PersonaEntity.fromDomain(
      Persona(
        id: 'built-in',
        name: 'Built in',
        emoji: '🤖',
        systemPrompt: '',
        isBuiltIn: true,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );
    final custom = PersonaEntity.fromDomain(
      Persona(
        id: 'custom',
        name: 'Custom',
        emoji: '🧠',
        systemPrompt: 'Private',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );
    final orphanedSavedMessage = SavedMessageEntity(
      id: 'saved-orphan',
      sourceMessageId: 'deleted-message',
      conversationId: 'deleted-conversation',
      conversationTitle: 'Deleted chat',
      roleIndex: MessageRole.assistant.index,
      content: 'Keep me',
      savedAt: DateTime.utc(2026, 7, 10),
    );
    final store = _FakeStore({
      ConversationEntity: _FakeBox([persistent, temporary]),
      MessageEntity: _FakeBox([
        message('persistent-message', persistent.id),
        message('temporary-message', temporary.id),
      ]),
      PersonaEntity: _FakeBox([builtIn, custom]),
      SavedMessageEntity: _FakeBox([orphanedSavedMessage]),
      SavedMessageFolderEntity: _FakeBox<SavedMessageFolderEntity>(const []),
      ServerEntity: _FakeBox<ServerEntity>(const []),
      ConversationFolderEntity: _FakeBox<ConversationFolderEntity>(const []),
    });

    final directory = await Directory.systemTemp.createTemp('backup-test');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final payload = await DataBackupService(
      documentsDirectory: () async => directory,
    ).exportCloudSync(
      store,
      jsonEncode({
        'themeMode': 1,
        'huggingFaceToken': 'secret',
        'defaultServerId': 'server',
        'hasCompletedOnboarding': true,
        'hasAskedForNotifications': true,
        'futureSecret': 'must-not-sync',
      }),
    );

    expect((payload['conversations'] as List).single['id'], persistent.id);
    expect((payload['messages'] as List).single['id'], 'persistent-message');
    expect((payload['messages'] as List).single['inputTokenCount'], 4);
    expect((payload['personas'] as List).single['id'], custom.id);
    expect(
      (payload['savedMessages'] as List).single['id'],
      orphanedSavedMessage.id,
    );
    expect(payload, isNot(contains('servers')));
    expect(payload, isNot(contains('modelMetadata')));
    expect(payload['settings'], isNot(contains('huggingFaceToken')));
    expect(payload['settings'], isNot(contains('defaultServerId')));
    expect(payload['settings'], isNot(contains('hasCompletedOnboarding')));
    expect(payload['settings'], isNot(contains('futureSecret')));
  });

  test('memory tags, summary, expiry and source app survive export/import',
      () async {
    final memory = MemoryEntity(
      id: 'memory-1',
      kindIndex: MemoryKind.inferred.index,
      title: 'Standup',
      content: 'Standup moved to 10:00.',
      createdAt: DateTime.utc(2026, 10, 20),
      updatedAt: DateTime.utc(2026, 10, 20),
      tags: const ['work', 'standup'],
      shortSummary: 'Standup at 10:00',
      expiresAt: DateTime.utc(2026, 10, 21),
      sourceApp: 'com.whatsapp',
    );
    final memoryBox = _MemoryBox([memory]);
    final store = _FakeStore({
      MemoryEntity: memoryBox,
      MemoryRelationEntity: _FakeBox<MemoryRelationEntity>(const []),
      MemoryEmbeddingEntity: _FakeBox<MemoryEmbeddingEntity>(const []),
    });
    final directory = await Directory.systemTemp.createTemp(
      'backup-memory-test',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final service = DataBackupService(
      documentsDirectory: () async => directory,
    );

    final exported = await service.exportSkillsAndMemories(store);
    final row =
        (exported['memories'] as List).single as Map<String, dynamic>;
    expect(row['kind'], 'inferred');
    expect(row['tags'], ['work', 'standup']);
    expect(row['shortSummary'], 'Standup at 10:00');
    expect(row['expiresAt'], '2026-10-21T00:00:00.000Z');
    expect(row['sourceApp'], 'com.whatsapp');

    final importedBox = _MemoryBox();
    await service.importSkillsAndMemories(
      _FakeStore({
        MemoryEntity: importedBox,
        MemoryRelationEntity: _FakeBox<MemoryRelationEntity>(const []),
        MemoryEmbeddingEntity: _FakeBox<MemoryEmbeddingEntity>(const []),
      }),
      exported,
    );

    final restored = importedBox.items.single;
    expect(restored.id, 'memory-1');
    expect(restored.kindIndex, MemoryKind.inferred.index);
    expect(restored.tags, ['work', 'standup']);
    expect(restored.shortSummary, 'Standup at 10:00');
    expect(restored.expiresAt, DateTime.utc(2026, 10, 21));
    expect(restored.sourceApp, 'com.whatsapp');
  });

  test(
    'cloud import rejects incomplete replacement payloads before mutation',
    () {
      final malformed = <String, dynamic>{
        'version': 1,
        'type': 'cloudSync',
        'settings': <String, dynamic>{},
        'conversations': <dynamic>[],
      };

      expect(
        DataBackupService().importCloudSync(_FakeStore(const {}), malformed),
        throwsFormatException,
      );
    },
  );
}

class _FakeStore extends Fake implements Store {
  _FakeStore(this._boxes);

  final Map<Type, Object> _boxes;

  @override
  Box<T> box<T>() =>
      _boxes.putIfAbsent(T, () => _FakeBox<T>(<T>[])) as Box<T>;
}

class _FakeBox<T> extends Fake implements Box<T> {
  _FakeBox(this._items);

  final List<T> _items;

  @override
  List<T> getAll() => List<T>.from(_items);
}

class _MemoryBox extends Fake implements Box<MemoryEntity> {
  _MemoryBox([Iterable<MemoryEntity> items = const []]) {
    this.items.addAll(items);
  }

  final List<MemoryEntity> items = [];

  @override
  List<MemoryEntity> getAll() => List<MemoryEntity>.from(items);

  @override
  QueryBuilder<MemoryEntity> query([Condition<MemoryEntity>? qc]) =>
      _FakeQueryBuilder(items);

  @override
  int put(MemoryEntity entity, {PutMode mode = PutMode.put}) {
    final index = items.indexWhere((item) => item.id == entity.id);
    if (index >= 0) {
      items[index] = entity;
    } else {
      items.add(entity);
    }
    return items.length;
  }
}

class _FakeQueryBuilder<T> extends Fake implements QueryBuilder<T> {
  _FakeQueryBuilder(this._items);

  final List<T> _items;

  @override
  Query<T> build() => _FakeQuery(_items);
}

class _FakeQuery<T> extends Fake implements Query<T> {
  _FakeQuery(this._items);

  final List<T> _items;

  @override
  T? findFirst() => _items.isEmpty ? null : _items.first;

  @override
  void close() {}
}
