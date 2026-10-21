import '../../../core/storage/entities.dart';
import '../../../objectbox.g.dart';

/// One short-lived screen sample in the on-disk queue.
class ScreenSample {
  const ScreenSample({
    this.id = 0,
    required this.capturedAt,
    required this.packageName,
    required this.text,
    required this.hash,
  });

  /// ObjectBox internal id; 0 until the row is stored.
  final int id;
  final DateTime capturedAt;
  final String packageName;
  final String text;
  final String hash;
}

/// Persistence seam for the screen-sample queue. Unit tests use their own
/// recording store; the app uses [ObjectBoxScreenSampleStore].
abstract class ScreenSampleStore {
  void add(ScreenSample sample);

  List<ScreenSample> pending({int limit = 240});

  void markProcessed(Iterable<int> ids, DateTime now);

  /// Deletes samples captured before [before], then keeps at most [keepMax]
  /// of the newest rows.
  void prune({required DateTime before, int keepMax = 4000});
}

class ObjectBoxScreenSampleStore implements ScreenSampleStore {
  ObjectBoxScreenSampleStore(this._box);

  final Box<ScreenSampleEntity> _box;

  @override
  void add(ScreenSample sample) {
    _box.put(
      ScreenSampleEntity(
        capturedAt: sample.capturedAt,
        packageName: sample.packageName,
        text: sample.text,
        hash: sample.hash,
      ),
    );
  }

  @override
  List<ScreenSample> pending({int limit = 240}) {
    final query = _box
        .query(ScreenSampleEntity_.processedAt.isNull())
        .order(ScreenSampleEntity_.capturedAt)
        .build();
    try {
      query.limit = limit;
      return query.find().map(_toDomain).toList();
    } finally {
      query.close();
    }
  }

  @override
  void markProcessed(Iterable<int> ids, DateTime now) {
    final entities = _box
        .getMany(ids.toList())
        .whereType<ScreenSampleEntity>()
        .toList();
    if (entities.isEmpty) return;
    for (final entity in entities) {
      entity.processedAt = now;
    }
    _box.putMany(entities);
  }

  @override
  void prune({required DateTime before, int keepMax = 4000}) {
    final expired = _box
        .query(ScreenSampleEntity_.capturedAt.lessThanDate(before))
        .build();
    try {
      _box.removeMany(expired.findIds());
    } finally {
      expired.close();
    }

    final count = _box.count();
    if (count <= keepMax) return;
    final oldest = _box.query().order(ScreenSampleEntity_.capturedAt).build();
    try {
      oldest.limit = count - keepMax;
      _box.removeMany(oldest.findIds());
    } finally {
      oldest.close();
    }
  }

  ScreenSample _toDomain(ScreenSampleEntity entity) => ScreenSample(
    id: entity.internalId,
    capturedAt: entity.capturedAt,
    packageName: entity.packageName,
    text: entity.text,
    hash: entity.hash,
  );
}
