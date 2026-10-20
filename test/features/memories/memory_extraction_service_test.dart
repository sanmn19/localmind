import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/memories/data/memory_extraction_service.dart';
import 'package:localmind/features/memories/data/models/memory.dart';

void main() {
  final service = MemoryExtractionService();

  test('parses a JSON array and maps kinds, importance and scope', () {
    final parsed = service.parse('''
```json
[
  {"kind":"preference","title":"Coffee order","content":"Prefers oat milk flat whites.","importance":70,"scope":"global"},
  {"kind":"event","title":"Kitchen renovation","content":"Renovating the kitchen in November.","importance":45,"scope":"chat"}
]
```
''');
    expect(parsed, hasLength(2));
    expect(parsed.first.kind, MemoryKind.preference);
    expect(parsed.first.title, 'Coffee order');
    expect(parsed.first.importance, 70);
    expect(parsed.first.conversationScoped, isFalse);
    expect(parsed.last.kind, MemoryKind.event);
    expect(parsed.last.conversationScoped, isTrue);
  });

  test('drops secret-looking memories', () {
    final parsed = service.parse(
      '[{"kind":"fact","title":"API key","content":"sk-abcdef1234567890",'
      '"importance":90,"scope":"global"}]',
    );
    expect(parsed, isEmpty);
  });

  test('caps a turn at three memories', () {
    final parsed = service.parse(
      '[{"kind":"fact","title":"A","content":"one","importance":50},'
      '{"kind":"fact","title":"B","content":"two","importance":50},'
      '{"kind":"fact","title":"C","content":"three","importance":50},'
      '{"kind":"fact","title":"D","content":"four","importance":50}]',
    );
    expect(parsed, hasLength(3));
  });

  test('returns empty for prose or invalid output', () {
    expect(service.parse('Nothing worth remembering.'), isEmpty);
    expect(service.parse('[{"title":'), isEmpty);
  });

  test('clamps importance into 0-100', () {
    final parsed = service.parse(
      '[{"kind":"fact","title":"Age","content":"42 years old.","importance":900}]',
    );
    expect(parsed.single.importance, 100);
  });
}
