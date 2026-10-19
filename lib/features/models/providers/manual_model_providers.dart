import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/storage_providers.dart';
import '../../chat/providers/model_selection_providers.dart';
import '../../servers/providers/server_providers.dart';
import '../../../core/providers/app_providers.dart';
import '../data/manual_model_repository.dart';
import 'rig_load_providers.dart';
import '../data/manual_model_store.dart';
import '../data/models/manual_model.dart';

final manualModelRepositoryProvider = Provider<ManualModelRepository>((ref) {
  final db = ref.watch(databaseProvider);
  return ManualModelRepository(ObjectBoxManualModelStore(db.manualModelBox));
});

/// The persisted manual models of one provider.
final manualModelsProvider = FutureProvider.family<List<ManualModel>, String>((
  ref,
  serverId,
) async {
  return ref.watch(manualModelRepositoryProvider).listForServer(serverId);
});

final manualModelsNotifierProvider =
    NotifierProvider<ManualModelsNotifier, int>(ManualModelsNotifier.new);

class ManualModelsNotifier extends Notifier<int> {
  @override
  int build() => 0;

  Future<void> add(ManualModel model) async {
    ref.read(manualModelRepositoryProvider).add(model);
    invalidateAvailableModelsCache(model.serverId);
    ref.invalidate(manualModelsProvider(model.serverId));
    state++;
  }

  Future<void> remove(String serverId, String modelId) async {
    final removed = ref
        .read(manualModelRepositoryProvider)
        .remove(serverId, modelId);
    if (!removed) return;
    // Never leave dangling pointers at a removed model.
    final selected = ref.read(selectedModelProvider);
    if (selected != null &&
        selected.serverId == serverId &&
        selected.id == modelId) {
      ref.read(selectedModelProvider.notifier).clear();
    }
    final settings = ref.read(settingsProvider);
    if (settings.defaultModelServerId == serverId &&
        settings.defaultModelId == modelId) {
      ref
          .read(settingsProvider.notifier)
          .setDefaultModel(serverId: serverId, modelId: null);
    }
    invalidateAvailableModelsCache(serverId);
    ref.invalidate(manualModelsProvider(serverId));
    state++;
  }

  /// Provider deletion: drop the rows and any dangling pointers.
  Future<void> clearForServer(String serverId) async {
    ref.read(manualModelRepositoryProvider).removeAllForServer(serverId);
    ref.invalidate(manualModelsProvider(serverId));
    invalidateAvailableModelsCache(serverId);
    final selected = ref.read(selectedModelProvider);
    if (selected != null && selected.serverId == serverId) {
      ref.read(selectedModelProvider.notifier).clear();
    }
    final settings = ref.read(settingsProvider);
    if (settings.defaultModelServerId == serverId) {
      ref
          .read(settingsProvider.notifier)
          .setDefaultModel(serverId: serverId, modelId: null);
    }
    ref.read(rigLoadProvider.notifier).resetForServer(serverId);
    state++;
  }
}
