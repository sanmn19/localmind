import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../data/models/cloud_sync_models.dart';

class CloudSyncMergeResult {
  const CloudSyncMergeResult(this.snapshot, this.conflictCount);

  final CloudSyncSnapshot snapshot;
  final int conflictCount;
}

class CloudSyncMergeService {
  static const _recordCollections = [
    'personas',
    'savedMessages',
    'savedMessageFolders',
    'conversationFolders',
  ];

  static const _settledStatuses = {'complete', 'error'};

  static const _timestampFields = <String, List<String>>{
    'messages': ['updatedAt', 'createdAt'],
    'conversations': ['updatedAt', 'createdAt'],
    'personas': ['updatedAt', 'savedAt', 'createdAt'],
    'savedMessages': ['updatedAt', 'savedAt', 'createdAt'],
    'savedMessageFolders': ['updatedAt', 'savedAt', 'createdAt'],
    'conversationFolders': ['updatedAt', 'savedAt', 'createdAt'],
  };

  static final _legacyTombstoneTime = DateTime.utc(1970);

  Future<String> fingerprint(Map<String, dynamic> payload) async {
    final canonical = _canonicalize(payload);
    final hash = await Sha256().hash(utf8.encode(jsonEncode(canonical)));
    return base64UrlEncode(hash.bytes).replaceAll('=', '');
  }

  Future<String> snapshotFingerprint(CloudSyncSnapshot snapshot) => _hashValue({
    'payload': snapshot.payload,
    'tombstones': snapshot.tombstones,
  });

  Future<Map<String, dynamic>> recordHashes(
    Map<String, dynamic> payload,
  ) async {
    final result = <String, dynamic>{};
    for (final collection in _recordCollections) {
      final hashes = <String, String>{};
      for (final item in _list(payload[collection])) {
        final id = item['id'] as String?;
        if (id != null) hashes[id] = await _hashValue(item);
      }
      result[collection] = hashes;
    }
    final messages = <String, String>{};
    for (final item in _list(payload['messages'])) {
      final id = item['id'] as String?;
      if (id != null) messages[id] = await _hashValue(item);
    }
    result['messages'] = messages;
    final threads = _groupByConversation(payload['messages']);
    final conversationHashes = <String, String>{};
    for (final item in _list(payload['conversations'])) {
      final id = item['id'] as String?;
      if (id != null) {
        conversationHashes[id] = await _hashValue({
          'conversation': item,
          'messages': threads[id] ?? const [],
        });
      }
    }
    result['conversations'] = conversationHashes;
    return result;
  }

  Future<String> _hashValue(Map<String, dynamic> value) async {
    final hash = await Sha256().hash(
      utf8.encode(jsonEncode(_canonicalize(value))),
    );
    return base64UrlEncode(hash.bytes).replaceAll('=', '');
  }

  String? _baseHash(
    Map<String, dynamic> journal,
    String collection,
    String id,
  ) {
    final all = journal['recordHashes'];
    if (all is! Map || all[collection] is! Map) return null;
    return (all[collection] as Map)[id] as String?;
  }

  Map<String, dynamic> _canonicalize(Map<String, dynamic> payload) {
    dynamic normalize(dynamic value) {
      if (value is Map) {
        final keys = value.keys.map((e) => e.toString()).toList()..sort();
        return {for (final key in keys) key: normalize(value[key])};
      }
      if (value is List) {
        final normalized = value.map(normalize).toList();
        if (normalized.every((item) => item is Map && item['id'] is String)) {
          normalized.sort(
            (a, b) => (a['id'] as String).compareTo(b['id'] as String),
          );
        }
        return normalized;
      }
      return value;
    }

    return Map<String, dynamic>.from(normalize(payload) as Map);
  }

