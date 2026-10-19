import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/features/chat/providers/model_selection_providers.dart';
import 'package:localmind/features/models/data/manual_model_repository.dart';
import 'package:localmind/features/models/data/manual_model_store.dart';
import 'package:localmind/features/models/data/models/manual_model.dart';
import 'package:localmind/features/models/data/models/model_info.dart';
import 'package:localmind/features/models/providers/manual_model_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

ManualModel _manual(String serverId, String modelId) => ManualModel(
  serverId: serverId,
  modelId: modelId,
  createdAt: DateTime(2026, 10, 19),
);

ManualModelRepository _repo() =>
    ManualModelRepository(InMemoryManualModelStore())..add(_manual('s1', 'm1'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('removing the selected manual model clears the selection', () async {
    final prefs = await SharedPreferences.getInstance();
    final repo = _repo();
    final container = ProviderContainer(
      overrides: [
        manualModelRepositoryProvider.overrideWithValue(repo),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(selectedModelProvider.notifier)
        .setModel(
          ModelInfo(
            id: 'm1',
            name: 'M1',
            serverType: ServerType.openAICompatible,
            serverId: 's1',
          ),
        );
    await container
        .read(manualModelsNotifierProvider.notifier)
        .remove('s1', 'm1');

    expect(container.read(selectedModelProvider), isNull);
  });

  test('removing the default manual model clears the default', () async {
    final prefs = await SharedPreferences.getInstance();
    final repo = _repo();
    final container = ProviderContainer(
      overrides: [
        manualModelRepositoryProvider.overrideWithValue(repo),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(settingsProvider.notifier)
        .setDefaultModel(serverId: 's1', modelId: 'm1');
    await container
        .read(manualModelsNotifierProvider.notifier)
        .remove('s1', 'm1');

    expect(container.read(settingsProvider).defaultModelId, isNull);
  });

  test(
    'removing another server model leaves selection and default intact',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = _repo()..add(_manual('s2', 'm2'));
      final container = ProviderContainer(
        overrides: [
          manualModelRepositoryProvider.overrideWithValue(repo),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(selectedModelProvider.notifier)
          .setModel(
            ModelInfo(
              id: 'm1',
              name: 'M1',
              serverType: ServerType.openAICompatible,
              serverId: 's1',
            ),
          );
      container
          .read(settingsProvider.notifier)
          .setDefaultModel(serverId: 's1', modelId: 'm1');

      await container
          .read(manualModelsNotifierProvider.notifier)
          .remove('s2', 'm2');

      expect(container.read(selectedModelProvider)?.id, 'm1');
      expect(container.read(settingsProvider).defaultModelId, 'm1');
    },
  );
}
