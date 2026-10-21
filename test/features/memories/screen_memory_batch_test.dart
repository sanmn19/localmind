import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/chat/data/chat_service.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/memories/data/memory_extraction_service.dart';
import 'package:localmind/features/memories/data/memory_repository.dart';
import 'package:localmind/features/memories/data/memory_store.dart';
import 'package:localmind/features/memories/data/models/memory.dart';
import 'package:localmind/features/memories/data/screen_memory_batch_processor.dart';
import 'package:localmind/features/memories/data/screen_sample_store.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';

class _RecordingStore implements ScreenSampleStore {
  final List<ScreenSample> added = [];
  final List<int> processed = [];
  DateTime? prunedBefore;
  int? prunedKeepMax;

  @override
  void add(ScreenSample sample) => added.add(sample);

  @override
  List<ScreenSample> pending({int limit = 240}) => added.take(limit).toList();

  @override
  void markProcessed(Iterable<int> ids, DateTime now) => processed.addAll(ids);

  @override
  void prune({required DateTime before, int keepMax = 4000}) {
    prunedBefore = before;
    prunedKeepMax = keepMax;
  }
}

class _FakeExtractor extends MemoryExtractionService {
  _FakeExtractor({this.results = const [], this.fail = false});

  final List<ExtractedMemory> results;
  bool fail;
  int calls = 0;
  String lastText = '';
  String lastSourceApp = '';

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
  }) async {
    calls++;
    lastText = screenText;
    lastSourceApp = sourceApp;
    if (fail) throw StateError('extraction failed');
    return results;
  }
}

class _NoopChatService implements ChatService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _server = Server(
  id: 'server',
  name: 'Test server',
  type: ServerType.openAICompatible,
  host: 'localhost',
  port: 1234,
  createdAt: DateTime(2026),
  lastConnectedAt: DateTime(2026),
);

ScreenSample _sample(int id, String text, String packageName) => ScreenSample(
  id: id,
  capturedAt: DateTime(2026, 10, 20, 9, id),
  packageName: packageName,
  text: text,
  hash: 'hash-$id',
);

ScreenMemoryBatchProcessor _processor({
  required ScreenSampleStore store,
  required MemoryExtractionService extractor,
  MemoryRepository? repository,
  AppSettings? settings,
  DateTime Function()? now,
  void Function(String)? onFailure,
}) {
  return ScreenMemoryBatchProcessor(
    store: store,
    extractor: extractor,
    repository: repository ?? MemoryRepository(InMemoryMemoryStore()),
    chatService: _NoopChatService.new,
    server: () => _server,
    modelId: () => 'model',
    params: ChatParameters.defaults,
    settings: () => settings ?? AppSettings(screenMemoryEnabled: true),
    now: now,
    onFailure: onFailure,
  );
}