  Future<CloudSyncMergeResult> merge({
    required CloudSyncSnapshot local,
    required CloudSyncSnapshot? remote,
    required Map<String, dynamic> journal,
  }) async {
    if (remote == null) return CloudSyncMergeResult(local, 0);

    final localHash = await fingerprint(local.payload);
    final lastHash = journal['payloadHash'] as String?;
    final lastRemoteRevision = journal['remoteRevision'] as int?;
    final localChanged = lastHash == null || localHash != lastHash;
    final remoteChanged =
        lastRemoteRevision == null ||
        remote.revision != lastRemoteRevision ||
        remote.deviceId != journal['remoteDeviceId'];

    if (!localChanged) return CloudSyncMergeResult(remote, 0);
    if (!remoteChanged) return CloudSyncMergeResult(local, 0);

    final payload = Map<String, dynamic>.from(remote.payload);
    var conflicts = 0;

    // Settings are a single record: last write wins by snapshot time, with the
    // larger device id breaking ties. A first link keeps the remote settings.
    payload['settings'] = lastHash == null
        ? remote.payload['settings']
        : _resolveSettings(local, remote);

    final localMessages = _mapById(local.payload['messages']);
    final remoteMessages = _mapById(remote.payload['messages']);
    final mergedMessages = <String, Map<String, dynamic>>{};
    for (final id in {...localMessages.keys, ...remoteMessages.keys}) {
      final localMessage = localMessages[id];
      final remoteMessage = remoteMessages[id];
      if (localMessage == null) {
        mergedMessages[id] = remoteMessage!;
        continue;
      }
      if (remoteMessage == null) {
        mergedMessages[id] = localMessage;
        continue;
      }
      if (_same(localMessage, remoteMessage)) {
        mergedMessages[id] = localMessage;
        continue;
      }
      if (await _bothChanged(
        journal,
        'messages',
        id,
        localMessage,
        remoteMessage,
      )) {
        conflicts++;
      }
      mergedMessages[id] = _resolveMessage(localMessage, remoteMessage);
    }

    final localThreads = _groupByConversation(local.payload['messages']);
    final remoteThreads = _groupByConversation(remote.payload['messages']);
    final localConversations = _mapById(local.payload['conversations']);
    final remoteConversations = _mapById(remote.payload['conversations']);
    final mergedConversations = <String, Map<String, dynamic>>{};
    for (final id in {
      ...localConversations.keys,
      ...remoteConversations.keys,
    }) {
      final localConversation = localConversations[id];
      final remoteConversation = remoteConversations[id];
      if (localConversation == null) {
        mergedConversations[id] = Map<String, dynamic>.from(
          remoteConversation!,
        );
        continue;
      }
      if (remoteConversation == null) {
        mergedConversations[id] = Map<String, dynamic>.from(localConversation);
        continue;
      }
      final metadataDiffers = !_sameConversation(
        localConversation,
        remoteConversation,
      );
      if (metadataDiffers) {
        if (await _conversationChanged(
              journal,
              id,
              localConversation,
              localThreads[id] ?? const [],
            ) &&
            await _conversationChanged(
              journal,
              id,
              remoteConversation,
              remoteThreads[id] ?? const [],
            )) {
          conflicts++;
        }
      }
      final winner = _resolveRecord(
        localConversation,
        remoteConversation,
        'conversations',
        local.deviceId,
        remote.deviceId,
      );
      final merged = Map<String, dynamic>.from(winner);
      final createdAt = _earlierTime(
        localConversation['createdAt'],
        remoteConversation['createdAt'],
      );
      if (createdAt != null) merged['createdAt'] = createdAt;
      mergedConversations[id] = merged;
    }

    payload['messages'] = mergedMessages.values.toList()
      ..sort(_compareMessages);
    payload['conversations'] = _sortedById(mergedConversations);

    for (final collection in _recordCollections) {
      final localRecords = _mapById(local.payload[collection]);
      final remoteRecords = _mapById(remote.payload[collection]);
      final mergedRecords = <String, Map<String, dynamic>>{};
      for (final id in {...localRecords.keys, ...remoteRecords.keys}) {
        final localRecord = localRecords[id];
        final remoteRecord = remoteRecords[id];
        if (localRecord == null) {
          mergedRecords[id] = remoteRecord!;
          continue;
        }
        if (remoteRecord == null) {
          mergedRecords[id] = localRecord;
          continue;
        }
        if (_same(localRecord, remoteRecord)) {
          mergedRecords[id] = localRecord;
          continue;
        }
        if (await _bothChanged(
          journal,
          collection,
          id,
          localRecord,
          remoteRecord,
        )) {
          conflicts++;
        }
        mergedRecords[id] = _resolveRecord(
          localRecord,
          remoteRecord,
          collection,
          local.deviceId,
          remote.deviceId,
        );
      }
      payload[collection] = _sortedById(mergedRecords);
    }

    final tombstones = _mergeTombstones(local.tombstones, remote.tombstones);
    _applyTombstones(payload, tombstones);
    _recomputeConversationStats(payload);

    return CloudSyncMergeResult(
      CloudSyncSnapshot(
        deviceId: local.deviceId,
        revision:
            (local.revision > remote.revision
                ? local.revision
                : remote.revision) +
            1,
        updatedAt: DateTime.now().toUtc(),
        payload: payload,
        tombstones: tombstones,
      ),
      conflicts,
    );
  }

