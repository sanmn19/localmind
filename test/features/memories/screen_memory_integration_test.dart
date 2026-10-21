import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/screen_memory_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/features/ask_local/data/ask_local_main_channel.dart';
import 'package:localmind/features/chat/data/chat_service.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/memories/data/memory_extraction_service.dart';
import 'package:localmind/features/memories/data/memory_repository.dart';
import 'package:localmind/features/memories/data/memory_store.dart';
import 'package:localmind/features/memories/data/screen_memory_batch_processor.dart';
import 'package:localmind/features/memories/data/screen_memory_scheduler.dart';
import 'package:localmind/features/memories/data/screen_sample_store.dart';
import 'package:localmind/features/memories/data/screen_sampler.dart';
import 'package:localmind/features/memories/data/screen_text_gateway.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeGateway implements ScreenTextGateway {
  _FakeGateway({required this.text, required this.packageName});

  final String text;
  final String packageName;

  @override
  Future<ScreenText?> readText() async =>
      ScreenText(packageName: packageName, text: text, isInteractive: true);
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
  void prune({required DateTime before, int keepMax = 4000}) {}
}

class _FakeExtractor extends MemoryExtractionService {
  @override
  Future<List<ExtractedMemory>> extractScreen({
    required ChatService chatService,
    required Server server,
    required String modelId,
    required ChatParameters params,
    required String screenText,
    required String sourceApp,
    List<String> existingTitles = const [],
    DateTime? now,
  }) async => const [];
}

class _NoopChatService implements ChatService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBatch extends ScreenMemoryBatchProcessor {
  _FakeBatch()
    : super(
        store: _RecordingStore(),
        extractor: _FakeExtractor(),
        repository: MemoryRepository(InMemoryMemoryStore()),
        chatService: _NoopChatService.new,
        server: () => null,
        modelId: () => '',
        params: ChatParameters.defaults,
        settings: () => AppSettings(screenMemoryEnabled: true),
      );

  int calls = 0;
  int pruneCalls = 0;

  @override
  Future<void> batchNow() async {
    calls++;
  }

  @override
  Future<void> pruneSamples() async {
    pruneCalls++;
  }
}

class _EnabledSettings extends SettingsNotifier {
  @override
  AppSettings build() => AppSettings(screenMemoryEnabled: true);
}

ScreenMemoryScheduler _scheduler({
  required ScreenTextGateway gateway,
  required MemoryExtractionService extractor,
}) {
  return ScreenMemoryScheduler(
    sampler: ScreenSampler(
      gateway: gateway,
      store: _RecordingStore(),
      settings: () => AppSettings(screenMemoryEnabled: true),
    ),
    batch: ScreenMemoryBatchProcessor(
      store: _RecordingStore(),
      extractor: extractor,
      repository: MemoryRepository(InMemoryMemoryStore()),
      chatService: _NoopChatService.new,
      server: () => null,
      modelId: () => '',
      params: ChatParameters.defaults,
      settings: () => AppSettings(screenMemoryEnabled: true),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a shown overlay triggers a screen-memory batch', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final batch = _FakeBatch();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        settingsProvider.overrideWith(_EnabledSettings.new),
        screenBatchProcessorProvider.overrideWithValue(batch),
      ],
    );
    addTearDown(container.dispose);
    final channel = AskLocalMainChannel(
      openOverlay:
          ({capturePath, required selectedText, bootstrap = const {}}) async =>
              true,
    );

    await channel.handle(
      const MethodCall('askLocalRequestArrived', {'selectedText': 'x'}),
      container,
    );

    expect(batch.calls, 1);
  });

  test('a failed overlay open does not trigger a batch', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final batch = _FakeBatch();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        settingsProvider.overrideWith(_EnabledSettings.new),
        screenBatchProcessorProvider.overrideWithValue(batch),
      ],
    );
    addTearDown(container.dispose);
    final channel = AskLocalMainChannel(
      openOverlay:
          ({capturePath, required selectedText, bootstrap = const {}}) async =>
              false,
    );

    await channel.handle(
      const MethodCall('askLocalRequestArrived', {'selectedText': 'x'}),
      container,
    );

    expect(batch.calls, 0);
  });

  test('applySettings starts and stops the timer', () async {
    final gateway = _FakeGateway(text: 'x', packageName: 'com.whatsapp');
    final scheduler = _scheduler(gateway: gateway, extractor: _FakeExtractor());
    addTearDown(scheduler.dispose);
    scheduler.applySettings(AppSettings().copyWith(screenMemoryEnabled: true));
    expect(scheduler.isRunning, isTrue);
    scheduler.applySettings(AppSettings().copyWith(screenMemoryEnabled: false));
    expect(scheduler.isRunning, isFalse);
  });

  test('disabling the scheduler prunes samples without batching', () async {
    final batch = _FakeBatch();
    final scheduler = ScreenMemoryScheduler(
      sampler: ScreenSampler(
        gateway: _FakeGateway(text: 'x', packageName: 'com.whatsapp'),
        store: _RecordingStore(),
        settings: () => AppSettings(screenMemoryEnabled: true),
      ),
      batch: batch,
    );
    addTearDown(scheduler.dispose);

    scheduler.applySettings(AppSettings().copyWith(screenMemoryEnabled: true));
    expect(scheduler.isRunning, isTrue);
    expect(batch.pruneCalls, 0);

    scheduler.applySettings(AppSettings().copyWith(screenMemoryEnabled: false));
    expect(scheduler.isRunning, isFalse);
    await Future<void>.delayed(Duration.zero);

    expect(batch.pruneCalls, 1);
    expect(batch.calls, 0);
  });
}
