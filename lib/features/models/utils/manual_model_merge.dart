import '../../../../core/models/enums.dart';
import '../data/models/manual_model.dart';
import '../data/models/model_info.dart';
import '../data/models/rig_model_entry.dart';

/// Merges the provider's detected models with the user's hand-added ones.
///
/// Detected models keep [ModelAvailability.available]; manual models are annotated
/// from the switcher roster (when configured). A failed detection keeps the manual
/// rows as [ModelAvailability.unknown] instead of hiding them.
List<ModelInfo> mergeManualModels(
  List<ModelInfo> detected,
  List<ManualModel> manual, {
  required String serverId,
  required ServerType serverType,
  bool rosterConfigured = false,
  List<RigModelEntry>? roster,
  bool detectionFailed = false,
}) {
  final seen = detected.map((model) => model.id).toSet();
  final merged = <ModelInfo>[...detected];

  for (final entry in manual) {
    final id = entry.modelId.trim();
    if (id.isEmpty || !seen.add(id)) continue;
    final name = (entry.displayName ?? '').trim();
    merged.add(
      ModelInfo(
        id: id,
        name: name.isEmpty ? id : name,
        serverType: serverType,
        serverId: serverId,
        status: ModelStatus.unloaded,
        availability: _availabilityFor(
          id,
          detectionFailed: detectionFailed,
          rosterConfigured: rosterConfigured,
          roster: roster,
        ),
      ),
    );
  }

  return merged;
}

ModelAvailability _availabilityFor(
  String modelId, {
  required bool detectionFailed,
  required bool rosterConfigured,
  required List<RigModelEntry>? roster,
}) {
  if (detectionFailed) return ModelAvailability.unknown;
  if (!rosterConfigured) return ModelAvailability.unavailable;
  if (roster == null) return ModelAvailability.unknown;

  final matches = roster.where((entry) => entry.servedModelName.trim() == modelId);
  if (matches.any((entry) => entry.enabled && entry.active)) {
    return ModelAvailability.available;
  }
  if (matches.any((entry) => entry.enabled && !entry.active)) {
    return ModelAvailability.loadable;
  }
  return ModelAvailability.unavailable;
}
