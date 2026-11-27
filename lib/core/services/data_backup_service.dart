import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/enums.dart';
import '../storage/entities.dart';
import 'data_backup_import_helpers.dart';
import '../../features/chat/data/models/message.dart';
import '../../features/chat/data/tools/tool_event.dart';
import '../../features/conversations/data/models/conversation.dart';
import '../../features/personas/data/models/persona.dart';
import '../../features/servers/data/models/server.dart';
import '../../features/skills/data/skills_store.dart';
import '../../features/memories/data/models/memory.dart';
import '../../features/memories/data/memory_store.dart';
import '../../objectbox.g.dart';

class DataBackupService {
  DataBackupService({Future<Directory> Function()? documentsDirectory})
    : _documentsDirectory =
          documentsDirectory ?? getApplicationDocumentsDirectory;

  /// Skills live beside the database in the app documents directory; tests
  /// inject a temporary directory because path_provider needs a binding.
  final Future<Directory> Function() _documentsDirectory;
  static const _synchronizedSettingKeys = {
    'temperature',
    'topP',
    'maxTokens',
    'contextLength',
    'themeMode',
    'fontSize',
    'showSystemMessages',
    'hapticFeedbackEnabled',
    'sendOnEnter',
    'showDataIndicator',
    'autoGenerateTitle',
    'streamingEnabled',
    'defaultPersonaId',
    'defaultModelId',
    'defaultModelServerId',
    'mcpEnabled',
    'newChatMcpEnabled',
    'codeThemeDark',
    'codeThemeLight',
    'preferredBackend',
    'ttsEngine',
    'ttsVoiceId',
    'ttsSpeed',
    'kittenTtsModelVariant',
    'autoSpeakEnabled',
    'conciseVoiceResponsesEnabled',
    'ttsProcessMarkdown',
    'ttsSkipSeconds',
    'smartReplyEnabled',
    'aiUserResponseEnabled',
    'localeCode',
    'unloadModelsBeforeLoad',
    'tempChatKeyboardIncognito',
    'resumeLastChat',
    'imageCompressionEnabled',
    'imageCompressionLevel',
    'smartRepliesUsePersona',
    'keepPersonaOnNewChat',
    'roleSwapButtonEnabled',
    'showSystemMessagesInChat',
  };

  Map<String, dynamic> _messageToMap(Message message) => {
    'id': message.id,
    'conversationId': message.conversationId,
    'role': message.role.name,
    'content': message.content,
    'createdAt': message.createdAt.toUtc().toIso8601String(),
    'updatedAt': message.effectiveUpdatedAt.toUtc().toIso8601String(),
    'status': message.status.name,
    'modelId': message.modelId,
    'tokenCount': message.tokenCount,
    'inputTokenCount': message.inputTokenCount,
    'tokensPerSecond': message.tokensPerSecond,
    'ttftMs': message.ttftMs,
    'stopReason': message.stopReason,
    'errorMessage': message.errorMessage,
    'attachmentPaths': message.attachmentPaths,
    'generationTimeMs': message.generationTimeMs,
    'reasoningContent': message.reasoningContent,
    'toolCalls': message.toolCalls?.map((e) => e.toMap()).toList(),
    'toolCallId': message.toolCallId,
    'isProcessing': message.isProcessing,
    'toolSessionId': message.toolSessionId,
    'toolEvents': message.toolEvents?.map((e) => e.toMap()).toList(),
    'variantGroupId': message.variantGroupId,
    'variantIndex': message.variantIndex,
    'threadOrder': message.threadOrder,
    'isActiveVariant': message.isActiveVariant,
    'parentMessageId': message.parentMessageId,
    'contentTokenCount': message.contentTokenCount,
  };

  Map<String, dynamic> _conversationToMap(Conversation domain) => {
    'id': domain.id,
    'title': domain.title,
    'createdAt': domain.createdAt.toUtc().toIso8601String(),
    'updatedAt': domain.updatedAt.toUtc().toIso8601String(),
    'isPinned': domain.isPinned,
    'personaId': domain.personaId,
    'serverId': domain.serverId,
    'modelId': domain.modelId,
    'messageCount': domain.messageCount,
    'lastMessagePreview': domain.lastMessagePreview,
    'systemPrompt': domain.systemPrompt,
    'temperature': domain.temperature,
    'topP': domain.topP,
    'maxTokens': domain.maxTokens,
    'contextLength': domain.contextLength,
    'mcpEnabled': domain.mcpEnabled,
    'smartReplies': domain.smartReplies,
    'smartRepliesLastMessageId': domain.smartRepliesLastMessageId,
    'folderId': domain.folderId,
    'isTemporary': domain.isTemporary,
    'isArchived': domain.isArchived,
    'characterCount': domain.characterCount,
    'totalTokenCount': domain.totalTokenCount,
    // Fork/background rows are hidden in every history surface. Losing these
    // fields on a backup round-trip turns a hidden fork into a normal chat, so
    // they travel with the conversation record itself.
    'forkOfMessageId': domain.forkOfMessageId,
    'forkSpan': domain.forkSpan,
    'isFork': domain.isFork,
    'isBackground': domain.isBackground,
    'specialKind': domain.specialKind,
  };

  List<Map<String, dynamic>> _exportSavedMessages(Store store) {
    final box = store.box<SavedMessageEntity>();
    return box.getAll().map((e) {
      return {
        'id': e.id,
        'sourceMessageId': e.sourceMessageId,
        'conversationId': e.conversationId,
        'conversationTitle': e.conversationTitle,
        'roleIndex': e.roleIndex,
        'content': e.content,
        'modelId': e.modelId,
        'folderId': e.folderId,
        'isArchived': e.isArchived,
        'savedAt': e.savedAt.toIso8601String(),
      };
    }).toList();
  }

