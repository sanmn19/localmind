import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/models/data/models/model_info.dart';
import 'package:localmind/features/models/data/models/rig_model_entry.dart';
import 'package:localmind/features/models/utils/default_model_pick.dart';

ModelInfo _model(ModelAvailability availability) => ModelInfo(
  id: 'DeepSeek-V4.1-Flash',
  name: 'DeepSeek V4.1 Flash',
  serverType: ServerType.openAICompatible,
  serverId: 's1',
  availability: availability,
);

RigModelEntry _entry(String name, String served, {bool active = false}) =>
    RigModelEntry(
      name: name,
      label: name,
      servedModelName: served,
      enabled: true,
      active: active,
    );

void main() {
  test('a loadable pick plans the load and never changes the default', () {
    final pick = resolveDefaultModelPick(_model(ModelAvailability.loadable), [
      _entry('ds41-flash-1017', 'DeepSeek-V4.1-Flash'),
      _entry('other', 'Other'),
    ]);

    expect(pick.load, isTrue);
    expect(pick.targets.single.name, 'ds41-flash-1017');
  });

  test('an available pick applies the default directly', () {
    final pick = resolveDefaultModelPick(_model(ModelAvailability.available), [
      _entry('ds41-flash-1017', 'DeepSeek-V4.1-Flash'),
    ]);

    expect(pick.load, isFalse);
    expect(pick.targets, isEmpty);
  });

  test('a loadable pick without a roster target yields no targets', () {
    final pick = resolveDefaultModelPick(
      _model(ModelAvailability.loadable),
      const [],
    );

    expect(pick.load, isTrue);
    expect(pick.targets, isEmpty);
  });
}
