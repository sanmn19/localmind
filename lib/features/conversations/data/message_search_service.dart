import '../../../core/models/enums.dart';
import '../../../core/storage/entities.dart';
import '../../../core/storage/objectbox_store.dart';
import '../../../objectbox.g.dart';
import '../../chat/data/models/background_task.dart';
import 'models/message_search_hit.dart';

class MessageSearchService {
  const MessageSearchService();

  List<MessageSearchHit> searchMessages(
    ObjectBoxStore db, {
    required String query,
    int limit = 50,
    Set<String> excludedConversationIds = const {},
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return const [];

    final hits = <MessageSearchHit>[];
    final conversationIds = <String>{};
    final messageQuery = db.messageBox
        .query(
          MessageEntity_.content.contains(
            normalizedQuery,
            caseSensitive: false,
          ),
        )
        .build();
    final messages = messageQuery.find();
    messageQuery.close();

    for (final entity in messages) {
      // Hidden fork conversations (selection-fork feature) must not surface
      // in message search; their turns live only in the fork panel.
      if (excludedConversationIds.contains(entity.conversationUid)) continue;
      if (!entity.content.toLowerCase().contains(normalizedQuery)) continue;

      final content = entity.content;
      final index = content.toLowerCase().indexOf(normalizedQuery);
      final start = index > 40 ? index - 40 : 0;
      final end = (index + normalizedQuery.length + 40).clamp(
        0,
        content.length,
      );
      var snippet = content.substring(start, end);
      if (start > 0) snippet = '…$snippet';
      if (end < content.length) snippet = '$snippet…';

      conversationIds.add(entity.conversationUid);
      hits.add(
        MessageSearchHit(
          messageId: entity.id,
          conversationId: entity.conversationUid,
          conversationTitle: 'Chat',
          snippet: snippet,
          role: MessageRole.values[entity.roleIndex],
        ),
      );
      if (hits.length >= limit) break;
    }

    if (hits.isEmpty) return hits;

    final titleById = _loadConversationTitles(db, conversationIds);
    return hits
        .map(
          (hit) => MessageSearchHit(
            messageId: hit.messageId,
            conversationId: hit.conversationId,
            conversationTitle: titleById[hit.conversationId] ?? 'Chat',
            snippet: hit.snippet,
            role: hit.role,
          ),
        )
        .toList();
  }

  /// Ids of hidden fork and background-task conversations, plus the task
  /// conversation ids recorded in the tasks table. Callers pass the parcel
  /// via `excludedConversationIds` so hidden conversations' turns never
  /// leak into chat history search. (Fork selection panel: `isFork`;
  /// background sub-agents: `isBackground` + `BackgroundTaskEntity`
  /// rows — the tasks-table parcel covers the window where a task row
  /// exists before its conversation row does.)
  ///
  /// Parity note: fork/task rows are fetched through TWO separate
  /// flag-condition queries instead of one `or()` group — condition groups
  /// hit the native library at construction time, which the host probe
  /// convention (fork_service_test.dart) cannot load.
  Set<String> hiddenConversationIds(ObjectBoxStore db) {
    final ids = <String>{};

    final forkQuery = db.conversationBox
        .query(ConversationEntity_.isFork.equals(true))
        .build();
    final forks = forkQuery.find();
    forkQuery.close();
    // Mirror the pushed-down conditions in Dart — keeps the
    // condition-agnostic persistence fakes authoritative.
    ids.addAll(forks.where((e) => e.isFork).map((e) => e.id));

    final bgQuery = db.conversationBox
        .query(ConversationEntity_.isBackground.equals(true))
        .build();
    final backgrounds = bgQuery.find();
    bgQuery.close();
    ids.addAll(
      backgrounds.where((e) => e.isBackground).map((e) => e.id),
    );

    final taskBox = db.store.box<BackgroundTaskEntity>();
    final taskQuery = taskBox
        .query(
          BackgroundTaskEntity_.state
              .equals(BackgroundTaskState.running.name),
        )
        .build();
    final taskRows = taskQuery.find();
    taskQuery.close();
    ids.addAll(
      taskRows
          .where((row) => row.state == BackgroundTaskState.running.name)
          .map((row) => row.taskConversationId),
    );

    return ids;
  }

  Map<String, String> _loadConversationTitles(
    ObjectBoxStore db,
    Set<String> conversationIds,
  ) {
    if (conversationIds.isEmpty) return const {};

    final query = db.conversationBox
        .query(
          ConversationEntity_.id.oneOf(conversationIds.toList(growable: false)),
        )
        .build();
    final entities = query.find();
    query.close();

    return {for (final entity in entities) entity.id: entity.title};
  }
}
