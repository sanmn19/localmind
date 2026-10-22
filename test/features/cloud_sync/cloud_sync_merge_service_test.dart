import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/cloud_sync/data/models/cloud_sync_models.dart';
import 'package:localmind/features/cloud_sync/services/cloud_sync_merge_service.dart';

void main() {
  final service = CloudSyncMergeService();

  CloudSyncSnapshot snapshot(
    String device,
    int revision,
    Map<String, dynamic> payload,
  ) => CloudSyncSnapshot(
    deviceId: device,
    revision: revision,
    updatedAt: DateTime.utc(2026, 7, 10, revision),
    payload: {
      'settings': <String, dynamic>{},
      'personas': <dynamic>[],
      'conversations': <dynamic>[],
      'messages': <dynamic>[],
      'savedMessages': <dynamic>[],
      'savedMessageFolders': <dynamic>[],
      'conversationFolders': <dynamic>[],
      ...payload,
    },
  );

  Map<String, dynamic> conversation(
    String id,
    String title,
    int minute, {
    int? updatedAt,
  }) => {
    'id': id,
    'title': title,
    'createdAt': DateTime.utc(2026, 1, 1, 0, minute).toIso8601String(),
    'updatedAt': DateTime.utc(
      2026,
      1,
      1,
      0,
      updatedAt ?? minute,
    ).toIso8601String(),
  };

  Map<String, dynamic> message(
    String id,
    String conversationId,
    int minute, {
    String content = 'text',
    String status = 'complete',
    String role = 'assistant',
    int? updatedAt,
  }) => {
    'id': id,
    'conversationId': conversationId,
    'role': role,
    'content': content,
    'createdAt': DateTime.utc(2026, 1, 1, 0, minute).toIso8601String(),
    'updatedAt': DateTime.utc(
      2026,
      1,
      1,
      0,
      updatedAt ?? minute,
    ).toIso8601String(),
    'status': status,
  };

  CloudSyncSnapshot withTombstones(
    CloudSyncSnapshot snapshot,
    Map<String, Map<String, String>> tombstones,
  ) => CloudSyncSnapshot(
    deviceId: snapshot.deviceId,
    revision: snapshot.revision,
    updatedAt: snapshot.updatedAt,
    payload: snapshot.payload,
    tombstones: tombstones,
  );

  test('unions independent records', () async {
    final remote = snapshot('remote-device', 1, {
      'personas': [
        {'id': 'remote', 'name': 'Remote'},
      ],
    });
    final local = snapshot('local-device', 2, {
      'personas': [
        {'id': 'local', 'name': 'Local'},
      ],
    });

    final result = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );

    expect(
      (result.snapshot.payload['personas'] as List)
          .map((item) => item['id'])
          .toSet(),
      {'remote', 'local'},
    );
    expect(result.conflictCount, 0);
  });

  test(
    'uses remote settings when linking a device for the first time',
    () async {
      final remote = snapshot('remote-device', 3, {
        'settings': {'fontSize': 22.0},
      });
      final local = snapshot('local-device', 1, {
        'settings': {'fontSize': 16.0},
      });

      final result = await service.merge(
        local: local,
        remote: remote,
        journal: const {},
      );

      expect(result.snapshot.payload['settings'], {'fontSize': 22.0});
    },
  );

  test('keeps the newer settings snapshot', () async {
    final remote = snapshot('remote-device', 1, {
      'settings': {'fontSize': 22.0},
    });
    final local = snapshot('local-device', 2, {
      'settings': {'fontSize': 16.0},
    });
    final journal = {'payloadHash': 'previous'};

    final forward = await service.merge(
      local: local,
      remote: remote,
      journal: journal,
    );
    final backward = await service.merge(
      local: remote,
      remote: local,
      journal: journal,
    );

    expect(forward.snapshot.payload['settings'], {'fontSize': 16.0});
    expect(backward.snapshot.payload['settings'], {'fontSize': 16.0});
  });

  test('resolves settings ties by the larger device id', () async {
    final remote = snapshot('remote-device', 1, {
      'settings': {'fontSize': 22.0},
    });
    final local = snapshot('local-device', 1, {
      'settings': {'fontSize': 16.0},
    });
    final journal = {'payloadHash': 'previous'};

    final forward = await service.merge(
      local: local,
      remote: remote,
      journal: journal,
    );
    final backward = await service.merge(
      local: remote,
      remote: local,
      journal: journal,
    );

    expect(forward.snapshot.payload['settings'], {'fontSize': 22.0});
    expect(backward.snapshot.payload['settings'], {'fontSize': 22.0});
  });

  test(
    'unions messages appended on two devices in chronological order',
    () async {
      final remote = snapshot('remote-device', 1, {
        'conversations': [conversation('c1', 'Chat', 1)],
        'messages': [message('m1', 'c1', 1), message('m2', 'c1', 2)],
      });
      final local = snapshot('local-device', 2, {
        'conversations': [conversation('c1', 'Chat', 1)],
        'messages': [message('m1', 'c1', 1), message('m3', 'c1', 3)],
      });

      final forward = await service.merge(
        local: local,
        remote: remote,
        journal: const {},
      );
      final backward = await service.merge(
        local: remote,
        remote: local,
        journal: const {},
      );

      expect(
        (forward.snapshot.payload['messages'] as List).map((m) => m['id']),
        ['m1', 'm2', 'm3'],
      );
      expect(forward.conflictCount, 0);
      expect(
        (forward.snapshot.payload['conversations'] as List).single['title'],
        'Chat',
      );
      expect(
        await service.fingerprint(forward.snapshot.payload),
        await service.fingerprint(backward.snapshot.payload),
      );
    },
  );

  test('keeps the completed reply over a streaming checkpoint', () async {
    final remote = snapshot('remote-device', 1, {
      'conversations': [conversation('c1', 'Chat', 1)],
      'messages': [message('m1', 'c1', 1, content: 'Hello', updatedAt: 4)],
    });
    final local = snapshot('local-device', 2, {
      'conversations': [conversation('c1', 'Chat', 1)],
      'messages': [
        message(
          'm1',
          'c1',
          1,
          content: 'Hel',
          status: 'streaming',
          updatedAt: 5,
        ),
      ],
    });

    final forward = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );
    final backward = await service.merge(
      local: remote,
      remote: local,
      journal: const {},
    );

    for (final result in [forward, backward]) {
      final merged = (result.snapshot.payload['messages'] as List).single;
      expect(merged['content'], 'Hello');
      expect(merged['status'], 'complete');
    }
  });

  test('prefers the later completed edit of a message', () async {
    final remote = snapshot('remote-device', 1, {
      'conversations': [conversation('c1', 'Chat', 1)],
      'messages': [message('m1', 'c1', 1, content: 'First', updatedAt: 4)],
    });
    final local = snapshot('local-device', 2, {
      'conversations': [conversation('c1', 'Chat', 1)],
      'messages': [message('m1', 'c1', 1, content: 'Second', updatedAt: 5)],
    });

    final forward = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );
    final backward = await service.merge(
      local: remote,
      remote: local,
      journal: const {},
    );

    for (final result in [forward, backward]) {
      expect(
        (result.snapshot.payload['messages'] as List).single['content'],
        'Second',
      );
    }
  });

  test(
    'orders two concurrent request and response pairs by request time',
    () async {
      final remote = snapshot('remote-device', 1, {
        'conversations': [conversation('c1', 'Chat', 1)],
        'messages': [
          message('u1', 'c1', 1, role: 'user', content: 'First question'),
          message('a1', 'c1', 2, content: 'First answer'),
        ],
      });
      final local = snapshot('local-device', 2, {
        'conversations': [conversation('c1', 'Chat', 1)],
        'messages': [
          message('u2', 'c1', 3, role: 'user', content: 'Second question'),
          message('a2', 'c1', 4, content: 'Second answer'),
        ],
      });

      final forward = await service.merge(
        local: local,
        remote: remote,
        journal: const {},
      );
      final backward = await service.merge(
        local: remote,
        remote: local,
        journal: const {},
      );

      expect(
        (forward.snapshot.payload['messages'] as List).map((m) => m['id']),
        ['u1', 'a1', 'u2', 'a2'],
      );
      expect(
        (backward.snapshot.payload['messages'] as List).map((m) => m['id']),
        ['u1', 'a1', 'u2', 'a2'],
      );
      expect(forward.conflictCount, 0);
    },
  );

  test('breaks exact timestamp ties by longer content', () async {
    final remote = snapshot('remote-device', 1, {
      'conversations': [conversation('c1', 'Chat', 1)],
      'messages': [message('m1', 'c1', 1, content: 'short', updatedAt: 3)],
    });
    final local = snapshot('local-device', 2, {
      'conversations': [conversation('c1', 'Chat', 1)],
      'messages': [
        message('m1', 'c1', 1, content: 'a longer reply', updatedAt: 3),
      ],
    });

    final forward = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );
    final backward = await service.merge(
      local: remote,
      remote: local,
      journal: const {},
    );

    for (final result in [forward, backward]) {
      expect(
        (result.snapshot.payload['messages'] as List).single['content'],
        'a longer reply',
      );
    }
  });

  test('keeps the newer conversation title', () async {
    final remote = snapshot('remote-device', 1, {
      'conversations': [conversation('c1', 'Remote title', 1)],
    });
    final local = snapshot('local-device', 2, {
      'conversations': [conversation('c1', 'Local title', 2)],
    });

    final forward = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );
    final backward = await service.merge(
      local: remote,
      remote: local,
      journal: const {},
    );

    expect(
      (forward.snapshot.payload['conversations'] as List).single['title'],
      'Local title',
    );
    expect(
      (backward.snapshot.payload['conversations'] as List).single['title'],
      'Local title',
    );
  });

  test('recomputes the message count and last message preview', () async {
    final longContent = 'x' * 120;
    final remote = snapshot('remote-device', 1, {
      'conversations': [conversation('c1', 'Chat', 1)],
      'messages': [message('m1', 'c1', 1, content: 'Hello')],
    });
    final local = snapshot('local-device', 2, {
      'conversations': [conversation('c1', 'Chat', 1)],
      'messages': [message('m2', 'c1', 2, content: longContent)],
    });

    final forward = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );
    final backward = await service.merge(
      local: remote,
      remote: local,
      journal: const {},
    );

    for (final result in [forward, backward]) {
      final merged = (result.snapshot.payload['conversations'] as List).single;
      expect(merged['messageCount'], 2);
      expect(
        merged['lastMessagePreview'],
        '${longContent.substring(0, 100)}...',
      );
    }
  });

  test('drops orphan messages', () async {
    final remote = snapshot('remote-device', 1, {
      'conversations': [conversation('c1', 'Chat', 1)],
      'messages': [message('m1', 'c1', 1)],
    });
    final local = snapshot('local-device', 2, {
      'conversations': [conversation('c1', 'Chat', 1)],
      'messages': [message('orphan', 'c2', 2)],
    });

    final result = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );

    expect((result.snapshot.payload['messages'] as List).map((m) => m['id']), [
      'm1',
    ]);
  });

  test('merges persona edits last-write-wins without copies', () async {
    final remote = snapshot('remote-device', 1, {
      'personas': [
        {
          'id': 'p1',
          'name': 'Remote',
          'createdAt': '2026-01-01T00:01:00.000Z',
          'updatedAt': '2026-01-01T00:02:00.000Z',
        },
      ],
    });
    final local = snapshot('local-device', 2, {
      'personas': [
        {
          'id': 'p1',
          'name': 'Local',
          'createdAt': '2026-01-01T00:01:00.000Z',
          'updatedAt': '2026-01-01T00:03:00.000Z',
        },
      ],
    });

    final forward = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );
    final backward = await service.merge(
      local: remote,
      remote: local,
      journal: const {},
    );

    for (final result in [forward, backward]) {
      final personas = result.snapshot.payload['personas'] as List;
      expect(personas, hasLength(1));
      expect(personas.single['id'], 'p1');
      expect(personas.single['name'], 'Local');
    }
    expect(forward.conflictCount, 1);
  });

  test('keeps a persona edited after its deletion without a copy', () async {
    final remote = snapshot('remote-device', 1, {
      'personas': [
        {
          'id': 'p1',
          'name': 'Edited',
          'createdAt': '2026-01-01T00:01:00.000Z',
          'updatedAt': '2026-01-01T00:06:00.000Z',
        },
      ],
    });
    final local = withTombstones(snapshot('local-device', 2, {}), const {
      'personas': {'p1': '2026-01-01T00:05:00.000Z'},
    });

    final forward = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );
    final backward = await service.merge(
      local: remote,
      remote: local,
      journal: const {},
    );

    for (final result in [forward, backward]) {
      final personas = result.snapshot.payload['personas'] as List;
      expect(personas, hasLength(1));
      expect(personas.single['id'], 'p1');
      expect(personas.single['name'], 'Edited');
    }
  });

  test('deletes a persona not edited after its deletion', () async {
    final remote = snapshot('remote-device', 1, {
      'personas': [
        {
          'id': 'p1',
          'name': 'Stale',
          'createdAt': '2026-01-01T00:01:00.000Z',
          'updatedAt': '2026-01-01T00:04:00.000Z',
        },
      ],
    });
    final local = withTombstones(snapshot('local-device', 2, {}), const {
      'personas': {'p1': '2026-01-01T00:05:00.000Z'},
    });

    final forward = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );
    final backward = await service.merge(
      local: remote,
      remote: local,
      journal: const {},
    );

    for (final result in [forward, backward]) {
      expect(result.snapshot.payload['personas'], isEmpty);
    }
  });

  test('resurrects a message edited after its deletion', () async {
    final local = withTombstones(
      snapshot('local-device', 2, {
        'conversations': [conversation('c1', 'Chat', 1)],
        'messages': [message('m1', 'c1', 1, content: 'edited', updatedAt: 6)],
      }),
      const {
        'messages': {'m1': '2026-01-01T00:05:00.000Z'},
      },
    );
    final remote = snapshot('remote-device', 1, {
      'conversations': [conversation('c1', 'Chat', 1)],
    });

    final forward = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );
    final backward = await service.merge(
      local: remote,
      remote: local,
      journal: const {},
    );

    for (final result in [forward, backward]) {
      expect(
        (result.snapshot.payload['messages'] as List).single['content'],
        'edited',
      );
    }
  });

  test('deletes a message not edited after its deletion', () async {
    final remote = snapshot('remote-device', 1, {
      'conversations': [conversation('c1', 'Chat', 1)],
      'messages': [message('m1', 'c1', 1, content: 'stale', updatedAt: 4)],
    });
    final local = withTombstones(
      snapshot('local-device', 2, {
        'conversations': [conversation('c1', 'Chat', 1)],
      }),
      const {
        'messages': {'m1': '2026-01-01T00:05:00.000Z'},
      },
    );

    final forward = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );
    final backward = await service.merge(
      local: remote,
      remote: local,
      journal: const {},
    );

    expect(forward.snapshot.payload['messages'], isEmpty);
    expect(backward.snapshot.payload['messages'], isEmpty);
  });

  test('deletes a message with a legacy epoch tombstone', () async {
    final remote = snapshot('remote-device', 1, {
      'conversations': [conversation('c1', 'Chat', 1)],
      'messages': [message('m1', 'c1', 1)],
    });
    final local = withTombstones(
      snapshot('local-device', 2, {
        'conversations': [conversation('c1', 'Chat', 1)],
      }),
      const {
        'messages': {'m1': '1970-01-01T00:00:00.000Z'},
      },
    );

    final forward = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );
    final backward = await service.merge(
      local: remote,
      remote: local,
      journal: const {},
    );

    for (final result in [forward, backward]) {
      expect(result.snapshot.payload['messages'], isEmpty);
    }
  });

  test(
    'merges edits to different conversations without false conflicts',
    () async {
      final base = snapshot('base-device', 1, {
        'conversations': [
          conversation('c1', 'One', 1),
          conversation('c2', 'Two', 1),
        ],
        'messages': [
          message('m1', 'c1', 1, content: 'One'),
          message('m2', 'c2', 2, content: 'Two'),
        ],
      });
      final remote = snapshot('remote-device', 2, {
        'conversations': [
          conversation('c1', 'Remote edit', 2),
          conversation('c2', 'Two', 1),
        ],
        'messages': base.payload['messages'],
      });
      final local = snapshot('local-device', 2, {
        'conversations': [
          conversation('c1', 'One', 1),
          conversation('c2', 'Local edit', 2),
        ],
        'messages': base.payload['messages'],
      });
      final journal = {
        'payloadHash': await service.fingerprint(base.payload),
        'remoteRevision': base.revision,
        'remoteDeviceId': base.deviceId,
        'recordHashes': await service.recordHashes(base.payload),
      };

      final result = await service.merge(
        local: local,
        remote: remote,
        journal: journal,
      );

      final conversations = {
        for (final item in result.snapshot.payload['conversations'] as List)
          item['id']: item['title'],
      };
      expect(conversations, {'c1': 'Remote edit', 'c2': 'Local edit'});
      expect(result.conflictCount, 0);
    },
  );

  test('applies tombstones after merging', () async {
    final remote = snapshot('remote-device', 1, {
      'personas': [
        {'id': 'deleted', 'name': 'Delete me'},
      ],
    });
    final local = withTombstones(snapshot('local-device', 2, {}), const {
      'personas': {'deleted': '1970-01-01T00:00:00.000Z'},
    });

    final result = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );
    expect(result.snapshot.payload['personas'], isEmpty);
  });

  test('converges regardless of merge order', () async {
    final remote = snapshot('remote-device', 1, {
      'conversations': [conversation('c1', 'Remote', 1)],
      'messages': [
        message('m1', 'c1', 1),
        message('m2', 'c1', 2, content: 'remote'),
      ],
    });
    final local = snapshot('local-device', 2, {
      'conversations': [conversation('c1', 'Local', 2)],
      'messages': [
        message('m1', 'c1', 1),
        message('m3', 'c1', 3, content: 'local'),
      ],
    });

    final forward = await service.merge(
      local: local,
      remote: remote,
      journal: const {},
    );
    final backward = await service.merge(
      local: remote,
      remote: local,
      journal: const {},
    );

    expect(
      await service.fingerprint(forward.snapshot.payload),
      await service.fingerprint(backward.snapshot.payload),
    );
    expect(forward.snapshot.payload, backward.snapshot.payload);
  });

  test('retains cumulative tombstones on a local-only fast path', () async {
    final remote = CloudSyncSnapshot(
      deviceId: 'remote-device',
      revision: 4,
      updatedAt: DateTime.utc(2026, 7, 10),
      payload: snapshot('remote-device', 4, {
        'settings': {'fontSize': 16.0},
      }).payload,
      tombstones: const {
        'personas': {'deleted-persona': '1970-01-01T00:00:00.000Z'},
      },
    );
    final local = CloudSyncSnapshot(
      deviceId: 'local-device',
      revision: 5,
      updatedAt: DateTime.utc(2026, 7, 10, 1),
      payload: snapshot('local-device', 5, {
        'settings': {'fontSize': 18.0},
      }).payload,
      tombstones: remote.tombstones,
    );
    final journal = {
      'payloadHash': await service.fingerprint(remote.payload),
      'remoteRevision': remote.revision,
      'remoteDeviceId': remote.deviceId,
    };

    final result = await service.merge(
      local: local,
      remote: remote,
      journal: journal,
    );

    expect(result.snapshot.tombstones, remote.tombstones);
    final withoutTombstones = CloudSyncSnapshot(
      deviceId: result.snapshot.deviceId,
      revision: result.snapshot.revision,
      updatedAt: result.snapshot.updatedAt,
      payload: result.snapshot.payload,
    );
    expect(
      await service.snapshotFingerprint(result.snapshot),
      isNot(await service.snapshotFingerprint(withoutTombstones)),
    );
  });
}
