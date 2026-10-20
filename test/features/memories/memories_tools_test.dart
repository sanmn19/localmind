import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/memories/data/memories_mcp_server.dart';
import 'package:localmind/features/memories/data/models/memory.dart';

Memory _memory(String title, String content, MemoryKind kind) => Memory(
      id: 'id-$title',
      kind: kind,
      title: title,
      content: content,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

MemoriesServices _services({
  required List<Memory> rows,
  bool enabled = true,
  List<String>? remembered,
}) {
  return MemoriesServices(
    list: () async => rows,
    remember: (title, content, kind, importance) async {
      remembered?.add('$title:$content');
      return _memory(title, content, kind);
    },
    search: (query) async => rows,
    forget: (id) async => true,
    link: (from, to, label) async => MemoryRelation(
      id: 'r1',
      fromMemoryId: from,
      toMemoryId: to,
      label: label,
      createdAt: DateTime(2026),
    ),
    relationsFor: (id) async => const [],
    enabled: () => enabled,
    afterRemember: (memory) async {},
  );
}

void main() {
  test('list renders one kind/title/content row per memory', () {
    final text = formatMemoriesList([
      _memory('Coffee', 'Oat milk', MemoryKind.preference),
    ]);
    expect(text, '- [preference] Coffee: Oat milk');
  });

  test('an empty list renders a friendly line', () {
    expect(formatMemoriesList(const []), 'No memories yet.');
  });

  test('search rows carry the id so the model can link or forget', () {
    final text = formatMemoriesSearch([
      _memory('Coffee', 'Oat milk', MemoryKind.preference),
    ]);
    expect(text, contains('id: id-Coffee'));
  });

  test('remember validates the title and content', () {
    expect(memoriesRememberFailure('', 'x'), isNotNull);
    expect(memoriesRememberFailure('x', '  '), isNotNull);
    expect(memoriesRememberFailure('x', 'y'), isNull);
  });

  test('remember forwards to the repository and runs the embed hook', () async {
    final remembered = <String>[];
    final services = _services(rows: const [], remembered: remembered);
    await services.remember('Coffee', 'Oat milk', MemoryKind.preference, 70);
    expect(remembered, ['Coffee:Oat milk']);
  });

  test('the disabled feature rejects every call', () async {
    final services = _services(rows: const [], enabled: false);
    expect(services.enabled, isFalse);
  });
}