  List<Map<String, dynamic>> _exportConversationFolders(Store store) {
    final box = store.box<ConversationFolderEntity>();
    return box.getAll().map((e) {
      return {
        'id': e.id,
        'name': e.name,
        'sortOrder': e.sortOrder,
        'createdAt': e.createdAt.toIso8601String(),
      };
    }).toList();
  }

  List<Map<String, dynamic>> _exportForkAnchors(Store store) {
    final box = store.box<ForkAnchorEntity>();
    return box.getAll().map((e) {
      return {
        'id': e.id,
        'mainConversationId': e.mainConversationId,
        'anchorMessageId': e.anchorMessageId,
        'selectedText': e.selectedText,
        'forkConversationId': e.forkConversationId,
        'createdAt': e.createdAt.toIso8601String(),
      };
    }).toList();
  }

  /// Local store shape for support reports. Included only in the manual
  /// conversations export (never in cloud payloads, whose hashes must stay
  /// stable): it shows whether a missing chat is absent from the database or
  /// merely hidden/mis-filtered.
  Map<String, dynamic> _exportStoreDiagnostics(Store store) {
    final conversations = store.box<ConversationEntity>().getAll();
    final messages = store.box<MessageEntity>().getAll();
    final anchors = store.box<ForkAnchorEntity>().getAll();
    final conversationIds = conversations.map((c) => c.id).toSet();
    final messageConversationIds = messages
        .map((m) => m.conversationUid)
        .whereType<String>()
        .toSet();
    return {
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'conversationCount': conversations.length,
      'messageCount': messages.length,
      'conversationIds': conversationIds.toList(),
      'messagesWithoutConversationRow': messageConversationIds
          .difference(conversationIds)
          .toList(),
      'anchoredForkConversationIds': anchors
          .map((anchor) => anchor.forkConversationId)
          .toList(),
      'hiddenConversations': [
        for (final c in conversations)
          if (c.isTemporary || c.isFork || c.isBackground || c.isArchived)
            {
              'id': c.id,
              'title': c.title,
              'isTemporary': c.isTemporary,
              'isFork': c.isFork,
              'isBackground': c.isBackground,
              'isArchived': c.isArchived,
              'folderId': c.folderId,
              'updatedAt': c.updatedAt.toUtc().toIso8601String(),
            },
      ],
    };
  }

  List<Map<String, dynamic>> _conversationFoldersForConversationIds(
    Map<String, dynamic> all,
    Set<String> conversationIds,
  ) {
    final folderIds = (all['conversations'] as List)
        .where((c) => conversationIds.contains((c as Map)['id']))
        .map((c) => (c as Map)['folderId'] as String?)
        .whereType<String>()
        .toSet();
    return (all['conversationFolders'] as List)
        .where((f) => folderIds.contains((f as Map)['id']))
        .toList()
        .cast<Map<String, dynamic>>();
  }

  List<Map<String, dynamic>> _exportSavedMessageFolders(Store store) {
    final box = store.box<SavedMessageFolderEntity>();
    return box.getAll().map((e) {
      return {
        'id': e.id,
        'name': e.name,
        'sortOrder': e.sortOrder,
        'createdAt': e.createdAt.toIso8601String(),
      };
    }).toList();
  }

  List<Map<String, dynamic>> _exportServers(Store store) {
    return store.box<ServerEntity>().getAll().map((entity) {
      final server = entity.toDomain();
      return {
        'id': server.id,
        'name': server.name,
        'type': server.type.name,
        'host': server.host,
        'port': server.port,
        'apiKey': server.apiKey,
        'isDefault': server.isDefault,
        'createdAt': server.createdAt.toIso8601String(),
        'lastConnectedAt': server.lastConnectedAt.toIso8601String(),
        'status': server.status.name,
        'iconName': server.iconName,
        'pathPrefix': server.pathPrefix,
        'switcherBaseUrl': server.switcherBaseUrl,
      };
    }).toList();
  }

  List<Map<String, dynamic>> _exportManualModels(Store store) {
    return store.box<ManualModelEntity>().getAll().map((entity) {
      return {
        'serverId': entity.serverId,
        'modelId': entity.modelId,
        'displayName': entity.displayName,
        'createdAt': entity.createdAt.toIso8601String(),
      };
    }).toList();
  }

