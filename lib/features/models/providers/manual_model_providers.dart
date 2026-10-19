import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/storage_providers.dart';
import '../data/manual_model_repository.dart';
import '../data/manual_model_store.dart';
import '../data/models/manual_model.dart';

final manualModelRepositoryProvider = Provider<ManualModelRepository>((ref) {
  final db = ref.watch(databaseProvider);
  return ManualModelRepository(ObjectBoxManualModelStore(db.manualModelBox));
});

/// The persisted manual models of one provider.
final manualModelsProvider =
    FutureProvider.family<List<ManualModel>, String>((ref, serverId) async {
  return ref.watch(manualModelRepositoryProvider).listForServer(serverId);
});

final manualModelsNotifierProvider =
    NotifierProvider<ManualModelsNotifier, int>(ManualModelsNotifier.new);

class ManualModelsNotifier extends Notifier<int> {
  @override
  int build() => 0;

  Future<void> add(ManualModel model) async {
    ref.read(manualModelRepositoryProvider).add(model);
    ref.invalidate(manualModelsProvider(model.serverId));
    state++;
  }

  Future<void> remove(String serverId, String modelId) async {
    ref.read(manualModelRepositoryProvider).remove(serverId, modelId);
    ref.invalidate(manualModelsProvider(serverId));
    state++;
  }
}
