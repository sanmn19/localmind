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

  test('remember rejects inferred memories and stores nothing', () {
    final store = InMemoryMemoryStore();
    final repo = MemoryRepository(store);
    expect(
      () => repo.remember(
        title: 'Standup',
        content: 'Standup moved to 10:00.',
        kind: MemoryKind.inferred,
      ),
      throwsArgumentError,
    );
    expect(store.list(), isEmpty);
  });

  test('rememberInferred normalizes tags and stores expiry', () {
    final repo = MemoryRepository(InMemoryMemoryStore());
    final memory = repo.rememberInferred(
      title: 'Standup',
      content: 'Standup moved to 10:00.',
      tags: const [' Work ', 'work', 'Standup'],
      shortSummary: 'Standup at 10:00',
      expiresAt: DateTime(2026, 10, 21),
      sourceApp: 'com.whatsapp',
    );
    expect(memory.tags, ['work', 'standup']);
    expect(memory.shortSummary, 'Standup at 10:00');
    expect(memory.expiresAt, DateTime(2026, 10, 21));
    expect(memory.sourceApp, 'com.whatsapp');
  });

  test('list and pruneExpired exclude an expired inferred memory', () {
    final repo = MemoryRepository(InMemoryMemoryStore());
    repo.rememberInferred(
      title: 'Deadline',
      content: 'Ship on Monday',
      expiresAt: DateTime(2026, 10, 19),
    );
    expect(repo.list(), isEmpty);
    repo.pruneExpired(now: DateTime(2026, 10, 20));
    expect(repo.list(), isEmpty);
  });

  test('listIncludingExpired shows an expired memory that list hides', () {
    final repo = MemoryRepository(InMemoryMemoryStore());
    final expired = repo.rememberInferred(
      title: 'Deadline',
      content: 'Ship on Monday',
      expiresAt: DateTime.now().subtract(const Duration(days: 1)),
    );
    expect(repo.list(), isEmpty);
    expect(repo.listIncludingExpired().map((m) => m.id), [expired.id]);

    repo.archive(expired.id);
    expect(repo.listIncludingExpired(), isEmpty);
  });

  test('a near-duplicate inferred memory updates tags and expiry', () {
    final repo = MemoryRepository(InMemoryMemoryStore());
    final first = repo.rememberInferred(
      title: 'Standup time',
      content: '10:00',
      tags: const ['work'],
    );
    final second = repo.rememberInferred(
      title: 'Standup time',
      content: '10:30',
      tags: const ['work', 'standup'],
      expiresAt: DateTime(2026, 10, 21),
    );
    expect(second.id, first.id);
    expect(second.tags, ['work', 'standup']);
    expect(second.expiresAt, DateTime(2026, 10, 21));
  });

  test('correct preserves tags, summary, expiry, and source app', () {
    final repo = MemoryRepository(InMemoryMemoryStore());
    final old = repo.rememberInferred(
      title: 'Standup',
      content: '10:00',
      tags: const ['work'],
      shortSummary: 'Standup at 10:00',
      expiresAt: DateTime(2026, 10, 21),
      sourceApp: 'com.whatsapp',
    );
    final fixed = repo.correct(old.id, title: 'Standup', content: '10:30');

    expect(fixed.tags, ['work']);
    expect(fixed.shortSummary, 'Standup at 10:00');
    expect(fixed.expiresAt, DateTime(2026, 10, 21));
    expect(fixed.sourceApp, 'com.whatsapp');
  });

  test('remember caps tags at eight and drops blanks', () {
    final repo = MemoryRepository(InMemoryMemoryStore());
    final memory = repo.remember(
      title: 'Tags',
      content: 'Many tags',
      tags: const [
        '',
        '  ',
        'One',
        'two',
        'three',
        'four',
        'five',
        'six',
        'seven',
        'eight',
        'nine',
      ],
    );

    expect(memory.tags, [
      'one',
      'two',
      'three',
      'four',
      'five',
      'six',
      'seven',
      'eight',
    ]);
  });

  test('pruneExpired archives the expired row', () {
    final store = InMemoryMemoryStore();
    final repo = MemoryRepository(store);
    repo.rememberInferred(
      title: 'Deadline',
      content: 'Ship on Monday',
      expiresAt: DateTime(2026, 10, 19),
    );

    repo.pruneExpired(now: DateTime(2026, 10, 20));

    expect(store.list().single.archived, isTrue);
  });

  test('an expired row cannot absorb a new near-duplicate', () {
    final repo = MemoryRepository(InMemoryMemoryStore());
    final expired = repo.rememberInferred(
      title: 'Standup time',
      content: '10:00',
      expiresAt: DateTime(2026, 10, 19),
    );

    final fresh = repo.rememberInferred(
      title: 'Standup time',
      content: '10:30',
    );

    expect(fresh.id, isNot(expired.id));
    expect(repo.list().single.id, fresh.id);
  });

  test('an expiry equal to now is still live, one second earlier is expired', () {
    final store = InMemoryMemoryStore();
    final repo = MemoryRepository(store);
    final boundary = repo.rememberInferred(
      title: 'Boundary',
      content: 'still live',
      expiresAt: DateTime(2026, 10, 20, 12),
    );
    final past = repo.rememberInferred(
      title: 'Before boundary',
      content: 'expired',
      expiresAt: DateTime(2026, 10, 20, 11, 59, 59),
    );

    repo.pruneExpired(now: DateTime(2026, 10, 20, 12));

    final byId = {for (final memory in store.list()) memory.id: memory};
    expect(byId[boundary.id]!.archived, isFalse);
    expect(byId[past.id]!.archived, isTrue);
  });

  test('a null expiry on a near-duplicate clears the old expiry', () {
    final repo = MemoryRepository(InMemoryMemoryStore());
    final first = repo.rememberInferred(
      title: 'Standup time',
      content: '10:00',
      expiresAt: DateTime(2030),
    );
    final second = repo.rememberInferred(
      title: 'Standup time',
      content: '10:30',
    );

    expect(second.id, first.id);
    expect(second.expiresAt, isNull);
  });
}
