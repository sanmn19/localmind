import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/chat/data/chat_service.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/mcp_integration.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/memories/data/memory_extraction_service.dart';
import 'package:localmind/features/memories/data/models/memory.dart';
import 'package:localmind/features/servers/data/models/server.dart';

void main() {
  final service = MemoryExtractionService();

  test('parses a JSON array and maps kinds, importance and scope', () {
    final parsed = service.parse('''
```json
[
  {"kind":"preference","title":"Coffee order","content":"Prefers oat milk flat whites.","importance":70,"scope":"global"},
  {"kind":"event","title":"Kitchen renovation","content":"Renovating the kitchen in November.","importance":45,"scope":"chat"}
]
```
''');
    expect(parsed, hasLength(2));
    expect(parsed.first.kind, MemoryKind.preference);
    expect(parsed.first.title, 'Coffee order');
    expect(parsed.first.importance, 70);
    expect(parsed.first.conversationScoped, isFalse);
    expect(parsed.last.kind, MemoryKind.event);
    expect(parsed.last.conversationScoped, isTrue);
  });

  test('drops secret-looking memories', () {
    final parsed = service.parse(
      '[{"kind":"fact","title":"API key","content":"sk-abcdef1234567890",'
      '"importance":90,"scope":"global"}]',
    );
    expect(parsed, isEmpty);
  });

  test('caps a turn at three memories', () {
    final parsed = service.parse(
      '[{"kind":"fact","title":"A","content":"one","importance":50},'
      '{"kind":"fact","title":"B","content":"two","importance":50},'
      '{"kind":"fact","title":"C","content":"three","importance":50},'
      '{"kind":"fact","title":"D","content":"four","importance":50}]',
    );
    expect(parsed, hasLength(3));
  });

  test('returns empty for prose or invalid output', () {
    expect(service.parse('Nothing worth remembering.'), isEmpty);
    expect(service.parse('[{"title":'), isEmpty);
  });

  test('clamps importance into 0-100', () {
    final parsed = service.parse(
      '[{"kind":"fact","title":"Age","content":"42 years old.","importance":900}]',
    );
    expect(parsed.single.importance, 100);
  });

  test('screen extraction parses tags, summary and expiry', () async {
    final parsed = await _extractScreen(service, '''
  [{"kind":"inferred","title":"Standup","summary":"Standup at 10:00",
    "content":"Team standup moved to 10:00 on 2026-10-21.",
    "tags":["work","standup"],"importance":60,
    "expiresAt":"2026-10-21","scope":"chat"}]
  ''');
    expect(parsed.single.kind, MemoryKind.inferred);
    expect(parsed.single.tags, ['work', 'standup']);
    expect(parsed.single.shortSummary, 'Standup at 10:00');
    expect(parsed.single.expiresAt, DateTime(2026, 10, 21, 23, 59, 59, 999));
    expect(parsed.single.conversationScoped, isTrue);
  });

  test('a permanent inferred memory keeps expiresAt null', () async {
    final parsed = await _extractScreen(
      service,
      '[{"kind":"inferred","title":"Lives in Berlin",'
      '"summary":"Lives in Berlin","content":"Lives in Berlin.",'
      '"tags":["location"],"importance":60,"expiresAt":null}]',
    );
    expect(parsed.single.expiresAt, isNull);
  });

  test('chat parse coerces an inferred result to a fact and drops expiry', () {
    final parsed = service.parse(
      '[{"kind":"inferred","title":"Standup",'
      '"summary":"Standup at 10:00","content":"Standup at 10:00.",'
      '"tags":["work"],"expiresAt":"2026-10-21"}]',
    );
    expect(parsed.single.kind, MemoryKind.fact);
    expect(parsed.single.expiresAt, isNull);
  });

  test(
    'screen extraction forces the inferred kind when it is renamed',
    () async {
      final parsed = await _extractScreen(
        service,
        '[{"kind":"fact","title":"Standup","content":"Standup at 10:00."},'
        '{"title":"Lives in Berlin","content":"Lives in Berlin."}]',
      );
      expect(parsed, hasLength(2));
      expect(
        parsed.map((memory) => memory.kind),
        everyElement(MemoryKind.inferred),
      );
    },
  );

  test('normalizes tags and caps them at eight', () async {
    final parsed = await _extractScreen(
      service,
      '[{"kind":"inferred","title":"T","content":"c",'
      '"tags":[" Work ","work","",1,"a","b","c","d","e","f","g","h"]}]',
    );
    expect(parsed.single.tags, ['work', 'a', 'b', 'c', 'd', 'e', 'f', 'g']);
  });

  test('parsed tags are unmodifiable', () async {
    final parsed = await _extractScreen(
      service,
      '[{"kind":"inferred","title":"T","content":"c","tags":["work"]}]',
    );
    expect(() => parsed.single.tags.add('other'), throwsUnsupportedError);
  });

  test(
    'an inferred memory without a summary falls back to its content',
    () async {
      final parsed = await _extractScreen(
        service,
        '[{"kind":"inferred","title":"Lives in Berlin",'
        '"content":"Lives in Berlin.","tags":["location"]}]',
      );
      expect(parsed.single.shortSummary, 'Lives in Berlin.');
    },
  );

  test('a short summary is capped at 400 characters', () async {
    final longSummary = 'x' * 500;
    final parsed = await _extractScreen(
      service,
      '[{"kind":"inferred","title":"T","content":"c","summary":"$longSummary"}]',
    );
    expect(parsed.single.shortSummary, hasLength(400));
  });

  test('an unparsable expiry stays permanent', () async {
    final parsed = await _extractScreen(
      service,
      '[{"kind":"inferred","title":"T","content":"c","expiresAt":"soon"}]',
    );
    expect(parsed.single.expiresAt, isNull);
  });

  test(
    'screen extraction prompt carries the screen text and existing titles',
    () async {
      final chat = _RecordingChatService(
        '[{"kind":"inferred","title":"Standup",'
        '"summary":"Standup at 10:00","content":"Standup at 10:00.",'
        '"tags":["work"],"importance":60,"expiresAt":null}]',
      );

      final extracted = await service.extractScreen(
        chatService: chat,
        server: _server(),
        modelId: 'model',
        params: ChatParameters.defaults(),
        screenText: 'Standup at 10:00',
        sourceApp: 'com.whatsapp',
        existingTitles: const ['Coffee order'],
        now: DateTime(2026, 10, 20, 9),
      );

      final capturedUserContent = chat.lastMessages!.single.content;
      expect(capturedUserContent, contains('Standup at 10:00'));
      expect(capturedUserContent, contains('com.whatsapp'));
      expect(capturedUserContent, contains('Already remembered'));
      expect(capturedUserContent, contains('Coffee order'));
      expect(capturedUserContent, contains('2026-10-20'));
      expect(extracted.single.kind, MemoryKind.inferred);
    },
  );

  test('screen extraction keeps at most two memories', () async {
    final chat = _RecordingChatService(
      '[{"kind":"inferred","title":"A","content":"a"},'
      '{"kind":"inferred","title":"B","content":"b"},'
      '{"kind":"inferred","title":"C","content":"c"}]',
    );

    final extracted = await service.extractScreen(
      chatService: chat,
      server: _server(),
      modelId: 'model',
      params: ChatParameters.defaults(),
      screenText: 'A B C',
      sourceApp: 'com.whatsapp',
    );

    expect(extracted, hasLength(2));
  });

  test('screen extraction disables reasoning for the hidden call', () async {
    final chat = _RecordingChatService('[]');

    await service.extractScreen(
      chatService: chat,
      server: _server(),
      modelId: 'model',
      params: ChatParameters.defaults(),
      screenText: 'Standup at 10:00',
      sourceApp: 'com.whatsapp',
    );

    expect(chat.lastParams?.reasoningEnabled, isFalse);
  });

  test('an empty screen skips the hidden call', () async {
    final chat = _RecordingChatService('[]');

    final extracted = await service.extractScreen(
      chatService: chat,
      server: _server(),
      modelId: 'model',
      params: ChatParameters.defaults(),
      screenText: '   ',
      sourceApp: 'com.whatsapp',
    );

    expect(extracted, isEmpty);
    expect(chat.lastMessages, isNull);
  });
}

