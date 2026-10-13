import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/features/chat/data/models/background_task.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';

void main() {
  test('isBackground defaults false and survives copyWith', () {
    final c = Conversation(
      id: 'c1',
      title: 't',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    expect(c.isBackground, isFalse);
    final bg = c.copyWith(isBackground: true);
    expect(bg.isBackground, isTrue);
    final fg = bg.copyWith(isBackground: false);
    expect(fg.isBackground, isFalse);
  });

  test(
    'BackgroundTask toJson/fromMap round-trip all fields, millis precision',
    () {
      final t = BackgroundTask(
        id: 'bt-1',
        ownerConversationId: 'c-owner',
        taskConversationId: 'c-task',
        prompt: 'do the thing',
        loopMinutes: 30,
        maxRuns: 5,
        runCount: 2,
        state: BackgroundTaskState.running,
        lastRunAt: DateTime.fromMillisecondsSinceEpoch(1770000000123),
        createdAt: DateTime.fromMillisecondsSinceEpoch(1769999000456),
        resultMessageId: 'm-result',
        ownerMessageId: 'm-owner',
      );
      final json = t.toJson();
      expect(json.keys.length, 12);
      expect(json['state'], 'running');
      expect(json['lastRunAt'], 1770000000123);
      expect(t.lastRunAt!.millisecondsSinceEpoch, json['lastRunAt']);

      final back = BackgroundTask.fromMap(json);
      expect(back.id, t.id);
      expect(back.ownerConversationId, t.ownerConversationId);
      expect(back.taskConversationId, t.taskConversationId);
      expect(back.prompt, t.prompt);
      expect(back.loopMinutes, t.loopMinutes);
      expect(back.maxRuns, t.maxRuns);
      expect(back.runCount, t.runCount);
      expect(back.state, t.state);
      expect(
        back.lastRunAt!.millisecondsSinceEpoch,
        t.lastRunAt!.millisecondsSinceEpoch,
      );
      expect(
        back.createdAt.millisecondsSinceEpoch,
        t.createdAt.millisecondsSinceEpoch,
      );
      expect(back.resultMessageId, t.resultMessageId);
      expect(back.ownerMessageId, t.ownerMessageId);
      expect(back.toJson(), equals(json));
    },
  );

  test('BackgroundTask toJson/fromMap with null optionals and initial state', () {
    final t = BackgroundTask(
      id: 'bt-2',
      ownerConversationId: 'c-owner',
      taskConversationId: 'c-task',
      prompt: 'p',
      loopMinutes: 15,
      maxRuns: 1,
      runCount: 0,
      state: BackgroundTaskState.finished,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1770000000789),
    );
    final back = BackgroundTask.fromMap(t.toJson());
    expect(back.lastRunAt, isNull);
    expect(back.resultMessageId, isNull);
    expect(back.ownerMessageId, isNull);
    expect(back.state, BackgroundTaskState.finished);
  });

  test('state enum keeps its documented order (paused appended last)', () {
    expect(
      BackgroundTaskState.values.map((s) => s.name),
      ['running', 'finished', 'cancelled', 'failed', 'paused'],
    );
  });

  test('BackgroundTask.fromMap parses the paused state; unknown strings '
      'degrade to failed (T1 review ruling)', () {
    final base = BackgroundTask(
      id: 'bt-4',
      ownerConversationId: 'c-owner',
      taskConversationId: 'c-task',
      prompt: 'p',
      loopMinutes: 15,
      maxRuns: 10,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1770000000000),
    ).toJson();

    expect(
      BackgroundTask.fromMap({...base, 'state': 'paused'}).state,
      BackgroundTaskState.paused,
    );
    expect(
      BackgroundTask.fromMap({...base, 'state': 'corrupted-row'}).state,
      BackgroundTaskState.failed,
      reason: 'unknown stored names must never re-arm the engine as running',
    );
  });

  test('BackgroundTaskEntity fromDomain/toDomain round-trip all fields', () {
    final t = BackgroundTask(
      id: 'bt-3',
      ownerConversationId: 'c-owner',
      taskConversationId: 'c-task',
      prompt: 'looping prompt',
      loopMinutes: 60,
      maxRuns: 10,
      runCount: 3,
      state: BackgroundTaskState.failed,
      lastRunAt: DateTime.fromMillisecondsSinceEpoch(1770000000999),
      createdAt: DateTime.fromMillisecondsSinceEpoch(1769999000111),
      resultMessageId: 'm-r',
      ownerMessageId: 'm-o',
    );
    final entity = BackgroundTaskEntity.fromDomain(t);
    expect(entity.internalId, 0);
    final back = entity.toDomain();
    expect(back.id, t.id);
    expect(back.ownerConversationId, t.ownerConversationId);
    expect(back.taskConversationId, t.taskConversationId);
    expect(back.prompt, t.prompt);
    expect(back.loopMinutes, t.loopMinutes);
    expect(back.maxRuns, t.maxRuns);
    expect(back.runCount, t.runCount);
    expect(back.state, t.state);
    expect(
      back.lastRunAt!.millisecondsSinceEpoch,
      t.lastRunAt!.millisecondsSinceEpoch,
    );
    expect(
      back.createdAt.millisecondsSinceEpoch,
      t.createdAt.millisecondsSinceEpoch,
    );
    expect(back.resultMessageId, t.resultMessageId);
    expect(back.ownerMessageId, t.ownerMessageId);
  });
}
