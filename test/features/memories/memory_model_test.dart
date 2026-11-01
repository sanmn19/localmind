import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/memories/data/models/memory.dart';

void main() {
  test('inferred is appended and survives a copyWith round-trip', () {
    expect(MemoryKind.values.last, MemoryKind.inferred);
    final memory = Memory(
      id: 'm1',
      kind: MemoryKind.inferred,
      title: 'Standup',
      content: 'Standup moved to 10:00.',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      tags: const ['work', 'standup'],
      shortSummary: 'Standup at 10:00',
      expiresAt: DateTime(2026, 10, 21),
      sourceApp: 'com.whatsapp',
    );
    final copy = memory.copyWith(tags: const ['work']);
    expect(copy.tags, ['work']);
    expect(copy.shortSummary, 'Standup at 10:00');
    expect(copy.expiresAt, DateTime(2026, 10, 21));
    expect(copy.sourceApp, 'com.whatsapp');
  });

  test('copyWith can clear expiry without touching other fields', () {
    final memory = Memory(
      id: 'm1',
      kind: MemoryKind.inferred,
      title: 'Standup',
      content: 'Standup moved to 10:00.',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      expiresAt: DateTime(2026, 10, 21),
    );

    final cleared = memory.copyWith(clearExpiresAt: true);

    expect(cleared.expiresAt, isNull);
    expect(cleared.title, memory.title);
    expect(cleared.tags, isEmpty);
    expect(cleared.shortSummary, isEmpty);
  });
}
