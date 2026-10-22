import '../../../core/utils/uuid.dart';
import 'memory_store.dart';
import 'models/memory.dart';

/// Memory graph rules: normalized dedupe, correction supersession, edge cleanup.
class MemoryRepository {
  MemoryRepository(this._store);

  final MemoryStore _store;

  /// Every live memory (not archived, not superseded, not expired).
  List<Memory> list() {
    final now = DateTime.now();
    return _store
        .list()
        .where(
          (m) => !m.archived && m.supersededById == null && !_isExpired(m, now),
        )
        .toList();
  }

  /// Every memory the memories screen should show. Expired rows stay visible
  /// (the screen labels them "Expired"); archived and superseded rows do not.
  /// Retrieval keeps using [list], which excludes expired rows.
  List<Memory> listIncludingExpired() {
    return _store
        .list()
        .where((m) => !m.archived && m.supersededById == null)
        .toList();
  }

  Memory remember({
    required String title,
    required String content,
    MemoryKind kind = MemoryKind.fact,
    int importance = 50,
    String? scopeConversationId,
    String? excludeMemoryId,
    List<String> tags = const [],
    String shortSummary = '',
    DateTime? expiresAt,
    String? sourceApp,
  }) {
    if (kind == MemoryKind.inferred) {
      throw ArgumentError.value(
        kind,
        'kind',
        'use rememberInferred for inferred memories',
      );
    }
    return _remember(
      title: title,
      content: content,
      kind: kind,
      importance: importance,
      scopeConversationId: scopeConversationId,
      excludeMemoryId: excludeMemoryId,
      tags: tags,
      shortSummary: shortSummary,
      expiresAt: expiresAt,
      sourceApp: sourceApp,
    );
  }

  /// Creates an inferred memory. Only the screen batch should call this.
  Memory rememberInferred({
    required String title,
    required String content,
    List<String> tags = const [],
    String shortSummary = '',
    DateTime? expiresAt,
    String? sourceApp,
    int importance = 50,
  }) {
    return _remember(
      title: title,
      content: content,
      kind: MemoryKind.inferred,
      importance: importance,
      tags: tags,
      shortSummary: shortSummary,
      expiresAt: expiresAt,
      sourceApp: sourceApp,
    );
  }

  Memory _remember({
    required String title,
    required String content,
    MemoryKind kind = MemoryKind.fact,
    int importance = 50,
    String? scopeConversationId,
    String? excludeMemoryId,
    List<String> tags = const [],
    String shortSummary = '',
    DateTime? expiresAt,
    String? sourceApp,
  }) {
    final trimmedTitle = title.trim();
    final trimmedContent = content.trim();
    if (trimmedContent.isEmpty) {
      throw ArgumentError('memory content is required');
    }
    final normalizedTitle = trimmedTitle.toLowerCase();
    final normalizedContent = trimmedContent.toLowerCase();
    final normalizedTags = _normalizeTags(tags);
    final trimmedSummary = shortSummary.trim();
    final now = DateTime.now();
    for (final existing in _store.list()) {
      if (existing.id == excludeMemoryId) continue;
      if (existing.archived || existing.supersededById != null) continue;
      if (_isExpired(existing, now)) continue;
      if (existing.title.trim().toLowerCase() == normalizedTitle &&
          existing.content.trim().toLowerCase() == normalizedContent) {
        final updated = existing.copyWith(
          updatedAt: now,
          tags: _mergeTags(existing.tags, normalizedTags),
          shortSummary: _mergeSummary(existing.shortSummary, trimmedSummary),
          expiresAt: expiresAt,
          clearExpiresAt: expiresAt == null,
          sourceApp: sourceApp ?? existing.sourceApp,
        );
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
      if (_isExpired(existing, now)) continue;
      if (_titleSimilarity(existing.title, trimmedTitle) < 0.8) continue;
      final updated = existing.copyWith(
        content: trimmedContent,
        importance: importance.clamp(0, 100),
        updatedAt: now,
        tags: _mergeTags(existing.tags, normalizedTags),
        shortSummary: _mergeSummary(existing.shortSummary, trimmedSummary),
        expiresAt: expiresAt,
        clearExpiresAt: expiresAt == null,
        sourceApp: sourceApp ?? existing.sourceApp,
      );
      _store.put(updated);
      return updated;
    }
    final memory = Memory(
      id: generateUuidV4(),
      kind: kind,
      title: trimmedTitle,
      content: trimmedContent,
      importance: importance.clamp(0, 100),
      createdAt: now,
      updatedAt: now,
      scopeConversationId: scopeConversationId,
      tags: normalizedTags,
      shortSummary: trimmedSummary,
      expiresAt: expiresAt,
      sourceApp: sourceApp,
    );
    _store.put(memory);
    return memory;
  }

  /// Archives every live memory whose expiry has passed.
  void pruneExpired({DateTime? now}) {
    final cutoff = now ?? DateTime.now();
    for (final memory in _store.list()) {
      if (memory.archived || memory.supersededById != null) continue;
      if (!_isExpired(memory, cutoff)) continue;
      _store.put(memory.copyWith(archived: true));
    }
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
    final replacement = _remember(
      title: title,
      content: content,
      kind: kind ?? old.kind,
      importance: importance ?? old.importance,
      scopeConversationId: old.scopeConversationId,
      excludeMemoryId: oldId,
      tags: old.tags,
      shortSummary: old.shortSummary,
      expiresAt: old.expiresAt,
      sourceApp: old.sourceApp,
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

  static const _maxTags = 8;

  /// Lowercases, trims, drops blanks and duplicates, and caps at [_maxTags].
  static List<String> _normalizeTags(Iterable<String> tags) {
    final normalized = <String>[];
    for (final tag in tags) {
      final value = tag.trim().toLowerCase();
      if (value.isEmpty || normalized.contains(value)) continue;
      normalized.add(value);
      if (normalized.length == _maxTags) break;
    }
    return normalized;
  }

  /// Existing tags win on order; incoming tags are appended after normalization.
  static List<String> _mergeTags(
    Iterable<String> existing,
    Iterable<String> incoming,
  ) => _normalizeTags([...existing, ...incoming]);

  /// Keeps the stored summary unless the caller supplied a new one.
  static String _mergeSummary(String existing, String incoming) =>
      incoming.isEmpty ? existing : incoming;

  /// A memory expires only after its expiry instant; null means permanent.
  static bool _isExpired(Memory memory, DateTime now) {
    final expiresAt = memory.expiresAt;
    return expiresAt != null && now.isAfter(expiresAt);
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
