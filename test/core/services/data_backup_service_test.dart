import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/services/data_backup_service.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
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

  test('cloud export excludes temporary chats, built-ins, and secrets', () {
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

    final payload = DataBackupService().exportCloudSync(
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

  test('exports timestamps in UTC so devices agree on ordering', () {
    ConversationEntity conversation(DateTime createdAt, DateTime updatedAt) =>
        ConversationEntity.fromDomain(
          Conversation(
            id: 'conv-1',
            title: 'Chat',
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
        );
    MessageEntity message(DateTime createdAt, DateTime updatedAt) =>
        MessageEntity.fromDomain(
          Message(
            id: 'm1',
            conversationId: 'conv-1',
            role: MessageRole.user,
            content: 'Hello',
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
        );
    _FakeStore storeFor(DateTime createdAt, DateTime updatedAt) => _FakeStore({
      ConversationEntity: _FakeBox([conversation(createdAt, updatedAt)]),
      MessageEntity: _FakeBox([message(createdAt, updatedAt)]),
      PersonaEntity: _FakeBox<PersonaEntity>(const []),
      SavedMessageEntity: _FakeBox<SavedMessageEntity>(const []),
      SavedMessageFolderEntity: _FakeBox<SavedMessageFolderEntity>(const []),
      ServerEntity: _FakeBox<ServerEntity>(const []),
      ConversationFolderEntity: _FakeBox<ConversationFolderEntity>(const []),
    });

    // The same instants, stored once with a local offset and once in UTC.
    final withOffset = DataBackupService().exportAll(
      storeFor(
        DateTime.parse('2026-01-01T10:00:00+02:00'),
        DateTime.parse('2026-01-01T11:00:00+02:00'),
      ),
    );
    final utc = DataBackupService().exportAll(
      storeFor(
        DateTime.parse('2026-01-01T08:00:00Z'),
        DateTime.parse('2026-01-01T09:00:00Z'),
      ),
    );

    final offsetMessage = (withOffset['messages'] as List).single as Map;
    final utcMessage = (utc['messages'] as List).single as Map;
    final offsetConversation =
        (withOffset['conversations'] as List).single as Map;
    final utcConversation = (utc['conversations'] as List).single as Map;

    for (final value in [
      offsetMessage['createdAt'],
      offsetMessage['updatedAt'],
      offsetConversation['createdAt'],
      offsetConversation['updatedAt'],
    ]) {
      expect(value, isA<String>());
      expect(value as String, endsWith('Z'));
    }
    expect(offsetMessage['createdAt'], utcMessage['createdAt']);
    expect(offsetMessage['updatedAt'], utcMessage['updatedAt']);
    expect(offsetConversation['createdAt'], utcConversation['createdAt']);
    expect(offsetConversation['updatedAt'], utcConversation['updatedAt']);
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