  Map<String, dynamic> _resolveSettings(
    CloudSyncSnapshot local,
    CloudSyncSnapshot remote,
  ) {
    final localSettings = Map<String, dynamic>.from(
      local.payload['settings'] as Map,
    );
    final remoteSettings = Map<String, dynamic>.from(
      remote.payload['settings'] as Map,
    );
    if (local.updatedAt.isAfter(remote.updatedAt)) return localSettings;
    if (remote.updatedAt.isAfter(local.updatedAt)) return remoteSettings;
    final byDevice = local.deviceId.compareTo(remote.deviceId);
    if (byDevice != 0) return byDevice > 0 ? localSettings : remoteSettings;
    return _canonicalJson(
              localSettings,
            ).compareTo(_canonicalJson(remoteSettings)) >=
            0
        ? localSettings
        : remoteSettings;
  }

  Map<String, dynamic> _resolveMessage(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) {
    final localSettled = _isSettled(local);
    final remoteSettled = _isSettled(remote);
    if (localSettled != remoteSettled) {
      return localSettled ? local : remote;
    }
    final localTime = _recordTime(local, 'messages');
    final remoteTime = _recordTime(remote, 'messages');
    if (localTime != null && remoteTime != null && localTime != remoteTime) {
      return localTime.isAfter(remoteTime) ? local : remote;
    }
    if (localTime != null && remoteTime == null) return local;
    if (remoteTime != null && localTime == null) return remote;
    final localContent = '${local['content'] ?? ''}';
    final remoteContent = '${remote['content'] ?? ''}';
    if (localContent.length != remoteContent.length) {
      return localContent.length > remoteContent.length ? local : remote;
    }
    final byContent = localContent.compareTo(remoteContent);
    if (byContent != 0) return byContent > 0 ? local : remote;
    final byId = '${local['id']}'.compareTo('${remote['id']}');
    if (byId != 0) return byId > 0 ? local : remote;
    return _canonicalJson(local).compareTo(_canonicalJson(remote)) >= 0
        ? local
        : remote;
  }

  Map<String, dynamic> _resolveRecord(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
    String collection,
    String localDeviceId,
    String remoteDeviceId,
  ) {
    final localTime = _recordTime(local, collection);
    final remoteTime = _recordTime(remote, collection);
    if (localTime != null && remoteTime != null && localTime != remoteTime) {
      return localTime.isAfter(remoteTime) ? local : remote;
    }
    if (localTime != null && remoteTime == null) return local;
    if (remoteTime != null && localTime == null) return remote;
    final byDevice = localDeviceId.compareTo(remoteDeviceId);
    if (byDevice != 0) return byDevice > 0 ? local : remote;
    return _canonicalJson(local).compareTo(_canonicalJson(remote)) >= 0
        ? local
        : remote;
  }

