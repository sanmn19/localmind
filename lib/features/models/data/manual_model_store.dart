import '../../../core/storage/entities.dart';
import '../../../objectbox.g.dart';
import 'models/manual_model.dart';

/// Persistence seam for [ManualModel]. The ObjectBox implementation is the
/// production path; [InMemoryManualModelStore] keeps repository logic testable
/// (the host test toolchain has no native ObjectBox library).
abstract class ManualModelStore {
  List<ManualModel> listForServer(String serverId);

  void put(ManualModel model);

  void remove(String serverId, String modelId);

  void removeAllForServer(String serverId);
}

class ObjectBoxManualModelStore implements ManualModelStore {
  ObjectBoxManualModelStore(this._box);

  final Box<ManualModelEntity> _box;

  @override
  List<ManualModel> listForServer(String serverId) {
    final query = _box
        .query(ManualModelEntity_.serverId.equals(serverId))
        .build();
    try {
      final rows = query.find()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return rows.map(_toDomain).toList();
    } finally {
      query.close();
    }
  }

  @override
  void put(ManualModel model) {
    _box.put(
      ManualModelEntity(
        serverId: model.serverId,
        modelId: model.modelId,
        displayName: model.displayName,
        createdAt: model.createdAt,
      ),
    );
  }

  @override
  void remove(String serverId, String modelId) {
    final query = _box
        .query(
          ManualModelEntity_.serverId
              .equals(serverId)
              .and(ManualModelEntity_.modelId.equals(modelId)),
        )
        .build();
    try {
      _box.removeMany(query.findIds());
    } finally {
      query.close();
    }
  }

  @override
  void removeAllForServer(String serverId) {
    final query = _box
        .query(ManualModelEntity_.serverId.equals(serverId))
        .build();
    try {
      _box.removeMany(query.findIds());
    } finally {
      query.close();
    }
  }

  ManualModel _toDomain(ManualModelEntity entity) => ManualModel(
    serverId: entity.serverId,
    modelId: entity.modelId,
    displayName: entity.displayName,
    createdAt: entity.createdAt,
  );
}

class InMemoryManualModelStore implements ManualModelStore {
  final List<ManualModel> _rows = [];

  @override
  List<ManualModel> listForServer(String serverId) {
    final rows = _rows.where((m) => m.serverId == serverId).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return rows;
  }

  @override
  void put(ManualModel model) => _rows.add(model);

  @override
  void remove(String serverId, String modelId) =>
      _rows.removeWhere((m) => m.serverId == serverId && m.modelId == modelId);

  @override
  void removeAllForServer(String serverId) =>
      _rows.removeWhere((m) => m.serverId == serverId);
}