void main() {
  test('one batch makes one extraction call and marks the samples', () async {
    final store = _RecordingStore()
      ..add(_sample(1, 'Standup 10:00', 'com.whatsapp'))
      ..add(_sample(2, 'Standup 10:30', 'com.whatsapp'));
    final extractor = _FakeExtractor();
    final batch = _processor(store: store, extractor: extractor);
    await batch.batchNow();
    expect(extractor.calls, 1);
    expect(extractor.lastText, contains('10:30'));
    expect(store.processed, [1, 2]);
  });

  test('the batch hourly cap stops extraction', () async {
    final store = _RecordingStore()..add(_sample(1, 'x', 'com.whatsapp'));
    final extractor = _FakeExtractor();
    final batch = _processor(store: store, extractor: extractor);
    for (var i = 0; i < 7; i++) {
      await batch.batchNow();
    }
    expect(extractor.calls, 6);
  });

  test('the batch merges the latest text per package', () async {
    final store = _RecordingStore()
      ..add(_sample(1, 'First note', 'com.whatsapp'))
      ..add(_sample(2, 'Latest note', 'com.whatsapp'))
      ..add(_sample(3, 'Browser page', 'com.android.chrome'));
    final extractor = _FakeExtractor();
    final batch = _processor(store: store, extractor: extractor);
    await batch.batchNow();
    expect(extractor.lastText, contains('Latest note'));
    expect(extractor.lastText, isNot(contains('First note')));
    expect(extractor.lastText, contains('Browser page'));
  });

  test('the batch writes inferred memories with the model expiry', () async {
    final store = _RecordingStore()
      ..add(_sample(1, 'Standup 10:00', 'com.whatsapp'));
    final expiry = DateTime(2026, 10, 21, 23, 59, 59, 999);
    final extractor = _FakeExtractor(
      results: [
        ExtractedMemory(
          kind: MemoryKind.inferred,
          title: 'Standup at 10:00',
          content: 'The user has a standup at 10:00.',
          importance: 60,
          conversationScoped: false,
          tags: const ['work'],
          shortSummary: 'Standup at 10:00',
          expiresAt: expiry,
        ),
        const ExtractedMemory(
          kind: MemoryKind.inferred,
          title: 'Works on Localmind',
          content: 'The user works on Localmind.',
          importance: 50,
          conversationScoped: false,
        ),
      ],
    );
    final memoryStore = InMemoryMemoryStore();
    final batch = _processor(
      store: store,
      extractor: extractor,
      repository: MemoryRepository(memoryStore),
    );
    await batch.batchNow();

    final memories = memoryStore.list();
    expect(memories, hasLength(2));
    expect(memories.every((m) => m.kind == MemoryKind.inferred), isTrue);
    expect(memories.every((m) => m.sourceApp == 'com.whatsapp'), isTrue);
    final dated = memories.firstWhere((m) => m.title == 'Standup at 10:00');
    expect(dated.expiresAt, expiry);
    expect(dated.tags, ['work']);
    final permanent = memories.firstWhere(
      (m) => m.title == 'Works on Localmind',
    );
    expect(permanent.expiresAt, isNull);
  });

  test(
    'a batch prunes samples older than 24 hours and caps the queue',
    () async {
      final now = DateTime(2026, 10, 20, 12);
      final store = _RecordingStore();
      final batch = _processor(
        store: store,
        extractor: _FakeExtractor(),
        now: () => now,
      );
      await batch.batchNow();
      expect(store.prunedBefore, now.subtract(const Duration(hours: 24)));
      expect(store.prunedKeepMax, 4000);
    },
  );

  test('pruneSamples prunes the queue without extracting', () async {
    final now = DateTime(2026, 10, 20, 12);
    final store = _RecordingStore()..add(_sample(1, 'x', 'com.whatsapp'));
    final extractor = _FakeExtractor();
    final batch = _processor(
      store: store,
      extractor: extractor,
      now: () => now,
    );

    await batch.pruneSamples();

    expect(store.prunedBefore, now.subtract(const Duration(hours: 24)));
    expect(store.prunedKeepMax, 4000);
    expect(extractor.calls, 0);
    expect(store.processed, isEmpty);
  });

  test('a disabled feature still prunes stale samples', () async {
    final now = DateTime(2026, 10, 20, 12);
    final store = _RecordingStore();
    final extractor = _FakeExtractor();
    final batch = _processor(
      store: store,
      extractor: extractor,
      settings: AppSettings(),
      now: () => now,
    );
    await batch.batchNow();
    expect(store.prunedBefore, now.subtract(const Duration(hours: 24)));
    expect(store.prunedKeepMax, 4000);
    expect(extractor.calls, 0);
  });

  test('one empty item does not drop the rest of the batch', () async {
    final store = _RecordingStore()
      ..add(_sample(1, 'Standup 10:00', 'com.whatsapp'));
    final extractor = _FakeExtractor(
      results: const [
        ExtractedMemory(
          kind: MemoryKind.inferred,
          title: 'Empty',
          content: '   ',
          importance: 50,
          conversationScoped: false,
        ),
        ExtractedMemory(
          kind: MemoryKind.inferred,
          title: 'Standup at 10:00',
          content: 'The user has a standup at 10:00.',
          importance: 50,
          conversationScoped: false,
        ),
      ],
    );
    final memoryStore = InMemoryMemoryStore();
    final batch = _processor(
      store: store,
      extractor: extractor,
      repository: MemoryRepository(memoryStore),
    );
    await batch.batchNow();

    expect(memoryStore.list().map((m) => m.title), ['Standup at 10:00']);
  });

  test('a failed batch backs off for five minutes', () async {
    var now = DateTime(2026, 10, 20, 9);
    final store = _RecordingStore()..add(_sample(1, 'x', 'com.whatsapp'));
    final extractor = _FakeExtractor(fail: true);
    final failures = <String>[];
    final batch = _processor(
      store: store,
      extractor: extractor,
      now: () => now,
      onFailure: failures.add,
    );
    await batch.batchNow();
    expect(failures, hasLength(1));
    await batch.batchNow();
    expect(extractor.calls, 1);
    now = now.add(const Duration(minutes: 6));
    extractor.fail = false;
    await batch.batchNow();
    expect(extractor.calls, 2);
  });

  test('a failed extraction leaves the samples pending', () async {
    final now = DateTime(2026, 10, 20, 9);
    final store = _RecordingStore()..add(_sample(1, 'x', 'com.whatsapp'));
    final extractor = _FakeExtractor(fail: true);
    final batch = _processor(
      store: store,
      extractor: extractor,
      now: () => now,
    );

    await batch.batchNow();

    expect(extractor.calls, 1);
    expect(store.processed, isEmpty);
    await batch.batchNow();
    expect(extractor.calls, 1);
  });

  test('an empty successful extraction marks the samples processed', () async {
    final now = DateTime(2026, 10, 20, 9);
    final store = _RecordingStore()..add(_sample(1, 'x', 'com.whatsapp'));
    final extractor = _FakeExtractor();
    final batch = _processor(
      store: store,
      extractor: extractor,
      now: () => now,
    );

    await batch.batchNow();

    expect(extractor.calls, 1);
    expect(store.processed, [1]);
  });

  test('a queued sample from a now-blocked package is not extracted', () async {
    final store = _RecordingStore()
      ..add(_sample(1, 'Bank balance 1234', 'com.bank'))
      ..add(_sample(2, 'Standup 10:00', 'com.whatsapp'));
    final extractor = _FakeExtractor();
    final batch = _processor(
      store: store,
      extractor: extractor,
      settings: AppSettings(
        screenMemoryEnabled: true,
        screenMemoryBlockedApps: const ['com.bank'],
      ),
    );

    await batch.batchNow();

    expect(extractor.lastText, isNot(contains('Bank balance')));
    expect(extractor.lastText, contains('Standup 10:00'));
    expect(store.processed, containsAll([1, 2]));
  });
}
