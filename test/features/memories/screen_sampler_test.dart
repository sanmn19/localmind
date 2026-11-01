import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/memories/data/screen_sample_store.dart';
import 'package:localmind/features/memories/data/screen_sampler.dart';
import 'package:localmind/features/memories/data/screen_text_gateway.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';

class _FakeGateway implements ScreenTextGateway {
  _FakeGateway({
    required this.text,
    required this.packageName,
    this.interactive = true,
  });

  final String text;
  final String packageName;
  final bool interactive;
  int reads = 0;

  @override
  Future<ScreenText?> readText() async => null;

  @override
  Future<void> startSampling(int intervalMs, {bool eventDriven = true}) async {}

  @override
  Future<void> stopSampling() async {}

  @override
  Future<List<ScreenText>> drainSamples() async {
    reads++;
    return [
      ScreenText(
        packageName: packageName,
        text: text,
        isInteractive: interactive,
      ),
    ];
  }

  @override
  Future<int> pendingSampleCount() async => 0;
}

class _RecordingStore implements ScreenSampleStore {
  final List<ScreenSample> added = [];

  @override
  void add(ScreenSample sample) => added.add(sample);

  @override
  void markProcessed(Iterable<int> ids, DateTime now) {}

  @override
  List<ScreenSample> pending({int limit = 240}) => added.take(limit).toList();

  @override
  int pendingCount() => added.length;

  @override
  void prune({required DateTime before, int keepMax = 4000}) {}
}

AppSettings _enabled({List<String> blocked = const []}) =>
    AppSettings(screenMemoryEnabled: true, screenMemoryBlockedApps: blocked);

void main() {
  test('an unchanged screen is sampled once', () async {
    final gateway = _FakeGateway(
      text: 'Standup 10:00',
      packageName: 'com.whatsapp',
    );
    final store = _RecordingStore();
    final sampler = ScreenSampler(
      gateway: gateway,
      store: store,
      settings: () => _enabled(),
    );
    await sampler.tick();
    await sampler.tick();
    expect(store.added, hasLength(1));
  });

  test('a blocked package is never stored', () async {
    final gateway = _FakeGateway(text: 'secret', packageName: 'com.bank');
    final store = _RecordingStore();
    final sampler = ScreenSampler(
      gateway: gateway,
      store: store,
      settings: () => _enabled(blocked: const ['com.bank']),
    );
    await sampler.tick();
    expect(store.added, isEmpty);
  });

  test('a screen with a card number or OTP is never stored', () async {
    final store = _RecordingStore();
    var text = 'Card 4111 1111 1111 1111 on file';
    final sampler = ScreenSampler(
      gateway: _ChangeableGateway(() => text),
      store: store,
      settings: () => _enabled(),
    );
    await sampler.tick();
    expect(store.added, isEmpty);

    text = 'Your verification code is 482913';
    await sampler.tick();
    expect(store.added, isEmpty);

    text = 'Call me at +1 555 123 4567';
    await sampler.tick();
    expect(store.added, hasLength(1));
  });

  test('a non-interactive screen is never read', () async {
    final gateway = _FakeGateway(
      text: 'x',
      packageName: 'com.whatsapp',
      interactive: false,
    );
    final store = _RecordingStore();
    final sampler = ScreenSampler(
      gateway: gateway,
      store: store,
      settings: () => _enabled(),
    );
    await sampler.tick();
    expect(store.added, isEmpty);
  });

  test('the feature toggle stops sampling', () async {
    final gateway = _FakeGateway(
      text: 'Standup 10:00',
      packageName: 'com.whatsapp',
    );
    final store = _RecordingStore();
    final sampler = ScreenSampler(
      gateway: gateway,
      store: store,
      settings: () => AppSettings(),
    );
    await sampler.tick();
    expect(gateway.reads, 0);
    expect(store.added, isEmpty);
  });

  test('a changed screen is sampled again', () async {
    final store = _RecordingStore();
    var text = 'Standup 10:00';
    final sampler = ScreenSampler(
      gateway: _ChangeableGateway(() => text),
      store: store,
      settings: () => _enabled(),
    );
    await sampler.tick();
    text = 'Standup 10:30';
    await sampler.tick();
    expect(store.added, hasLength(2));
    expect(store.added.last.text, contains('10:30'));
  });

  test('the stored sample is normalized and hashed', () async {
    final gateway = _FakeGateway(
      text: '  Standup\n  10:00  ',
      packageName: 'com.whatsapp',
    );
    final store = _RecordingStore();
    final sampler = ScreenSampler(
      gateway: gateway,
      store: store,
      settings: () => _enabled(),
    );
    await sampler.tick();
    expect(store.added.single.text, 'Standup 10:00');
    expect(store.added.single.packageName, 'com.whatsapp');
    expect(store.added.single.hash, isNotEmpty);
  });

  test('dispose stops further samples', () async {
    final gateway = _FakeGateway(
      text: 'Standup 10:00',
      packageName: 'com.whatsapp',
    );
    final store = _RecordingStore();
    final sampler = ScreenSampler(
      gateway: gateway,
      store: store,
      settings: () => _enabled(),
    );
    sampler.dispose();
    await sampler.tick();
    expect(store.added, isEmpty);
  });
}

class _ChangeableGateway implements ScreenTextGateway {
  _ChangeableGateway(this.text);

  final String Function() text;

  @override
  Future<ScreenText?> readText() async => null;

  @override
  Future<void> startSampling(int intervalMs, {bool eventDriven = true}) async {}

  @override
  Future<void> stopSampling() async {}

  @override
  Future<List<ScreenText>> drainSamples() async => [
        ScreenText(
          packageName: 'com.whatsapp',
          text: text(),
          isInteractive: true,
        ),
      ];

  @override
  Future<int> pendingSampleCount() async => 0;
}