  bool _sameConversation(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) {
    Map<String, dynamic> metadata(Map<String, dynamic> conversation) =>
        Map<String, dynamic>.from(conversation)
          ..remove('updatedAt')
          ..remove('messageCount')
          ..remove('lastMessagePreview');
    return _same(metadata(local), metadata(remote));
  }

  bool _isSettled(Map<String, dynamic> message) {
    final status = message['status'];
    return status == null || _settledStatuses.contains(status);
  }

  DateTime? _recordTime(Map<String, dynamic> record, String collection) {
    final fields = _timestampFields[collection] ?? const ['updatedAt'];
    for (final field in fields) {
      final value = record[field];
      if (value is! String) continue;
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed.toUtc();
    }
    return null;
  }

  Future<bool> _bothChanged(
    Map<String, dynamic> journal,
    String collection,
    String id,
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) async {
    final base = _baseHash(journal, collection, id);
    if (base == null) return true;
    return await _hashValue(local) != base && await _hashValue(remote) != base;
  }

  Future<bool> _conversationChanged(
    Map<String, dynamic> journal,
    String id,
    Map<String, dynamic> conversation,
    List<Map<String, dynamic>> messages,
  ) async {
    final base = _baseHash(journal, 'conversations', id);
    if (base == null) return true;
    final hash = await _hashValue({
      'conversation': conversation,
      'messages': messages,
    });
    return hash != base;
  }

  Map<String, Map<String, String>> _mergeTombstones(
    Map<String, Map<String, String>> local,
    Map<String, Map<String, String>> remote,
  ) {
    final merged = <String, Map<String, String>>{};
    for (final source in [local, remote]) {
      for (final entry in source.entries) {
        final values = merged[entry.key] ?? <String, String>{};
        for (final tombstone in entry.value.entries) {
          final existing = values[tombstone.key];
          if (existing == null || _isLater(tombstone.value, existing)) {
            values[tombstone.key] = tombstone.value;
          }
        }
        merged[entry.key] = {
          for (final key in values.keys.toList()..sort()) key: values[key]!,
        };
      }
    }
    return {for (final key in merged.keys.toList()..sort()) key: merged[key]!};
  }

  bool _isLater(String candidate, String existing) {
    final candidateTime = DateTime.tryParse(candidate);
    final existingTime = DateTime.tryParse(existing);
    if (candidateTime == null) return false;
    if (existingTime == null) return true;
    if (candidateTime.isAfter(existingTime)) return true;
    if (existingTime.isAfter(candidateTime)) return false;
    return candidate.compareTo(existing) > 0;
  }

  List<Map<String, dynamic>> _list(dynamic value) => value is List
      ? value.whereType<Map>().map(Map<String, dynamic>.from).toList()
      : <Map<String, dynamic>>[];

  Map<String, Map<String, dynamic>> _mapById(dynamic value) => {
    for (final item in _list(value))
      if (item['id'] is String) item['id'] as String: item,
  };

  Map<String, List<Map<String, dynamic>>> _groupByConversation(dynamic value) {
    final result = <String, List<Map<String, dynamic>>>{};
    for (final item in _list(value)) {
      final id = item['conversationId'] as String?;
      if (id != null) (result[id] ??= []).add(item);
    }
    for (final items in result.values) {
      items.sort(_compareMessages);
    }
    return result;
  }

  List<Map<String, dynamic>> _sortedById(
    Map<String, Map<String, dynamic>> records,
  ) =>
      records.values.toList()
        ..sort((a, b) => '${a['id']}'.compareTo('${b['id']}'));

  int _compareMessages(Map<String, dynamic> a, Map<String, dynamic> b) {
    final byCreated = _parseTime(
      a['createdAt'],
    ).compareTo(_parseTime(b['createdAt']));
    if (byCreated != 0) return byCreated;
    final byThread = _intValue(
      a['threadOrder'],
    ).compareTo(_intValue(b['threadOrder']));
    if (byThread != 0) return byThread;
    return '${a['id']}'.compareTo('${b['id']}');
  }