  Map<String, dynamic>? _readModelMetadata(SharedPreferences? prefs) {
    if (prefs == null) return null;
    final raw = prefs.getString('modelMetadata');
    if (raw == null || raw.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  /// Skills (name → description/body) and the memory graph (memories +
  /// relations; embeddings are recomputed on import). Absent sections are no-ops.
  Future<Map<String, dynamic>> exportSkillsAndMemories(Store store) async {
    final documents = await _documentsDirectory();
    final skills = SkillsStore(DirectorySkillFileHost(Future.value(documents)));
    final entries = await skills.refresh();
    final memoryStore = ObjectBoxMemoryStore(
      memories: store.box<MemoryEntity>(),
      relations: store.box<MemoryRelationEntity>(),
      embeddings: store.box<MemoryEmbeddingEntity>(),
    );
    final memories = memoryStore.list();
    final relations = memoryStore.listRelations();
    return {
      'skills': [
        for (final entry in entries)
          {
            'name': entry.name,
            'description': entry.description,
            'body': entry.body,
          },
      ],
      'memories': [
        for (final memory in memories)
          {
            'id': memory.id,
            'kind': memory.kind.name,
            'title': memory.title,
            'content': memory.content,
            'importance': memory.importance,
            'createdAt': memory.createdAt.toIso8601String(),
            'updatedAt': memory.updatedAt.toIso8601String(),
            'scopeConversationId': memory.scopeConversationId,
            'sourceConversationId': memory.sourceConversationId,
            'sourceMessageId': memory.sourceMessageId,
            'supersededById': memory.supersededById,
            'archived': memory.archived,
            'tags': memory.tags,
            'shortSummary': memory.shortSummary,
            'expiresAt': memory.expiresAt?.toIso8601String(),
            'sourceApp': memory.sourceApp,
          },
      ],
      'memoryRelations': [
        for (final relation in relations)
          {
            'id': relation.id,
            'fromMemoryId': relation.fromMemoryId,
            'toMemoryId': relation.toMemoryId,
            'label': relation.label,
            'createdAt': relation.createdAt.toIso8601String(),
          },
      ],
    };
  }

  Future<void> importSkillsAndMemories(
    Store store,
    Map<String, dynamic> decoded,
  ) async {
    final rawSkills = decoded['skills'];
    if (rawSkills is List) {
      final documents = await _documentsDirectory();
      final skills = SkillsStore(
        DirectorySkillFileHost(Future.value(documents)),
      );
      final existing = await skills.refresh();
      for (final raw in rawSkills.whereType<Map>()) {
        final name = backupImportString(raw['name']);
        final body = raw['body'];
        if (name == null || body is! String) continue;
        if (existing.any((entry) => entry.name == name)) {
          await skills.delete(name);
        }
        await skills.add(
          SkillEntry(
            name: name,
            description: backupImportString(raw['description']) ?? '',
            body: body,
          ),
        );
      }
    }
    final memoryStore = ObjectBoxMemoryStore(
      memories: store.box<MemoryEntity>(),
      relations: store.box<MemoryRelationEntity>(),
      embeddings: store.box<MemoryEmbeddingEntity>(),
    );
    final rawMemories = decoded['memories'];
    if (rawMemories is List) {
      for (final raw in rawMemories.whereType<Map>()) {
        final id = backupImportString(raw['id']);
        final title = backupImportString(raw['title']);
        final content = backupImportString(raw['content']);
        final createdAt = backupImportDateTime(raw['createdAt']);
        final updatedAt = backupImportDateTime(raw['updatedAt']);
        final rawTags = raw['tags'];
        if (id == null ||
            title == null ||
            content == null ||
            createdAt == null ||
            updatedAt == null) {
          continue;
        }
        memoryStore.put(
          Memory(
            id: id,
            kind: MemoryKind.values.firstWhere(
              (kind) => kind.name == raw['kind'],
              orElse: () => MemoryKind.fact,
            ),
            title: title,
            content: content,
            importance: (raw['importance'] as num?)?.toInt() ?? 50,
            createdAt: createdAt,
            updatedAt: updatedAt,
            scopeConversationId: backupImportString(raw['scopeConversationId']),
            sourceConversationId: backupImportString(
              raw['sourceConversationId'],
            ),
            sourceMessageId: backupImportString(raw['sourceMessageId']),
            supersededById: backupImportString(raw['supersededById']),
            archived: raw['archived'] as bool? ?? false,
            tags: rawTags is List
                ? rawTags.whereType<String>().toList()
                : const [],
            shortSummary: backupImportString(raw['shortSummary']) ?? '',
            expiresAt: backupImportDateTime(raw['expiresAt']),
            sourceApp: backupImportString(raw['sourceApp']),
          ),
        );
      }
    }
    final rawRelations = decoded['memoryRelations'];
    if (rawRelations is List) {
      for (final raw in rawRelations.whereType<Map>()) {
        final id = backupImportString(raw['id']);
        final from = backupImportString(raw['fromMemoryId']);
        final to = backupImportString(raw['toMemoryId']);
        final createdAt = backupImportDateTime(raw['createdAt']);
        if (id == null || from == null || to == null || createdAt == null) {
          continue;
        }
        memoryStore.putRelation(
          MemoryRelation(
            id: id,
            fromMemoryId: from,
            toMemoryId: to,
            label: backupImportString(raw['label']) ?? '',
            createdAt: createdAt,
          ),
        );
      }
    }
  }

  Map<String, dynamic> exportAll(Store store, {SharedPreferences? prefs}) {
    final convBox = store.box<ConversationEntity>();
    final messageBox = store.box<MessageEntity>();
    final personaBox = store.box<PersonaEntity>();

    final conversations = convBox
        .getAll()
        .map((e) => _conversationToMap(e.toDomain()))
        .toList();
    final messages = messageBox
        .getAll()
        .map((e) => _messageToMap(e.toDomain()))
        .toList();

    final personas = personaBox
        .getAll()
        .where((entity) => !entity.isBuiltIn)
        .map((entity) {
          final persona = entity.toDomain();
          return {
            'id': persona.id,
            'name': persona.name,
            'emoji': persona.emoji,
            'systemPrompt': persona.systemPrompt,
            'description': persona.description,
            'isBuiltIn': persona.isBuiltIn,
            'createdAt': persona.createdAt.toIso8601String(),
            'updatedAt': persona.updatedAt.toIso8601String(),
            'category': persona.category,
            'preferredParams': persona.preferredParams,
          };
        })
        .toList();

    final modelMetadata = _readModelMetadata(prefs);
    return {
      'version': 3,
      'exportedAt': DateTime.now().toIso8601String(),
      'conversations': conversations,
      'messages': messages,
      'personas': personas,
      'savedMessages': _exportSavedMessages(store),
      'savedMessageFolders': _exportSavedMessageFolders(store),
      'servers': _exportServers(store),
      'manualModels': _exportManualModels(store),
      'conversationFolders': _exportConversationFolders(store),
      'forkAnchors': _exportForkAnchors(store),
      'modelMetadata': modelMetadata,
    };
  }

  Future<Map<String, dynamic>> exportCloudSync(
    Store store,
    String settingsJson,
  ) async {
    final all = exportAll(store);
    all.addAll(await exportSkillsAndMemories(store));
    final persistentConversations = (all['conversations'] as List)
        .where((item) => (item as Map)['isTemporary'] != true)
        .cast<Map<String, dynamic>>()
        .toList();
    final conversationIds = persistentConversations
        .map((item) => item['id'] as String)
        .toSet();
    final allSettings = Map<String, dynamic>.from(
      jsonDecode(settingsJson) as Map,
    );
    final settings = <String, dynamic>{
      for (final entry in allSettings.entries)
        if (_synchronizedSettingKeys.contains(entry.key))
          entry.key: entry.value,
    };
    return {
      'version': 1,
      'type': 'cloudSync',
      'settings': settings,
      'conversations': persistentConversations,
      'messages': (all['messages'] as List)
          .where(
            (item) => conversationIds.contains((item as Map)['conversationId']),
          )
          .toList(),
      'personas': all['personas'],
      'savedMessages': all['savedMessages'],
      'savedMessageFolders': all['savedMessageFolders'],
      'conversationFolders': all['conversationFolders'],
      // A fork is part of its parent chat: ship the anchor with the parent so a
      // restore can still hide the fork (and draw its highlight band) even when
      // the receiving app predates the conversation's isFork field.
      'forkAnchors': (all['forkAnchors'] as List)
          .where(
            (item) =>
                conversationIds.contains((item as Map)['mainConversationId']),
          )
          .toList(),
      // Cloud sync carries the memory graph too. Screen-memory device settings
      // stay out of `settings` so a restore cannot turn screen watching on.
      'memories': all['memories'],
      'memoryRelations': all['memoryRelations'],
    };
  }

  /// Applies a merged cloud snapshot.
  ///
  /// [tombstones] carries the merges' explicit deletions. Only records named
  /// there are removed: a record that is merely absent from [payload] may have
  /// been created after the snapshot was exported (a sync that was already in
  /// flight while the user sent a message). Deleting by absence used to make
  /// those new chats disappear from history.
  Future<void> importCloudSync(
    Store store,
    Map<String, dynamic> payload, {
    Map<String, Map<String, String>> tombstones = const {},
  }) async {
    _validateCloudPayload(payload);
    await importFromJson(
      store,
      jsonEncode(payload),
      replaceCloudData: true,
      tombstones: tombstones,
    );
  }

  void _validateCloudPayload(Map<String, dynamic> payload) {
    const collections = {
      'conversations',
      'messages',
      'personas',
      'savedMessages',
      'savedMessageFolders',
      'conversationFolders',
    };
    if (payload['version'] != 1 ||
        payload['type'] != 'cloudSync' ||
        payload['settings'] is! Map ||
        !(payload['settings'] as Map).entries.every(
          (entry) =>
              entry.key is String &&
              entry.key != 'huggingFaceToken' &&
              entry.key != 'webSearchApiKey',
        )) {
      // Unknown setting keys are tolerated for forward/backward compatibility;
      // AppSettings.fromMap ignores keys it does not know. Secret keys are still
      // rejected.
      throw const FormatException('Invalid cloud sync payload');
    }
    for (final collection in collections) {
      final records = payload[collection];
      if (records is! List ||
          !records.every(
            (record) =>
                record is Map &&
                record['id'] is String &&
                (record['id'] as String).isNotEmpty,
          )) {
        throw FormatException('Invalid cloud sync collection: $collection');
      }
    }
    // Optional for backward compatibility: backups written before fork anchors
    // were included still restore; when present they must be well-formed.
    final forkAnchors = payload['forkAnchors'];
    if (forkAnchors != null &&
        (forkAnchors is! List ||
            !forkAnchors.every(
              (record) =>
                  record is Map &&
                  record['id'] is String &&
                  (record['id'] as String).isNotEmpty,
            ))) {
      throw const FormatException('Invalid cloud sync collection: forkAnchors');
    }
    if ((payload['conversations'] as List).any(
          (record) => (record as Map)['isTemporary'] == true,
        ) ||
        (payload['personas'] as List).any(
          (record) => (record as Map)['isBuiltIn'] == true,
        )) {
      throw const FormatException('Cloud payload contains excluded records');
    }
  }

  Map<String, dynamic> exportConversations(Store store) {
    final all = exportAll(store);
    return {
      'version': 3,
      'type': 'conversations',
      'exportedAt': all['exportedAt'],
      'conversations': all['conversations'],
      'messages': all['messages'],
      'savedMessages': all['savedMessages'],
      'savedMessageFolders': all['savedMessageFolders'],
      'conversationFolders': all['conversationFolders'],
      'forkAnchors': all['forkAnchors'],
      // Manual export only: tells support whether a missing chat is absent
      // from the store or hidden by a row flag. Ignored on import.
      'diagnostics': _exportStoreDiagnostics(store),
      // Cloud sync carries the memory graph too. Screen-memory device settings
      // stay out of `settings` so a restore cannot turn screen watching on.
      'memories': all['memories'],
      'memoryRelations': all['memoryRelations'],
    };
  }

  Map<String, dynamic> exportConversation(Store store, String conversationId) {
    final all = exportAll(store);
    final conversations = (all['conversations'] as List)
        .where((c) => (c as Map)['id'] == conversationId)
        .toList();
    final messages = (all['messages'] as List)
        .where((m) => (m as Map)['conversationId'] == conversationId)
        .toList();
    final savedMessages = (all['savedMessages'] as List)
        .where((m) => (m as Map)['conversationId'] == conversationId)
        .toList();
    final folderIds = savedMessages
        .map((m) => (m as Map)['folderId'] as String?)
        .whereType<String>()
        .toSet();
    final savedMessageFolders = (all['savedMessageFolders'] as List)
        .where((f) => folderIds.contains((f as Map)['id']))
        .toList();
    final conversationFolders = _conversationFoldersForConversationIds(all, {
      conversationId,
    });
    final forkAnchors = (all['forkAnchors'] as List)
        .where(
          (item) =>
              (item as Map)['mainConversationId'] == conversationId ||
              item['forkConversationId'] == conversationId,
        )
        .toList();

    return {
      'version': 3,
      'type': 'conversation',
      'exportedAt': all['exportedAt'],
      'conversations': conversations,
      'messages': messages,
      'savedMessages': savedMessages,
      'savedMessageFolders': savedMessageFolders,
      'conversationFolders': conversationFolders,
      'forkAnchors': forkAnchors,
    };
  }

  Map<String, dynamic> exportConversationsForIds(
    Store store,
    Set<String> conversationIds,
  ) {
    final all = exportAll(store);
    final conversations = (all['conversations'] as List)
        .where((c) => conversationIds.contains((c as Map)['id']))
        .toList();
    final messages = (all['messages'] as List)
        .where((m) => conversationIds.contains((m as Map)['conversationId']))
        .toList();
    final savedMessages = (all['savedMessages'] as List)
        .where((m) => conversationIds.contains((m as Map)['conversationId']))
        .toList();
    final folderIds = savedMessages
        .map((m) => (m as Map)['folderId'] as String?)
        .whereType<String>()
        .toSet();
    final savedMessageFolders = (all['savedMessageFolders'] as List)
        .where((f) => folderIds.contains((f as Map)['id']))
        .toList();
    final conversationFolders = _conversationFoldersForConversationIds(
      all,
      conversationIds,
    );
    final forkAnchors = (all['forkAnchors'] as List)
        .where(
          (item) =>
              conversationIds.contains((item as Map)['mainConversationId']) ||
              conversationIds.contains(item['forkConversationId']),
        )
        .toList();

    return {
      'version': 3,
      'type': 'conversations',
      'exportedAt': all['exportedAt'],
      'conversations': conversations,
      'messages': messages,
      'savedMessages': savedMessages,
      'savedMessageFolders': savedMessageFolders,
      'conversationFolders': conversationFolders,
      'forkAnchors': forkAnchors,
    };
  }

  String exportConversationsForIdsAsJson(
    Store store,
    Set<String> conversationIds,
  ) => const JsonEncoder.withIndent(
    '  ',
  ).convert(exportConversationsForIds(store, conversationIds));

  Map<String, dynamic> exportPersonas(Store store) {
    final all = exportAll(store);
    return {
      'version': 3,
      'type': 'personas',
      'exportedAt': all['exportedAt'],
      'personas': all['personas'],
    };
  }

  Map<String, dynamic> exportSettings(
    String settingsJson, {
    Store? store,
    SharedPreferences? prefs,
  }) {
    final map = <String, dynamic>{
      'version': 3,
      'type': 'settings',
      'exportedAt': DateTime.now().toIso8601String(),
      'settings': jsonDecode(settingsJson),
    };
    if (store != null) {
      map['servers'] = _exportServers(store);
    }
    final metadata = _readModelMetadata(prefs);
    if (metadata != null) {
      map['modelMetadata'] = metadata;
    }
    return map;
  }

  String exportConversationsAsJson(Store store) =>
      const JsonEncoder.withIndent('  ').convert(exportConversations(store));

  String exportConversationAsJson(Store store, String conversationId) =>
      const JsonEncoder.withIndent(
        '  ',
      ).convert(exportConversation(store, conversationId));

  String exportPersonasAsJson(Store store) =>
      const JsonEncoder.withIndent('  ').convert(exportPersonas(store));

  String exportSettingsAsJson(
    String settingsJson, {
    Store? store,
    SharedPreferences? prefs,
  }) => const JsonEncoder.withIndent(
    '  ',
  ).convert(exportSettings(settingsJson, store: store, prefs: prefs));

  ArchiveFile _jsonArchiveFile(String name, String json) {
    final bytes = utf8.encode(json);
    return ArchiveFile(name, bytes.length, bytes);
  }

  Future<List<int>> exportAllZip(
    Store store,
    String settingsJson, {
    SharedPreferences? prefs,
  }) async {
    final extras = await exportSkillsAndMemories(store);
    final archive = Archive()
      ..addFile(
        _jsonArchiveFile(
          'conversations.json',
          exportConversationsAsJson(store),
        ),
      )
      ..addFile(_jsonArchiveFile('personas.json', exportPersonasAsJson(store)))
      ..addFile(
        _jsonArchiveFile(
          'settings.json',
          exportSettingsAsJson(settingsJson, store: store, prefs: prefs),
        ),
      )
      ..addFile(
        _jsonArchiveFile(
          'skills.json',
          const JsonEncoder.withIndent('  ').convert(extras['skills']),
        ),
      )
      ..addFile(
        _jsonArchiveFile(
          'memories.json',
          const JsonEncoder.withIndent('  ').convert({
            'memories': extras['memories'],
            'memoryRelations': extras['memoryRelations'],
          }),
        ),
      );
    return ZipEncoder().encode(archive);
  }

  Future<String> exportAllAsJson(
    Store store, {
    SharedPreferences? prefs,
  }) async {
    final all = exportAll(store, prefs: prefs);
    all.addAll(await exportSkillsAndMemories(store));
    return const JsonEncoder.withIndent('  ').convert(all);
  }

  Future<void> importFromJson(
    Store store,
    String jsonString, {
    bool replaceCloudData = false,
    Map<String, Map<String, String>> tombstones = const {},
  }) async {
    final decoded = jsonDecode(jsonString);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('Invalid backup format');
    }
    await importSkillsAndMemories(store, decoded);

    // Imported attachment paths are restored verbatim onto Message records
    // and later opened directly as files (image/text preview), so a
    // crafted backup could otherwise point them at arbitrary files already
    // readable by this app. Only accept paths that resolve inside our own
    // attachments directory.
    final appDir = await getApplicationDocumentsDirectory();
    final attachmentsDir = p.normalize(p.join(appDir.path, 'attachments'));

    await store.runInTransactionAsync(TxMode.write, (store, data) {
      final (decoded, attachmentsDir, replaceCloudData, tombstones) = data;
      final convBox = store.box<ConversationEntity>();
      final messageBox = store.box<MessageEntity>();
      final personaBox = store.box<PersonaEntity>();
      final serverBox = store.box<ServerEntity>();
      final savedBox = store.box<SavedMessageEntity>();
      final savedFolderBox = store.box<SavedMessageFolderEntity>();
      final conversationFolderBox = store.box<ConversationFolderEntity>();
      final forkAnchorBox = store.box<ForkAnchorEntity>();

      final personas = decoded['personas'];
      if (personas is List) {
        for (final item in personas) {
          if (item is! Map) continue;
          final id = backupImportString(item['id']);
          final name = backupImportString(item['name']);
          final createdAt = backupImportDateTime(item['createdAt']);
          final updatedAt = backupImportDateTime(item['updatedAt']);
          if (id == null ||
              name == null ||
              createdAt == null ||
              updatedAt == null) {
            continue;
          }
          final persona = Persona(
            id: id,
            name: name,
            emoji: item['emoji'] as String? ?? '🤖',
            systemPrompt: item['systemPrompt'] as String? ?? '',
            description: item['description'] as String?,
            isBuiltIn: item['isBuiltIn'] as bool? ?? false,
            createdAt: createdAt,
            updatedAt: updatedAt,
            category: item['category'] as String?,
            preferredParams: item['preferredParams'] is Map
                ? Map<String, dynamic>.from(item['preferredParams'] as Map)
                : null,
          );
          final query = personaBox
              .query(PersonaEntity_.id.equals(persona.id))
              .build();
          final existing = query.findFirst();
          query.close();
          final entity = PersonaEntity.fromDomain(persona);
          if (existing != null) entity.internalId = existing.internalId;
          personaBox.put(entity);
        }
      }

      final servers = decoded['servers'];
      if (servers is List) {
        for (final item in servers) {
          if (item is! Map) continue;
          final id = backupImportString(item['id']);
          final name = backupImportString(item['name']);
          final createdAt = backupImportDateTime(item['createdAt']);
          final lastConnectedAt = backupImportDateTime(item['lastConnectedAt']);
          if (id == null ||
              name == null ||
              createdAt == null ||
              lastConnectedAt == null) {
            continue;
          }
          final server = Server(
            id: id,
            name: name,
            type: ServerType.values.byName(
              item['type'] as String? ?? 'lmStudio',
            ),
            host: item['host'] as String? ?? 'localhost',
            port: item['port'] as int? ?? 1234,
            apiKey: item['apiKey'] as String?,
            isDefault: item['isDefault'] as bool? ?? false,
            createdAt: createdAt,
            lastConnectedAt: lastConnectedAt,
            status: ConnectionStatus.values.byName(
              item['status'] as String? ?? 'disconnected',
            ),
            iconName: item['iconName'] as String?,
            pathPrefix: item['pathPrefix'] as String?,
            switcherBaseUrl: item['switcherBaseUrl'] as String?,
          );
          final query = serverBox
              .query(ServerEntity_.id.equals(server.id))
              .build();
          final existing = query.findFirst();
          query.close();
          final entity = ServerEntity.fromDomain(server);
          if (existing != null) entity.internalId = existing.internalId;
          serverBox.put(entity);
        }
      }

      final manualModels = decoded['manualModels'];
      if (manualModels is List) {
        final manualBox = store.box<ManualModelEntity>();
        for (final item in manualModels) {
          if (item is! Map) continue;
          final serverId = backupImportString(item['serverId']);
          final modelId = backupImportString(item['modelId']);
          final createdAt = backupImportDateTime(item['createdAt']);
          if (serverId == null || modelId == null || createdAt == null) {
            continue;
          }
          final query = manualBox
              .query(
                ManualModelEntity_.serverId
                    .equals(serverId)
                    .and(ManualModelEntity_.modelId.equals(modelId)),
              )
              .build();
          final existing = query.findFirst();
          query.close();
          final entity = ManualModelEntity(
            serverId: serverId,
            modelId: modelId,
            displayName: backupImportString(item['displayName']),
            createdAt: createdAt,
          );
          if (existing != null) entity.internalId = existing.internalId;
          manualBox.put(entity);
        }
      }

      final savedFolders = decoded['savedMessageFolders'];
      if (savedFolders is List) {
        for (final item in savedFolders) {
          if (item is! Map) continue;
          final id = backupImportString(item['id']);
          final folderName = backupImportString(item['name']);
          final createdAt = backupImportDateTime(item['createdAt']);
          if (id == null || folderName == null || createdAt == null) continue;
          final entity = SavedMessageFolderEntity(
            id: id,
            name: folderName,
            sortOrder: item['sortOrder'] as int? ?? 0,
            createdAt: createdAt,
          );
          final query = savedFolderBox
              .query(SavedMessageFolderEntity_.id.equals(entity.id))
              .build();
          final existing = query.findFirst();
          query.close();
          if (existing != null) entity.internalId = existing.internalId;
          savedFolderBox.put(entity);
        }
      }

      final savedMessages = decoded['savedMessages'];
      if (savedMessages is List) {
        for (final item in savedMessages) {
          if (item is! Map) continue;
          final id = backupImportString(item['id']);
          final sourceMessageId = backupImportString(item['sourceMessageId']);
          final conversationId = backupImportString(item['conversationId']);
          final savedAt = backupImportDateTime(item['savedAt']);
          if (id == null ||
              sourceMessageId == null ||
              conversationId == null ||
              savedAt == null) {
            continue;
          }
          final entity = SavedMessageEntity(
            id: id,
            sourceMessageId: sourceMessageId,
            conversationId: conversationId,
            conversationTitle: item['conversationTitle'] as String? ?? 'Chat',
            roleIndex: item['roleIndex'] as int? ?? 0,
            content: item['content'] as String? ?? '',
            modelId: item['modelId'] as String?,
            folderId: item['folderId'] as String?,
            isArchived: item['isArchived'] as bool? ?? false,
            savedAt: savedAt,
          );
          final query = savedBox
              .query(SavedMessageEntity_.id.equals(entity.id))
              .build();
          final existing = query.findFirst();
          query.close();
          if (existing != null) entity.internalId = existing.internalId;
          savedBox.put(entity);
        }
      }

      final conversationFolders = decoded['conversationFolders'];
      if (conversationFolders is List) {
        for (final item in conversationFolders) {
          if (item is! Map) continue;
          final id = backupImportString(item['id']);
          final folderName = backupImportString(item['name']);
          final createdAt = backupImportDateTime(item['createdAt']);
          if (id == null || folderName == null || createdAt == null) continue;
          final entity = ConversationFolderEntity(
            id: id,
            name: folderName,
            sortOrder: item['sortOrder'] as int? ?? 0,
            createdAt: createdAt,
          );
          final query = conversationFolderBox
              .query(ConversationFolderEntity_.id.equals(entity.id))
              .build();
          final existing = query.findFirst();
          query.close();
          if (existing != null) entity.internalId = existing.internalId;
          conversationFolderBox.put(entity);
        }
      }

      final conversations = decoded['conversations'];
      if (conversations is List) {
        for (final item in conversations) {
          if (item is! Map) continue;
          final id = backupImportString(item['id']);
          final createdAt = backupImportDateTime(item['createdAt']);
          final updatedAt = backupImportDateTime(item['updatedAt']);
          if (id == null || createdAt == null || updatedAt == null) continue;
          final conversation = Conversation(
            id: id,
            title: item['title'] as String? ?? 'Imported Chat',
            createdAt: createdAt,
            updatedAt: updatedAt,
            isPinned: item['isPinned'] as bool? ?? false,
            personaId: item['personaId'] as String?,
            serverId: item['serverId'] as String?,
            modelId: item['modelId'] as String?,
            messageCount: item['messageCount'] as int? ?? 0,
            lastMessagePreview: item['lastMessagePreview'] as String?,
            systemPrompt: item['systemPrompt'] as String?,
            temperature: (item['temperature'] as num?)?.toDouble(),
            topP: (item['topP'] as num?)?.toDouble(),
            maxTokens: item['maxTokens'] as int?,
            contextLength: item['contextLength'] as int?,
            mcpEnabled: item['mcpEnabled'] as bool?,
            smartReplies: item['smartReplies'] is List
                ? List<String>.from(item['smartReplies'] as List)
                : null,
            smartRepliesLastMessageId:
                item['smartRepliesLastMessageId'] as String?,
            folderId: item['folderId'] as String?,
            isTemporary: item['isTemporary'] as bool? ?? false,
            isArchived: item['isArchived'] as bool? ?? false,
            characterCount: item['characterCount'] as int? ?? 0,
            totalTokenCount: item['totalTokenCount'] as int?,
            forkOfMessageId: item['forkOfMessageId'] as String?,
            forkSpan: item['forkSpan'] as String?,
            // Older backups lack isFork but still carry the fork anchor
            // fields on the conversation; derive the hidden flag so a restore
            // cannot turn a fork into a history row.
            isFork:
                item['isFork'] as bool? ??
                (item['forkOfMessageId'] != null || item['forkSpan'] != null),
            isBackground: item['isBackground'] as bool? ?? false,
            specialKind: item['specialKind'] as String?,
          );
          final query = convBox
              .query(ConversationEntity_.id.equals(conversation.id))
              .build();
          final existing = query.findFirst();
          query.close();
          final entity = ConversationEntity.fromDomain(conversation);
          if (existing != null) entity.internalId = existing.internalId;
          convBox.put(entity);
        }
      }

      final forkAnchors = decoded['forkAnchors'];
      if (forkAnchors is List) {
        for (final item in forkAnchors) {
          if (item is! Map) continue;
          final id = backupImportString(item['id']);
          final mainConversationId = backupImportString(
            item['mainConversationId'],
          );
          final anchorMessageId = backupImportString(item['anchorMessageId']);
          final forkConversationId = backupImportString(
            item['forkConversationId'],
          );
          final selectedText = backupImportString(item['selectedText']);
          final createdAt = backupImportDateTime(item['createdAt']);
          if (id == null ||
              mainConversationId == null ||
              anchorMessageId == null ||
              forkConversationId == null ||
              selectedText == null ||
              createdAt == null) {
            continue;
          }
          final entity = ForkAnchorEntity(
            id: id,
            mainConversationId: mainConversationId,
            anchorMessageId: anchorMessageId,
            selectedText: selectedText,
            forkConversationId: forkConversationId,
            createdAt: createdAt,
          );
          final query = forkAnchorBox
              .query(ForkAnchorEntity_.id.equals(entity.id))
              .build();
          final existing = query.findFirst();
          query.close();
          if (existing != null) entity.internalId = existing.internalId;
          forkAnchorBox.put(entity);
        }
        // An anchor is the durable identity of a fork. If an older payload
        // lost the conversation's isFork flag, restore it from the anchor so
        // the fork never surfaces as a normal history row.
        final forkConversationIds = forkAnchorBox
            .getAll()
            .map((anchor) => anchor.forkConversationId)
            .toSet();
        for (final entity in convBox.getAll()) {
          if (forkConversationIds.contains(entity.id) && !entity.isFork) {
            entity.isFork = true;
            convBox.put(entity);
          }
        }
      }

      final messages = decoded['messages'];
      if (messages is List) {
        for (final item in messages) {
          if (item is! Map) continue;
          final conversationId = backupImportString(item['conversationId']);
          final id = backupImportString(item['id']);
          final createdAt = backupImportDateTime(item['createdAt']);
          if (conversationId == null || id == null || createdAt == null) {
            continue;
          }
          final convQuery = convBox
              .query(ConversationEntity_.id.equals(conversationId))
              .build();
          final convEntity = convQuery.findFirst();
          convQuery.close();
          if (convEntity == null) continue;

          final message = Message(
            id: id,
            conversationId: conversationId,
            role: MessageRole.values.byName(item['role'] as String? ?? 'user'),
            content: item['content'] as String? ?? '',
            createdAt: createdAt,
            updatedAt: backupImportDateTime(item['updatedAt']) ?? createdAt,
            status: MessageStatus.values.byName(
              item['status'] as String? ?? 'complete',
            ),
            modelId: item['modelId'] as String?,
            tokenCount: item['tokenCount'] as int?,
            inputTokenCount: item['inputTokenCount'] as int?,
            tokensPerSecond: (item['tokensPerSecond'] as num?)?.toDouble(),
            ttftMs: item['ttftMs'] as int?,
            stopReason: item['stopReason'] as String?,
            errorMessage: item['errorMessage'] as String?,
            attachmentPaths: _sanitizedAttachmentPaths(
              item['attachmentPaths'],
              attachmentsDir,
            ),
            generationTimeMs: item['generationTimeMs'] as int?,
            reasoningContent: item['reasoningContent'] as String?,
            toolCalls: item['toolCalls'] is List
                ? (item['toolCalls'] as List)
                      .whereType<Map>()
                      .map(
                        (e) =>
                            ToolCallData.fromMap(Map<String, dynamic>.from(e)),
                      )
                      .toList()
                : null,
            toolCallId: item['toolCallId'] as String?,
            isProcessing: item['isProcessing'] as bool? ?? false,
            toolSessionId: item['toolSessionId'] as String?,
            toolEvents: item['toolEvents'] is List
                ? (item['toolEvents'] as List)
                      .whereType<Map>()
                      .map(
                        (e) => ToolEvent.fromMap(Map<String, dynamic>.from(e)),
                      )
                      .toList()
                : null,
            variantGroupId: item['variantGroupId'] as String?,
            variantIndex: item['variantIndex'] as int? ?? 0,
            threadOrder: item['threadOrder'] as int? ?? 0,
            isActiveVariant: item['isActiveVariant'] as bool? ?? true,
            parentMessageId: item['parentMessageId'] as String?,
            contentTokenCount: item['contentTokenCount'] as int?,
          );

          final entity = MessageEntity.fromDomain(message)
            ..conversation.target = convEntity;
          final query = messageBox
              .query(MessageEntity_.id.equals(message.id))
              .build();
          final existing = query.findFirst();
          query.close();
          if (existing != null) entity.internalId = existing.internalId;
          messageBox.put(entity);
        }
      }

      if (replaceCloudData) {
        /// A snapshot may have been exported before a local write landed.
        /// Absence from the payload is therefore not proof of deletion — only
        /// the snapshot's tombstones are. A tombstone also only removes data
        /// recorded at or before the deletion instant, so a local edit made
        /// after the delete survives (same rule the merge uses).
        bool tombstoned(String collection, String id, DateTime? recordTime) {
          final deletedAt = DateTime.tryParse(
            tombstones[collection]?[id] ?? '',
          );
          if (deletedAt == null) return false;
          if (recordTime == null) return true;
          return !recordTime.toUtc().isAfter(deletedAt.toUtc());
        }

        convBox.removeMany(
          convBox
              .getAll()
              .where((item) => !item.isTemporary)
              .where(
                (item) => tombstoned('conversations', item.id, item.updatedAt),
              )
              .map((item) => item.internalId)
              .toList(),
        );
        messageBox.removeMany(
          messageBox
              .getAll()
              .where(
                (item) => tombstoned(
                  'messages',
                  item.id,
                  item.updatedAt ?? item.createdAt,
                ),
              )
              .map((item) => item.internalId)
              .toList(),
        );
        personaBox.removeMany(
          personaBox
              .getAll()
              .where(
                (item) =>
                    !item.isBuiltIn &&
                    tombstoned('personas', item.id, item.updatedAt),
              )
              .map((item) => item.internalId)
              .toList(),
        );
        savedBox.removeMany(
          savedBox
              .getAll()
              .where(
                (item) => tombstoned('savedMessages', item.id, item.savedAt),
              )
              .map((item) => item.internalId)
              .toList(),
        );
        savedFolderBox.removeMany(
          savedFolderBox
              .getAll()
              .where(
                (item) =>
                    tombstoned('savedMessageFolders', item.id, item.createdAt),
              )
              .map((item) => item.internalId)
              .toList(),
        );
        conversationFolderBox.removeMany(
          conversationFolderBox
              .getAll()
              .where(
                (item) =>
                    tombstoned('conversationFolders', item.id, item.createdAt),
              )
              .map((item) => item.internalId)
              .toList(),
        );
        forkAnchorBox.removeMany(
          forkAnchorBox
              .getAll()
              .where(
                (item) => tombstoned('forkAnchors', item.id, item.createdAt),
              )
              .map((item) => item.internalId)
              .toList(),
        );
      }
    }, (decoded, attachmentsDir, replaceCloudData, tombstones));
  }

  List<String>? _sanitizedAttachmentPaths(dynamic raw, String attachmentsDir) {
    if (raw is! List) return null;
    final sanitized = <String>[];
    for (final entry in raw) {
      if (entry is! String || entry.isEmpty) continue;
      final normalized = p.normalize(entry);
      if (normalized == attachmentsDir ||
          p.isWithin(attachmentsDir, normalized)) {
        sanitized.add(entry);
      }
    }
    return sanitized.isEmpty ? null : sanitized;
  }

  Future<void> importZip(Store store, List<int> bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive.files) {
      if (!file.isFile) continue;
      try {
        await importFromJson(store, utf8.decode(file.content as List<int>));
      } catch (_) {
        // skip corrupted entry
      }
    }
  }
}
