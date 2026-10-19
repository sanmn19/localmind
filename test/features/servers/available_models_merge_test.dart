import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/models/data/models/manual_model.dart';
import 'package:localmind/features/models/data/models/model_info.dart';
import 'package:localmind/features/models/data/models/rig_model_entry.dart';
import 'package:localmind/features/models/utils/manual_model_merge.dart';

ModelInfo _model(String id) => ModelInfo(
      id: id,
      name: id,
      serverType: ServerType.openAICompatible,
      serverId: 's1',
    );

ManualModel _manual(String modelId, [String? displayName]) => ManualModel(
      serverId: 's1',
      modelId: modelId,
      displayName: displayName,
      createdAt: DateTime(2026, 10, 19),
    );

RigModelEntry _rigEntry(
  String name,
  String servedModelName, {
  bool enabled = true,
  bool active = false,
}) =>
    RigModelEntry(
      name: name,
      label: name,
      servedModelName: servedModelName,
      enabled: enabled,
      active: active,
    );

void main() {
  test('manual models merge after detected ones, deduped by id', () {
    final merged = mergeManualModels(
      [_model('m1')],
      [_manual('m1'), _manual('m2', 'My M2')],
      serverId: 's1',
      serverType: ServerType.openAICompatible,
    );

    expect(merged.map((m) => m.id), ['m1', 'm2']);
    expect(merged.last.displayName, 'My M2');
    expect(merged.first.availability, ModelAvailability.available);
    expect(merged.last.availability, ModelAvailability.unavailable);
  });

  test('roster makes a matching manual model loadable', () {
    final merged = mergeManualModels(
      const [],
      [_manual('DeepSeek-V4.1-Flash')],
      serverId: 's1',
      serverType: ServerType.openAICompatible,
      rosterConfigured: true,
      roster: [
        _rigEntry('ds41-flash-1017', 'DeepSeek-V4.1-Flash',
            enabled: true, active: false),
      ],
    );

    expect(merged.single.availability, ModelAvailability.loadable);
  });

  test('an active roster match is available', () {
    final merged = mergeManualModels(
      const [],
      [_manual('DeepSeek-V4.1-Flash')],
      serverId: 's1',
      serverType: ServerType.openAICompatible,
      rosterConfigured: true,
      roster: [
        _rigEntry('ds41-flash-1017', 'DeepSeek-V4.1-Flash',
            enabled: true, active: true),
      ],
    );

    expect(merged.single.availability, ModelAvailability.available);
  });

  test('roster failure is unknown, never unavailable', () {
    final merged = mergeManualModels(
      const [],
      [_manual('m1')],
      serverId: 's1',
      serverType: ServerType.openAICompatible,
      rosterConfigured: true,
      roster: null,
    );

    expect(merged.single.availability, ModelAvailability.unknown);
  });

  test('failed detection keeps manual models as unknown', () {
    final merged = mergeManualModels(
      const [],
      [_manual('m1')],
      serverId: 's1',
      serverType: ServerType.openAICompatible,
      detectionFailed: true,
    );

    expect(merged.single.availability, ModelAvailability.unknown);
  });
}