Server _server() {
  final now = DateTime(2026, 10, 20);
  return Server(
    id: 'server-1',
    name: 'Local',
    type: ServerType.lmStudio,
    host: 'localhost',
    port: 1234,
    createdAt: now,
    lastConnectedAt: now,
  );
}

Future<List<ExtractedMemory>> _extractScreen(
  MemoryExtractionService service,
  String reply, {
  String screenText = 'screen',
  DateTime? now,
}) {
  return service.extractScreen(
    chatService: _RecordingChatService(reply),
    server: _server(),
    modelId: 'model',
    params: ChatParameters.defaults(),
    screenText: screenText,
    sourceApp: 'com.whatsapp',
    now: now,
  );
}

class _RecordingChatService implements ChatService {
  _RecordingChatService(this.reply);

  final String reply;
  List<Message>? lastMessages;
  ChatParameters? lastParams;

  @override
  Stream<ChatResponse> sendMessage({
    required Server server,
    required String modelId,
    required List<Message> messages,
    required ChatParameters params,
    List<McpIntegration>? integrations,
    List<ToolDefinition>? tools,
    bool continueGeneration = false,
  }) {
    lastMessages = messages;
    lastParams = params;
    return Stream.fromIterable([
      ChatResponse(type: ChatResponseType.message, content: reply),
      const ChatResponse(type: ChatResponseType.done),
    ]);
  }

  @override
  void cancelStream() {}
}
