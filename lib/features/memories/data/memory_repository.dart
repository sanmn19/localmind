import '../../../core/utils/uuid.dart';
import 'memory_store.dart';
import 'models/memory.dart';

/// Memory graph rules: normalized dedupe, correction supersession, edge cleanup.
class MemoryRepository {
  MemoryRepository(this._store);

  final MemoryStore _store;

  /// Every live memory (not archived, not superseded).
  List<Memory> list() => _store
      .list()
      .where((m) => !m.archived && m.supersededById == null)
      .toList();

  Memory remember({
    required String title,
    required String content,
    MemoryKind kind = MemoryKind.fact,
    int importance = 50,
  }) {
    final trimmedTitle = title.trim();
    final trimmedContent = content.trim();
    if (trimmedContent.isEmpty) {
      throw ArgumentError('memory content is required');
    }
    final normalizedTitle = trimmedTitle.toLowerCase();
    final normalizedContent = trimmedContent.toLowerCase();
    for (final existing in _store.list()) {
      if (existing.archived || existing.supersededById != null) continue;
      if (existing.title.trim().toLowerCase() == normalizedTitle &&
          existing.content.trim().toLowerCase() == normalizedContent) {
        final updated = existing.copyWith(updatedAt: DateTime.now());
        _store.put(updated);
        return updated;
      }
    }
    final now = DateTime.now();
    final memory = Memory(
      id: generateUuidV4(),
      kind: kind,
      title: trimmedTitle,
      content: trimmedContent,
      importance: importance.clamp(0, 100),
      createdAt: now,
      updatedAt: now,
    );
    _store.put(memory);
    return memory;
  }

  /// Stores a replacement and marks [oldId] superseded by it.
  Memory correct(
    String oldId, {
    required String title,
    required String content,
    MemoryKind? kind,
    int? importance,
  }) {
    Memory? old;
    for (final memory in _store.list()) {
      if (memory.id == oldId) old = memory;
    }
    if (old == null) {
      throw ArgumentError('unknown memory "$oldId"');
    }
    final replacement = remember(
      title: title,
      content: content,
      kind: kind ?? old.kind,
      importance: importance ?? old.importance,
    );
    _store.put(old.copyWith(supersededById: replacement.id));
    return replacement;
  }

  bool forget(String memoryId) {
    var exists = false;
    for (final memory in _store.list()) {
      if (memory.id == memoryId) exists = true;
    }
    if (!exists) return false;
    _store.delete(memoryId);
    _store.deleteRelationsTouching(memoryId);
    return true;
  }

  void archive(String memoryId) {
    for (final memory in _store.list()) {
      if (memory.id != memoryId) continue;
      _store.put(memory.copyWith(archived: true));
    }
  }

  MemoryRelation link({
    required String from,
    required String to,
    required String label,
  }) {
    final relation = MemoryRelation(
      id: generateUuidV4(),
      fromMemoryId: from,
      toMemoryId: to,
      label: label.trim(),
      createdAt: DateTime.now(),
    );
    _store.putRelation(relation);
    return relation;
  }

  bool unlink(String relationId) {
    _store.deleteRelation(relationId);
    return true;
  }

  List<MemoryRelation> relationsFor(String memoryId) => _store
      .listRelations()
      .where(
        (relation) =>
            relation.fromMemoryId == memoryId ||
            relation.toMemoryId == memoryId,
      )
      .toList();

  void touch(String memoryId) {
    for (final memory in _store.list()) {
      if (memory.id != memoryId) continue;
      _store.put(
        memory.copyWith(
          lastUsedAt: DateTime.now(),
          useCount: memory.useCount + 1,
        ),
      );
    }
  }
}