  DateTime _parseTime(dynamic value) =>
      (value is String ? DateTime.tryParse(value) : null) ??
      _legacyTombstoneTime;

  int _intValue(dynamic value) => value is num ? value.toInt() : -1;

  String? _earlierTime(dynamic a, dynamic b) {
    if (a is! String) return b is String ? b : null;
    if (b is! String) return a;
    final aTime = DateTime.tryParse(a);
    final bTime = DateTime.tryParse(b);
    if (aTime == null) return b;
    if (bTime == null) return a;
    if (aTime.isBefore(bTime)) return a;
    if (bTime.isBefore(aTime)) return b;
    return a.compareTo(b) <= 0 ? a : b;
  }

  String? _preview(dynamic content) {
    if (content is! String) return null;
    return content.length > 100 ? '${content.substring(0, 100)}...' : content;
  }

  void _applyTombstones(
    Map<String, dynamic> payload,
    Map<String, Map<String, String>> tombstones,
  ) {
    for (final entry in tombstones.entries) {
      final records = payload[entry.key];
      if (records is! List) continue;
      final deletions = entry.value;
      payload[entry.key] = records.where((raw) {
        if (raw is! Map) return true;
        final id = raw['id'];
        if (id is! String) return true;
        final deletedAt = DateTime.tryParse(deletions[id] ?? '');
        if (deletedAt == null) return true;
        final deletedUtc = deletedAt.toUtc();
        // Legacy list tombstones carry no time and always delete.
        if (!deletedUtc.isAfter(_legacyTombstoneTime)) return false;
        final recordTime = _recordTime(
          Map<String, dynamic>.from(raw),
          entry.key,
        );
        return recordTime != null && recordTime.isAfter(deletedUtc);
      }).toList();
    }

    final conversationIds = _mapById(payload['conversations']).keys.toSet();
    final messages = payload['messages'];
    if (messages is List) {
      payload['messages'] = messages
          .where(
            (raw) =>
                raw is! Map || conversationIds.contains(raw['conversationId']),
          )
          .toList();
    }
  }

  void _recomputeConversationStats(Map<String, dynamic> payload) {
    final threads = _groupByConversation(payload['messages']);
    final conversations = payload['conversations'];
    if (conversations is! List) return;
    for (final raw in conversations) {
      if (raw is! Map) continue;
      final id = raw['id'];
      if (id is! String) continue;
      final active = _activeTimeline(
        threads[id] ?? const <Map<String, dynamic>>[],
      );
      raw['messageCount'] = active.length;
      raw['lastMessagePreview'] = active.isEmpty
          ? null
          : _preview(active.last['content']);
    }
  }

  /// Mirrors `MessageVariants._legacyFlatResolve` for flat sync payloads: one
  /// active message per variant group, ordered by the conversation timeline.
  List<Map<String, dynamic>> _activeTimeline(
    List<Map<String, dynamic>> messages,
  ) {
    final byGroup = <String, List<Map<String, dynamic>>>{};
    for (final message in messages) {
      final variantGroup = message['variantGroupId'];
      final id = message['id'];
      final groupId = variantGroup is String && variantGroup.isNotEmpty
          ? variantGroup
          : id is String
          ? id
          : null;
      if (groupId != null) (byGroup[groupId] ??= []).add(message);
    }
    final active = <Map<String, dynamic>>[];
    for (final group in byGroup.values) {
      group.sort((a, b) {
        final byIndex = _intValue(
          a['variantIndex'],
        ).compareTo(_intValue(b['variantIndex']));
        if (byIndex != 0) return byIndex;
        return _compareMessages(a, b);
      });
      active.add(
        group.firstWhere(
          (message) => message['isActiveVariant'] == true,
          orElse: () => group.last,
        ),
      );
    }
    active.sort(_compareMessages);
    return active;
  }

  bool _same(Map<String, dynamic> a, Map<String, dynamic> b) =>
      _canonicalJson(a) == _canonicalJson(b);

  String _canonicalJson(Map<String, dynamic> value) =>
      jsonEncode(_canonicalize(value));
}
