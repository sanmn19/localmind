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
    String? scopeConversationId,
    String? excludeMemoryId,
  }) {
    final trimmedTitle = title.trim();
    final trimmedContent = content.trim();
    if (trimmedContent.isEmpty) {
      throw ArgumentError('memory content is required');
    }
    final normalizedTitle = trimmedTitle.toLowerCase();
    final normalizedContent = trimmedContent.toLowerCase();
    for (final existing in _store.list()) {
      if (existing.id == excludeMemoryId) continue;
      if (existing.archived || existing.supersededById != null) continue;
      if (existing.title.trim().toLowerCase() == normalizedTitle &&
          existing.content.trim().toLowerCase() == normalizedContent) {
        final updated = existing.copyWith(updatedAt: DateTime.now());
        _store.put(updated);
        return updated;
      }
    }
    // The extractor is allowed to rephrase a title, so also merge on a high
    // title-token overlap. Without this, auto-remember slowly accumulates
    // near-duplicates of the same fact.
    for (final existing in _store.list()) {
      if (existing.id == excludeMemoryId) continue;
      if (existing.archived || existing.supersededById != null) continue;
      if (_titleSimilarity(existing.title, trimmedTitle) < 0.8) continue;
      final updated = existing.copyWith(
        content: trimmedContent,
        importance: importance.clamp(0, 100),
        updatedAt: DateTime.now(),
      );
      _store.put(updated);
      return updated;
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
      scopeConversationId: scopeConversationId,
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
      scopeConversationId: old.scopeConversationId,
      excludeMemoryId: oldId,
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

  static const _titleStopWords = {
    'a', 'an', 'and', 'the', 'my', 'our', 'your', 'user', 'users',
    'is', 'are', 'of', 'to', 'for', 'in', 'on', 'with', 'prefers',
  };

  static Set<String> _titleTokens(String title) => title
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((token) => token.isNotEmpty && !_titleStopWords.contains(token))
      .toSet();

  static double _titleSimilarity(String a, String b) {
    final left = _titleTokens(a);
    final right = _titleTokens(b);
    if (left.isEmpty || right.isEmpty) return 0;
    final intersection = left.intersection(right).length;
    final union = left.union(right).length;
    return union == 0 ? 0 : intersection / union;
  }
}
