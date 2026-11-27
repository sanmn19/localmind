import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/services/data_backup_service.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/objectbox.g.dart';

// Regression: a cloud sync exports its snapshot, the user sends a message
// while the upload/merge is in flight, and the snapshot is applied afterwards.
// Applying by "absent from the payload = deleted" used to erase that new chat.
// Only explicit tombstones may delete now.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cloud apply keeps local chats the snapshot never saw', () async {
    _mockDocumentsDirectory();
    final now = DateTime.utc(2026, 11, 27, 12);
    final longAgo = now.subtract(const Duration(hours: 2));

    final keep = ConversationEntity.fromDomain(
      Conversation(
        id: 'keep',
        title: 'Created during the sync',
        createdAt: now,
        updatedAt: now,
      ),
    )..internalId = 1;
    final remove = ConversationEntity.fromDomain(
      Conversation(
        id: 'remove',
        title: 'Deleted on another device',
        createdAt: longAgo,
        updatedAt: longAgo,
      ),
    )..internalId = 2;

    final conversations = _FakeBox<ConversationEntity>([
      keep,
      remove,
    ], (item) => item.id);
    final store = _FakeStore({
      ConversationEntity: conversations,
      MessageEntity: _FakeBox<MessageEntity>([], (item) => item.id),
      ForkAnchorEntity: _FakeBox<ForkAnchorEntity>([], (item) => item.id),
    });

    final payload = <String, dynamic>{
      'version': 1,
      'type': 'cloudSync',
      'settings': <String, dynamic>{},
      'conversations': [
        {
          'id': 'remote',
          'title': 'Existing on the server',
          'createdAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
        },
      ],
      'messages': <dynamic>[],
      'personas': <dynamic>[],
      'savedMessages': <dynamic>[],
      'savedMessageFolders': <dynamic>[],
      'conversationFolders': <dynamic>[],
    };

    await DataBackupService().importCloudSync(
      store,
      payload,
      tombstones: {
        'conversations': {'remove': now.toIso8601String()},
      },
    );

    final ids = conversations.rows.map((row) => row.id).toSet();
    expect(ids, contains('keep'), reason: 'newer local chat must survive');
    expect(ids, contains('remote'), reason: 'snapshot rows are upserted');
    expect(
      ids,
      isNot(contains('remove')),
      reason: 'explicit tombstone still deletes',
    );
  });
}

void _mockDocumentsDirectory() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'getApplicationDocumentsDirectory') {
      return Directory.systemTemp.path;
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

class _FakeStore extends Fake implements Store {
  _FakeStore(this._boxes);

  final Map<Type, Object> _boxes;

  @override
  Box<T> box<T>() {
    final existing = _boxes[T];
    if (existing != null) return existing as Box<T>;
    final created = _FakeBox<T>(<T>[], (item) => item.toString());
    _boxes[T] = created;
    return created;
  }

  @override
  Future<R> runInTransactionAsync<R, T>(
    TxMode mode,
    R Function(Store, T) fn,
    T arg,
  ) async => fn(this, arg);
}

class _FakeBox<T> extends Fake implements Box<T> {
  _FakeBox([List<T>? items, String Function(T)? idOf]) : _idOf = idOf {
    for (final item in items ?? <T>[]) {
      if (item is ConversationEntity && item.internalId == 0) {
        item.internalId = _nextId++;
      } else if (item is ForkAnchorEntity && item.internalId == 0) {
        item.internalId = _nextId++;
      }
      _rows[_idOf!(item)] = item;
    }
  }

  final String Function(T)? _idOf;
  final Map<String, T> _rows = {};
  int _nextId = 1;

  List<T> get rows => _rows.values.toList();

  @override
  List<T> getAll() => _rows.values.toList();

  @override
  QueryBuilder<T> query([Condition<T>? qc]) => _FakeQueryBuilder<T>(this);

  @override
  int put(T object, {PutMode mode = PutMode.put}) {
    if (object is ConversationEntity && object.internalId == 0) {
      object.internalId = _nextId++;
    }
    if (object is ForkAnchorEntity && object.internalId == 0) {
      object.internalId = _nextId++;
    }
    _rows[_idOf!(object)] = object;
    return 1;
  }

  @override
  int removeMany(List<int> ids) {
    final before = _rows.length;
    _rows.removeWhere((_, item) {
      final internalId = switch (item) {
        ConversationEntity() => item.internalId,
        ForkAnchorEntity() => item.internalId,
        MessageEntity() => item.internalId,
        _ => 0,
      };
      return ids.contains(internalId);
    });
    return before - _rows.length;
  }
}

class _FakeQueryBuilder<T> extends Fake implements QueryBuilder<T> {
  _FakeQueryBuilder(this._box);

  final _FakeBox<T> _box;

  @override
  Query<T> build() => _FakeQuery<T>(_box);
}

class _FakeQuery<T> extends Fake implements Query<T> {
  _FakeQuery(this._box);

  final _FakeBox<T> _box;

  @override
  T? findFirst() => _box.rows.isEmpty ? null : _box.rows.first;

  @override
  List<T> find() => _box.rows;

  @override
  void close() {}
}
