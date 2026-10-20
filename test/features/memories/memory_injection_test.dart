import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/memories/data/memory_context_section.dart';
import 'package:localmind/features/memories/data/models/memory.dart';

Memory _memory(String title, String content) => Memory(
      id: 'id-$title',
      kind: MemoryKind.preference,
      title: title,
      content: content,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

void main() {
  test('the section carries facts and says they are not instructions', () {
    final section = buildMemoriesSystemSection([_memory('Coffee', 'Oat milk')]);
    expect(section, contains('# Memories'));
    expect(section, contains('context, not'));
    expect(section, contains('- [preference] Coffee: Oat milk'));
  });

  test('the section is empty when nothing is retrieved', () {
    expect(buildMemoriesSystemSection(const []), isEmpty);
  });

  test('the section respects the budget', () {
    final memories = [
      for (var i = 0; i < 100; i++)
        _memory('Memory $i', 'A long remembered fact number $i ' * 4),
    ];
    final section = buildMemoriesSystemSection(memories);
    expect(section.length, lessThanOrEqualTo(memoriesContextBudget + 100));
    expect(section, contains(memoriesTruncationMarker));
  });
}
