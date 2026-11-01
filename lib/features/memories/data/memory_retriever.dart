import 'dart:math' as math;

import 'embedding_gateway.dart';
import 'memory_repository.dart';
import 'memory_store.dart';
import 'models/memory.dart';

/// Hybrid memory retrieval: embeddings when the provider supports them, keyword +
/// graph + recency everywhere. Never throws — a failed embed degrades to keyword.
class MemoryRetriever {
  MemoryRetriever({
    required this.store,
    required this.repository,
    required this.embeddings,
  });

  final MemoryStore store;
  final MemoryRepository repository;
  final EmbeddingGateway embeddings;

  static const defaultTopK = 8;
  static const defaultBudget = 2000;

  Future<List<Memory>> retrieve(
    String query, {
    int topK = defaultTopK,
    int budget = defaultBudget,
    String? conversationId,
  }) async {
    final now = DateTime.now();
    final live = repository
        .list()
        .where((memory) => !memory.isExpired)
        .where(
          (memory) =>
              memory.scopeConversationId == null ||
              memory.scopeConversationId == conversationId,
        )
        .toList();
    if (live.isEmpty) return const [];

    final byId = {for (final memory in live) memory.id: memory};
    final relations = store
        .listRelations()
        .where(
          (relation) =>
              byId.containsKey(relation.fromMemoryId) &&
              byId.containsKey(relation.toMemoryId),
        )
        .toList();

    final scores = <String, double>{};
    final queryTokens = _tokens(query);
    final queryVector = await _embed(query);
    if (queryVector != null) {
      final vectors = {
        for (final embedding in store.listEmbeddings())
          if (embedding.modelId == embeddings.modelId)
            embedding.memoryId: embedding.vector,
      };
      for (final memory in live) {
        final vector = vectors[memory.id];
        if (vector == null || vector.length != queryVector.length) continue;
        scores[memory.id] = _cosine(queryVector, vector);
      }
      // Graph evidence: a neighbour of a strong hit is likely relevant too.
      for (final relation in relations) {
        final from = scores[relation.fromMemoryId] ?? 0;
        final to = scores[relation.toMemoryId] ?? 0;
        scores[relation.fromMemoryId] =
            (scores[relation.fromMemoryId] ?? 0) + 0.25 * to;
        scores[relation.toMemoryId] =
            (scores[relation.toMemoryId] ?? 0) + 0.25 * from;
      }
    } else {
      for (final memory in live) {
        scores[memory.id] = _keywordScore(queryTokens, memory);
      }
      for (final relation in relations) {
        final from = scores[relation.fromMemoryId] ?? 0;
        final to = scores[relation.toMemoryId] ?? 0;
        scores[relation.fromMemoryId] =
            (scores[relation.fromMemoryId] ?? 0) + 0.25 * to;
        scores[relation.toMemoryId] =
            (scores[relation.toMemoryId] ?? 0) + 0.25 * from;
      }
    }

    double baseScore(Memory memory) =>
        (scores[memory.id] ?? 0) + _tagBoost(queryTokens, memory);

    final ranked = live.where((memory) => baseScore(memory) > 0).map((memory) {
      final recency = _recencyScore(memory, now);
      final importance = memory.importance / 100;
      return (
        memory: memory,
        score: baseScore(memory) + 0.15 * recency + 0.15 * importance,
      );
    }).toList()..sort((a, b) => b.score.compareTo(a.score));

    final selected = <Memory>[];
    var used = 0;
    for (final row in ranked) {
      if (selected.length >= topK) break;
      final body =
          row.memory.kind == MemoryKind.inferred &&
              row.memory.shortSummary.isNotEmpty
          ? row.memory.shortSummary
          : row.memory.content;
      final length = row.memory.title.length + body.length + 16;
      if (used + length > budget && selected.isNotEmpty) break;
      selected.add(row.memory);
      used += length;
    }
    return selected;
  }

  Future<List<double>?> _embed(String query) async {
    if (!embeddings.isAvailable) return null;
    if (query.trim().isEmpty) return null;
    return embeddings.embed(query);
  }

  double _keywordScore(Set<String> queryTokens, Memory memory) {
    if (queryTokens.isEmpty) return 0;
    final memoryTokens = _tokens(
      '${memory.title} ${memory.content} ${memory.tags.join(' ')}',
    );
    if (memoryTokens.isEmpty) return 0;
    var overlap = 0;
    for (final token in queryTokens) {
      if (memoryTokens.contains(token)) overlap++;
    }
    return overlap / queryTokens.length;
  }

  /// An exact query-token/tag match adds a small, deterministic boost.
  double _tagBoost(Set<String> queryTokens, Memory memory) =>
      memory.tags.any(queryTokens.contains) ? 0.1 : 0;

  Set<String> _tokens(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((token) => token.length > 1)
      .toSet();

  double _recencyScore(Memory memory, DateTime now) {
    final stamp = memory.lastUsedAt ?? memory.updatedAt;
    final days = now.difference(stamp).inDays;
    if (days <= 0) return 1;
    return 1 / (1 + days / 30);
  }

  double _cosine(List<double> a, List<double> b) {
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }
}
