enum MemoryKind { fact, preference, entity, event }

class Memory {
  const Memory({
    required this.id,
    required this.kind,
    required this.title,
    required this.content,
    this.importance = 50,
    required this.createdAt,
    required this.updatedAt,
    this.lastUsedAt,
    this.useCount = 0,
    this.scopeConversationId,
    this.sourceConversationId,
    this.sourceMessageId,
    this.supersededById,
    this.archived = false,
  });

  final String id;
  final MemoryKind kind;
  final String title;
  final String content;

  /// 0–100; higher ranks earlier on retrieval ties.
  final int importance;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastUsedAt;
  final int useCount;
  /// Null means the memory is global; otherwise it only applies to this
  /// conversation.
  final String? scopeConversationId;
  final String? sourceConversationId;
  final String? sourceMessageId;

  /// Set when a correction replaced this memory.
  final String? supersededById;
  final bool archived;

  Memory copyWith({
    String? title,
    String? content,
    MemoryKind? kind,
    int? importance,
    DateTime? updatedAt,
    DateTime? lastUsedAt,
    int? useCount,
    String? supersededById,
    bool? archived,
  }) {
    return Memory(
      id: id,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      content: content ?? this.content,
      importance: importance ?? this.importance,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      useCount: useCount ?? this.useCount,
      scopeConversationId: scopeConversationId,
      sourceConversationId: sourceConversationId,
      sourceMessageId: sourceMessageId,
      supersededById: supersededById ?? this.supersededById,
      archived: archived ?? this.archived,
    );
  }
}

class MemoryRelation {
  const MemoryRelation({
    required this.id,
    required this.fromMemoryId,
    required this.toMemoryId,
    required this.label,
    required this.createdAt,
  });

  final String id;
  final String fromMemoryId;
  final String toMemoryId;
  final String label;
  final DateTime createdAt;
}


class MemoryEmbedding {
  const MemoryEmbedding({
    required this.memoryId,
    required this.modelId,
    required this.vector,
    required this.createdAt,
  });

  final String memoryId;
  final String modelId;
  final List<double> vector;
  final DateTime createdAt;
}
