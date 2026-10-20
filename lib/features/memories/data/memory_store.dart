import 'dart:typed_data';

import '../../../core/storage/entities.dart';
import '../../../objectbox.g.dart';
import 'models/memory.dart';

/// Persistence seam for the memory graph. Unit tests use
/// [InMemoryMemoryStore]; the app uses [ObjectBoxMemoryStore].
abstract class MemoryStore {
  List<Memory> list();

  List<MemoryRelation> listRelations();

  List<MemoryEmbedding> listEmbeddings();

  void put(Memory memory);

  void putRelation(MemoryRelation relation);

  void putEmbedding(MemoryEmbedding embedding);

  void delete(String memoryId);

  void deleteRelationsTouching(String memoryId);

  void deleteRelation(String relationId);
}

class ObjectBoxMemoryStore implements MemoryStore {
  ObjectBoxMemoryStore({
    required this.memories,
    required this.relations,
    required this.embeddings,
  });

  final Box<MemoryEntity> memories;
  final Box<MemoryRelationEntity> relations;
  final Box<MemoryEmbeddingEntity> embeddings;

  @override
  List<Memory> list() =>
      memories.getAll().map(_toDomain).toList();

  @override
  List<MemoryRelation> listRelations() =>
      relations.getAll().map(_relationToDomain).toList();

  @override
  List<MemoryEmbedding> listEmbeddings() => embeddings
      .getAll()
      .map(
        (entity) => MemoryEmbedding(
          memoryId: entity.memoryId,
          modelId: entity.modelId,
          vector: List<double>.from(entity.vector),
          createdAt: entity.createdAt,
        ),
      )
      .toList();

  @override
  void putEmbedding(MemoryEmbedding embedding) => embeddings.put(
        MemoryEmbeddingEntity(
          memoryId: embedding.memoryId,
          modelId: embedding.modelId,
          dims: embedding.vector.length,
          vector: Float32List.fromList(embedding.vector),
          createdAt: embedding.createdAt,
        ),
      );

  @override
  void put(Memory memory) => memories.put(_toEntity(memory));

  @override
  void putRelation(MemoryRelation relation) =>
      relations.put(_relationToEntity(relation));

  @override
  void delete(String memoryId) {
    final query = memories
        .query(MemoryEntity_.id.equals(memoryId))
        .build();
    try {
      memories.removeMany(query.findIds());
    } finally {
      query.close();
    }
  }

  @override
  void deleteRelationsTouching(String memoryId) {
    final query = relations
        .query(
          MemoryRelationEntity_.fromMemoryId
              .equals(memoryId)
              .or(MemoryRelationEntity_.toMemoryId.equals(memoryId)),
        )
        .build();
    try {
      relations.removeMany(query.findIds());
    } finally {
      query.close();
    }
  }

  @override
  void deleteRelation(String relationId) {
    final query = relations
        .query(MemoryRelationEntity_.id.equals(relationId))
        .build();
    try {
      relations.removeMany(query.findIds());
    } finally {
      query.close();
    }
  }

  Memory _toDomain(MemoryEntity entity) => Memory(
        id: entity.id,
        kind: MemoryKind.values[entity.kindIndex.clamp(0, MemoryKind.values.length - 1)],
        title: entity.title,
        content: entity.content,
        importance: entity.importance,
        createdAt: entity.createdAt,
        updatedAt: entity.updatedAt,
        lastUsedAt: entity.lastUsedAt,
        useCount: entity.useCount,
        sourceConversationId: entity.sourceConversationId,
        sourceMessageId: entity.sourceMessageId,
        supersededById: entity.supersededById,
        archived: entity.archived,
      );

  MemoryEntity _toEntity(Memory memory) => MemoryEntity(
        id: memory.id,
        kindIndex: memory.kind.index,
        title: memory.title,
        content: memory.content,
        importance: memory.importance,
        createdAt: memory.createdAt,
        updatedAt: memory.updatedAt,
        lastUsedAt: memory.lastUsedAt,
        useCount: memory.useCount,
        sourceConversationId: memory.sourceConversationId,
        sourceMessageId: memory.sourceMessageId,
        supersededById: memory.supersededById,
        archived: memory.archived,
      );

  MemoryRelation _relationToDomain(MemoryRelationEntity entity) =>
      MemoryRelation(
        id: entity.id,
        fromMemoryId: entity.fromMemoryId,
        toMemoryId: entity.toMemoryId,
        label: entity.label,
        createdAt: entity.createdAt,
      );

  MemoryRelationEntity _relationToEntity(MemoryRelation relation) =>
      MemoryRelationEntity(
        id: relation.id,
        fromMemoryId: relation.fromMemoryId,
        toMemoryId: relation.toMemoryId,
        label: relation.label,
        createdAt: relation.createdAt,
      );
}

class InMemoryMemoryStore implements MemoryStore {
  final List<Memory> _memories = [];
  final List<MemoryRelation> _relations = [];
  final List<MemoryEmbedding> _embeddings = [];

  @override
  List<Memory> list() => List<Memory>.from(_memories);

  @override
  List<MemoryRelation> listRelations() =>
      List<MemoryRelation>.from(_relations);

  @override
  void put(Memory memory) {
    final index = _memories.indexWhere((m) => m.id == memory.id);
    if (index >= 0) {
      _memories[index] = memory;
    } else {
      _memories.add(memory);
    }
  }

  @override
  void putRelation(MemoryRelation relation) => _relations.add(relation);

  @override
  List<MemoryEmbedding> listEmbeddings() =>
      List<MemoryEmbedding>.from(_embeddings);

  @override
  void putEmbedding(MemoryEmbedding embedding) => _embeddings.add(embedding);

  @override
  void delete(String memoryId) =>
      _memories.removeWhere((m) => m.id == memoryId);

  @override
  void deleteRelationsTouching(String memoryId) => _relations.removeWhere(
        (r) => r.fromMemoryId == memoryId || r.toMemoryId == memoryId,
      );

  @override
  void deleteRelation(String relationId) =>
      _relations.removeWhere((r) => r.id == relationId);
}
