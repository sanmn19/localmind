import '../../../core/models/enums.dart';
import '../data/models/model_info.dart';
import '../data/models/rig_model_entry.dart';

/// The settings default-model dropdown's pick decision: a `loadable` model
/// starts the rig load flow (and never changes the default); anything else is
/// applied as the default directly.
class DefaultModelPick {
  const DefaultModelPick({required this.load, this.targets = const []});

  final bool load;

  final List<RigModelEntry> targets;
}

DefaultModelPick resolveDefaultModelPick(
  ModelInfo? model,
  List<RigModelEntry> roster,
) {
  if (model == null || model.availability != ModelAvailability.loadable) {
    return const DefaultModelPick(load: false);
  }
  return DefaultModelPick(
    load: true,
    targets: roster
        .where(
          (entry) =>
              entry.servedModelName == model.id &&
              entry.enabled &&
              !entry.active,
        )
        .toList(),
  );
}
