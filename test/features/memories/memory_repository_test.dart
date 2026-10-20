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

  test('touch bumps lastUsedAt and useCount', () {
    final repo = MemoryRepository(InMemoryMemoryStore());
    final a = repo.remember(title: 'A', content: 'a');
    repo.touch(a.id);
    final touched = repo.list().single;
    expect(touched.useCount, 1);
    expect(touched.lastUsedAt, isNotNull);
  });
}
