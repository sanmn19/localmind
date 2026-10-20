import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/memories/data/memory_repository.dart';
import 'package:localmind/features/memories/data/memory_store.dart';
import 'package:localmind/features/memories/data/models/memory.dart';

void main() {
  test('remember merges a normalized duplicate instead of inserting', () {
    final repo = MemoryRepository(InMemoryMemoryStore());

    final first = repo.remember(
      title: 'Coffee',
      content: 'Oat milk flat white',
      kind: MemoryKind.preference,
    );
    final second = repo.remember(
      title: ' coffee ',
      content: 'OAT MILK FLAT WHITE',
      kind: MemoryKind.preference,
    );

    expect(second.id, first.id);
    expect(repo.list(), hasLength(1));
  });

  test('a blank content is rejected', () {
    final repo = MemoryRepository(InMemoryMemoryStore());
    expect(
      () => repo.remember(title: 'X', content: '   '),
      throwsArgumentError,
    );
  });

  test('a correction supersedes the old memory and hides it', () {
    final repo = MemoryRepository(InMemoryMemoryStore());
    final old = repo.remember(
      title: 'Coffee',
      content: 'Whole milk',
      kind: MemoryKind.preference,
    );
    final fixed = repo.correct(
      old.id,
      title: 'Coffee',
      content: 'Oat milk',
    );

    expect(fixed.supersededById, isNull);
    expect(repo.list().map((m) => m.id), isNot(contains(old.id)));
    expect(repo.list().single.content, 'Oat milk');
  });

  test('forget removes the memory and its relations', () {
    final repo = MemoryRepository(InMemoryMemoryStore());
    final a = repo.remember(title: 'A', content: 'a');
    final b = repo.remember(title: 'B', content: 'b');
    repo.link(from: a.id, to: b.id, label: 'related_to');

    expect(repo.forget(a.id), isTrue);
    expect(repo.list().map((m) => m.id), [b.id]);
    expect(repo.relationsFor(b.id), isEmpty);
  });

  test('archive hides the memory but keeps its relations', () {
    final repo = MemoryRepository(InMemoryMemoryStore());
    final a = repo.remember(title: 'A', content: 'a');
    repo.archive(a.id);
    expect(repo.list(), isEmpty);
  });

  test('put upserts by id instead of duplicating on every import', () {
    final store = InMemoryMemoryStore();
    final memory = Memory(
      id: 'm1',
      kind: MemoryKind.fact,
      title: 'Coffee',
      content: 'Oat milk',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    store.put(memory);
    store.put(memory.copyWith(content: 'Oat milk, extra shot'));
    expect(store.list(), hasLength(1));
    expect(store.list().single.content, 'Oat milk, extra shot');
  });

  test('putEmbedding replaces the vector for the same memory and model', () {
    final store = InMemoryMemoryStore();
    store.putEmbedding(
      MemoryEmbedding(
        memoryId: 'm1',
        modelId: 'e1',
        vector: const [1, 0],
        createdAt: DateTime(2026),
      ),
    );
    store.putEmbedding(
      MemoryEmbedding(
        memoryId: 'm1',
        modelId: 'e1',
        vector: const [0, 1],
        createdAt: DateTime(2026),
      ),
    );
    expect(store.listEmbeddings(), hasLength(1));
    expect(store.listEmbeddings().single.vector, [0, 1]);
  });

  test('touch bumps lastUsedAt and useCount', () {
    final repo = MemoryRepository(InMemoryMemoryStore());
    final a = repo.remember(title: 'A', content: 'a');
    repo.touch(a.id);
    final touched = repo.list().single;
    expect(touched.useCount, 1);
    expect(touched.lastUsedAt, isNotNull);
  });
}
