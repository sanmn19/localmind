import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/models/data/models/model_info.dart';
import 'package:localmind/features/models/data/models/rig_model_entry.dart';
import 'package:localmind/features/models/data/models/rig_switch_status.dart';
import 'package:localmind/features/models/data/rig_model_switcher_service.dart';
import 'package:localmind/features/models/providers/rig_load_providers.dart';
import 'package:localmind/features/models/providers/rig_switcher_providers.dart';

class _FakeSwitcher implements RigModelSwitcherApi {
  final List<String> switched = [];
  final List<Uri> cancelled = [];
  RigSwitchStatus status = const RigSwitchStatus(
    phase: 'loading',
    progress: 10,
    target: 'ds41',
  );
  int polls = 0;

  @override
  Future<List<RigModelEntry>> fetchRoster(Uri base) async => const [];

  @override
  Future<RigSwitchStatus> fetchStatus(Uri base) async {
    polls++;
    return status;
  }

  @override
  Future<void> switchTo(Uri base, String name) async => switched.add(name);

  @override
  Future<void> cancel(Uri base) async => cancelled.add(base);
}

ModelInfo _model() => ModelInfo(
  id: 'DeepSeek-V4.1-Flash',
  name: 'DeepSeek V4.1 Flash',
  serverType: ServerType.openAICompatible,
  serverId: 's1',
  availability: ModelAvailability.loadable,
);

RigModelEntry _target() => const RigModelEntry(
  name: 'ds41-flash-1017',
  label: 'DeepSeek V4.1 Flash',
  servedModelName: 'DeepSeek-V4.1-Flash',
  enabled: true,
  active: false,
);

Future<void> _waitFor(bool Function() probe) async {
  for (var i = 0; i < 200; i++) {
    if (probe()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not met in time');
}

void main() {
  setUp(() {
    RigLoadNotifier.pollInterval = const Duration(milliseconds: 1);
  });

  tearDown(() {
    RigLoadNotifier.pollInterval = const Duration(seconds: 3);
  });

  test(
    'start switches then polls until healthy and selects on completion',
    () async {
      final fake = _FakeSwitcher()
        ..status = const RigSwitchStatus(phase: 'healthy', progress: 100);
      final container = ProviderContainer(
        overrides: [rigSwitcherServiceProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);

      var loaded = false;
      await container
          .read(rigLoadProvider.notifier)
          .start(
            Uri.parse('http://rig:9000'),
            's1',
            _model(),
            _target(),
            onLoaded: () => loaded = true,
          );

      expect(fake.switched, ['ds41-flash-1017']);
      await _waitFor(() => loaded);
      expect(container.read(rigLoadProvider), isNull);
    },
  );

  test('polling stops on failed and surfaces the error', () async {
    final fake = _FakeSwitcher()
      ..status = const RigSwitchStatus(
        phase: 'failed',
        progress: 40,
        error: 'weights missing',
      );
    final container = ProviderContainer(
      overrides: [rigSwitcherServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    await container
        .read(rigLoadProvider.notifier)
        .start(Uri.parse('http://rig:9000'), 's1', _model(), _target());

    await _waitFor(() => container.read(rigLoadProvider)?.active == false);
    final state = container.read(rigLoadProvider)!;
    expect(state.status.isFailed, isTrue);
    expect(state.status.error, 'weights missing');
  });

  test(
    'dispose cancels the timer but never cancels the switch on the rig',
    () async {
      final fake = _FakeSwitcher();
      final container = ProviderContainer(
        overrides: [rigSwitcherServiceProvider.overrideWithValue(fake)],
      );

      await container
          .read(rigLoadProvider.notifier)
          .start(Uri.parse('http://rig:9000'), 's1', _model(), _target());
      container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(fake.cancelled, isEmpty);
      expect(fake.polls, lessThanOrEqualTo(1));
    },
  );

  test('start is a no-op while a switch is in flight', () async {
    final fake = _FakeSwitcher();
    final container = ProviderContainer(
      overrides: [rigSwitcherServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    await container
        .read(rigLoadProvider.notifier)
        .start(Uri.parse('http://rig:9000'), 's1', _model(), _target());
    await container
        .read(rigLoadProvider.notifier)
        .start(Uri.parse('http://rig:9000'), 's1', _model(), _target());

    expect(fake.switched, hasLength(1));
  });
}
