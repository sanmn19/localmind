import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/cloud_sync/data/models/cloud_sync_models.dart';
import 'package:localmind/features/cloud_sync/providers/cloud_sync_providers.dart';

Map<String, dynamic> _payload({List<String> messageIds = const []}) => {
  'version': 1,
  'type': 'cloudSync',
  'settings': <String, dynamic>{},
  'conversations': <dynamic>[],
  'messages': [
    for (final id in messageIds) {'id': id, 'conversationId': 'c1'},
  ],
  'personas': <dynamic>[],
  'savedMessages': <dynamic>[],
  'savedMessageFolders': <dynamic>[],
  'conversationFolders': <dynamic>[],
};

Map<String, dynamic> _snapshotJson(Object? tombstones) => {
  'schema': 1,
  'deviceId': 'device-0001',
  'revision': 1,
  'updatedAt': '2026-01-01T00:00:00.000Z',
  'payload': _payload(),
  'tombstones': tombstones,
};

String _isoDaysAgo(int days) =>
    DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String();

void main() {
  test('reads legacy tombstone lists as deletions at the epoch', () {
    final snapshot = CloudSyncSnapshot.fromJson(
      _snapshotJson({
        'messages': ['m1'],
      }),
    );

    expect(snapshot.tombstones, {
      'messages': {'m1': '1970-01-01T00:00:00.000Z'},
    });
  });

  test('reads timestamped tombstones as a map', () {
    final snapshot = CloudSyncSnapshot.fromJson(
      _snapshotJson({
        'messages': {'m1': '2026-01-02T00:00:00.000Z'},
      }),
    );

    expect(snapshot.tombstones, {
      'messages': {'m1': '2026-01-02T00:00:00.000Z'},
    });
  });

  test('writes timestamped tombstones back as a map', () {
    final snapshot = CloudSyncSnapshot(
      deviceId: 'device-0001',
      revision: 1,
      updatedAt: DateTime.utc(2026, 1, 1),
      payload: const {},
      tombstones: const {
        'messages': {'m1': '2026-01-02T00:00:00.000Z'},
      },
    );

    expect(snapshot.toJson()['tombstones'], {
      'messages': {'m1': '2026-01-02T00:00:00.000Z'},
    });
  });

  test('rejects malformed tombstones', () {
    for (final malformed in [
      {'messages': 'm1'},
      {
        'messages': [1],
      },
      {
        'messages': {'m1': 5},
      },
      {
        'messages': {'m1': 'not-a-date'},
      },
      {
        'unknownCollection': ['m1'],
      },
      <Object>[],
      'm1',
      5,
    ]) {
      expect(
        () => CloudSyncSnapshot.fromJson(_snapshotJson(malformed)),
        throwsFormatException,
      );
    }
  });

  test('builds timestamps for newly deleted ids', () {
    final tombstones = CloudSyncController.debugBuildTombstones(
      _payload(messageIds: ['m1']),
      {
        'ids': {
          'messages': ['m1', 'm2'],
        },
      },
    );

    expect(tombstones['messages']?.keys, ['m2']);
    final deletedAt = DateTime.parse(tombstones['messages']!['m2']!);
    expect(
      DateTime.now().toUtc().difference(deletedAt).inSeconds.abs(),
      lessThan(5),
    );
  });

  test('preserves timestamps of existing tombstones', () {
    final deletedAt = _isoDaysAgo(1);
    final tombstones = CloudSyncController.debugBuildTombstones(
      _payload(messageIds: ['m1']),
      {
        'ids': {
          'messages': ['m1', 'm2'],
        },
        'tombstones': {
          'messages': {'m2': deletedAt},
        },
      },
    );

    expect(tombstones['messages']?['m2'], deletedAt);
  });

  test('prunes tombstones older than thirty days', () {
    final old = _isoDaysAgo(31);
    final recent = _isoDaysAgo(29);
    final tombstones = CloudSyncController.debugBuildTombstones(_payload(), {
      'ids': {'messages': <String>[]},
      'tombstones': {
        'messages': {'old': old, 'recent': recent},
      },
    });

    expect(tombstones['messages'], {'recent': recent});
  });

  test('converts legacy journal lists to epoch tombstones', () {
    final tombstones = CloudSyncController.debugBuildTombstones(_payload(), {
      'ids': {'messages': <String>[]},
      'tombstones': {
        'messages': ['m1'],
      },
    });

    expect(tombstones['messages'], {'m1': '1970-01-01T00:00:00.000Z'});
  });

  test('drops unparseable journal timestamps', () {
    final recent = _isoDaysAgo(1);
    final tombstones = CloudSyncController.debugBuildTombstones(_payload(), {
      'ids': {'messages': <String>[]},
      'tombstones': {
        'messages': {'corrupt': 'not-a-date', 'recent': recent},
      },
    });

    expect(tombstones['messages'], {'recent': recent});
  });
}
