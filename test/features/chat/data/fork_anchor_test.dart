import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/features/chat/data/models/fork_anchor.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';

void main() {
  test('fork fields default null and survive copyWith', () {
    final c = Conversation(
      id: 'c1',
      title: 't',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
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

  test('copyWith(clearForkOfMessageId) nulls the link, isFork independent', () {
    final c = Conversation(
      id: 'c1',
      title: 't',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      forkOfMessageId: 'm1',
      forkSpan: 'kind: span',
      isFork: true,
    );
    final cleared = c.copyWith(clearForkOfMessageId: true);
    expect(cleared.forkOfMessageId, isNull);
    expect(cleared.forkSpan, 'kind: span');
    expect(cleared.isFork, isTrue);

    final unForked = c.copyWith(clearForkOfMessageId: true, isFork: false);
    expect(unForked.forkOfMessageId, isNull);
    expect(unForked.isFork, isFalse);
    final reForked = unForked.copyWith(forkOfMessageId: 'm2', isFork: true);
    expect(reForked.forkOfMessageId, 'm2');
    expect(reForked.isFork, isTrue);
  });

  test('copyWith(clearForkSpan) beats a simultaneous forkSpan set', () {
    final c = Conversation(
      id: 'c1',
      title: 't',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      forkOfMessageId: 'm1',
      forkSpan: 'kind: span',
      isFork: true,
    );
    final cleared = c.copyWith(forkSpan: 'x', clearForkSpan: true);
    expect(cleared.forkSpan, isNull);
    expect(cleared.forkOfMessageId, 'm1');
    expect(cleared.isFork, isTrue);

    final bare = c.copyWith(clearForkSpan: true);
    expect(bare.forkSpan, isNull);
  });

  test(
    'ForkAnchor toJson/fromMap round-trip all six fields at millis precision',
    () {
      final a = ForkAnchor(
        id: 'fa-1',
        mainConversationId: 'c-main',
        anchorMessageId: 'm-anchor',
        selectedText: '  verbatim text ',
        forkConversationId: 'c-fork',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1770000000123),
      );
      final json = a.toJson();
      expect(json.keys.length, 6);
      expect(json['createdAt'], 1770000000123);
      expect(a.createdAt.millisecondsSinceEpoch, json['createdAt']);

      final back = ForkAnchor.fromMap(json);
      expect(back.id, a.id);
      expect(back.mainConversationId, a.mainConversationId);
      expect(back.anchorMessageId, a.anchorMessageId);
      expect(back.selectedText, a.selectedText);
      expect(back.forkConversationId, a.forkConversationId);
      expect(
        back.createdAt.millisecondsSinceEpoch,
        a.createdAt.millisecondsSinceEpoch,
      );
      expect(back.toJson(), equals(json));
    },
  );

  test('ForkAnchorEntity fromDomain/toDomain round-trip a ForkAnchor', () {
    final a = ForkAnchor(
      id: 'fa-2',
      mainConversationId: 'c-main',
      anchorMessageId: 'm-anchor',
      selectedText: 'snippet to anchor',
      forkConversationId: 'c-fork',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1770000000456),
    );
    final entity = ForkAnchorEntity.fromDomain(a);
    expect(entity.internalId, 0);
    final back = entity.toDomain();
    expect(back.id, a.id);
    expect(back.mainConversationId, a.mainConversationId);
    expect(back.anchorMessageId, a.anchorMessageId);
    expect(back.selectedText, a.selectedText);
    expect(back.forkConversationId, a.forkConversationId);
    expect(
      back.createdAt.millisecondsSinceEpoch,
      a.createdAt.millisecondsSinceEpoch,
    );
  });
}
