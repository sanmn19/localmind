import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/memories/data/embedding_gateway.dart';
import 'package:localmind/features/memories/data/memory_repository.dart';
import 'package:localmind/features/memories/data/memory_retriever.dart';
import 'package:localmind/features/memories/data/memory_store.dart';
import 'package:localmind/features/memories/data/models/memory.dart';

class _FakeEmbeddings implements EmbeddingGateway {
  _FakeEmbeddings(this.vectors);

  final Map<String, List<double>> vectors;

  @override
  bool get isAvailable => true;

  @override
  String get modelId => 'fake';

  @override
  Future<List<double>?> embed(String text) async => vectors[text];
}

class _StoreWithEmbeddings extends InMemoryMemoryStore {
  final List<MemoryEmbedding> _embeddings = [];

  @override
  List<MemoryEmbedding> listEmbeddings() =>
      List<MemoryEmbedding>.from(_embeddings);

  @override
  void putEmbedding(MemoryEmbedding embedding) => _embeddings.add(embedding);
}

MemoryRetriever _retriever(
  MemoryRepository repo,
  MemoryStore store,
  EmbeddingGateway gateway,
) =>
    MemoryRetriever(store: store, repository: repo, embeddings: gateway);

void main() {
  test('retrieves the semantically closer memory first', () async {
    final store = _StoreWithEmbeddings();
    final repo = MemoryRepository(store);
    final a = repo.remember(title: 'Coffee', content: 'Oat milk');
    final b = repo.remember(title: 'Car', content: 'Electric');
    store.putEmbedding(
      MemoryEmbedding(
        memoryId: a.id,
        modelId: 'fake',
        vector: const [1, 0],
        createdAt: DateTime(2026),
      ),
    );
    store.putEmbedding(
      MemoryEmbedding(
        memoryId: b.id,
        modelId: 'fake',
        vector: const [0, 1],
        createdAt: DateTime(2026),
      ),
    );

    final rows = await _retriever(
      repo,
      store,
      _FakeEmbeddings({'coffee drink': const [1, 0]}),
    ).retrieve('coffee drink');

    expect(rows.first.id, a.id);
  });

  test('falls back to keywords when embeddings are unavailable', () async {
    final store = InMemoryMemoryStore();
    final repo = MemoryRepository(store);
    final a = repo.remember(title: 'Coffee', content: 'Oat milk');
    repo.remember(title: 'Car', content: 'Electric');

    final rows = await _retriever(
      repo,
      store,
      const NoopEmbeddingGateway(),
    ).retrieve('oat milk');

    expect(rows.single.id, a.id);
  });

  test('a relation boosts its neighbour into the results', () async {
    final store = InMemoryMemoryStore();
    final repo = MemoryRepository(store);
    final a = repo.remember(title: 'Coffee', content: 'Oat milk');
    final b = repo.remember(title: 'Cafe', content: 'Corner shop');
    repo.link(from: a.id, to: b.id, label: 'likes');

    final rows = await _retriever(
      repo,
      store,
      const NoopEmbeddingGateway(),
    ).retrieve('oat milk');

    expect(rows.map((m) => m.id), contains(b.id));
  });

  test('the budget caps the rows', () async {
    final store = InMemoryMemoryStore();
    final repo = MemoryRepository(store);
    for (var i = 0; i < 20; i++) {
      repo.remember(title: 'Coffee $i', content: 'Oat milk $i');
    }

    final rows = await _retriever(
      repo,
      store,
      const NoopEmbeddingGateway(),
    ).retrieve('oat milk', budget: 40);

    expect(rows, hasLength(1));
  });
}
