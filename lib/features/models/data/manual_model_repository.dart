import 'manual_model_store.dart';
import 'models/manual_model.dart';

/// Rules for hand-added models: ids are trimmed, blank ids are rejected, and a
/// `(serverId, modelId)` pair is stored at most once.
class ManualModelRepository {
  ManualModelRepository(this._store);

  final ManualModelStore _store;

  List<ManualModel> listForServer(String serverId) =>
      _store.listForServer(serverId);

  bool add(ManualModel model) {
    final modelId = model.modelId.trim();
    if (modelId.isEmpty) return false;
    final exists = _store
        .listForServer(model.serverId)
        .any((row) => row.modelId == modelId);
    if (exists) return false;
    _store.put(
      ManualModel(
        serverId: model.serverId,
        modelId: modelId,
        displayName: _normalizeDisplayName(model.displayName),
        createdAt: model.createdAt,
      ),
    );
    return true;
  }

  bool remove(String serverId, String modelId) {
    final id = modelId.trim();
    final exists = _store
        .listForServer(serverId)
        .any((row) => row.modelId == id);
    if (!exists) return false;
    _store.remove(serverId, id);
    return true;
  }

  void removeAllForServer(String serverId) =>
      _store.removeAllForServer(serverId);

  String? _normalizeDisplayName(String? displayName) {
    final trimmed = displayName?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
