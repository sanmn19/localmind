import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';

void main() {
  test('fork fields default null and survive copyWith', () {
    final c = Conversation(
      id: 'c1', title: 't', createdAt: DateTime(2026), updatedAt: DateTime(2026),
    );
    expect(c.forkOfMessageId, isNull);
    expect(c.isFork, isFalse);
    final f = c.copyWith(
      forkOfMessageId: 'm1',
      forkSpan: 'kind: span',
      isFork: true,
    );
    expect(f.isFork, isTrue);
    expect(f.forkOfMessageId, 'm1');
  });
}
