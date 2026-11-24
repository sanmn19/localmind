import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/chat_completion_notifier.dart';

void main() {
  test('preview collapses whitespace and clips long replies', () {
    expect(
      chatReplyPreview('  Hello\n\n  world  '),
      'Hello world',
    );
    final long = 'a' * 200;
    final preview = chatReplyPreview(long, maxChars: 20);
    expect(preview.length, 21);
    expect(preview.endsWith('…'), isTrue);
  });

  test('notification ids are stable and non-negative per conversation', () {
    final first = chatReplyNotificationId('conversation-1');
    expect(first, chatReplyNotificationId('conversation-1'));
    expect(first, isNonNegative);
    expect(
      chatReplyNotificationId('conversation-2'),
      isNot(first),
    );
  });
}
