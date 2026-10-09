import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/chat_background_service_provider.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/services/chat_background_service.dart';
import 'package:localmind/features/chat/data/chat_service.dart' hide ToolCallData;
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/providers/chat_mcp_providers.dart';
import 'package:localmind/features/chat/providers/chat_notifier.dart';
import 'package:localmind/features/chat/providers/chat_params_providers.dart';
import 'package:localmind/features/chat/providers/chat_service_providers.dart';
import 'package:localmind/features/chat/providers/fork_chat_notifier.dart';
import 'package:localmind/features/chat/providers/model_selection_providers.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/on_device/providers/on_device_providers.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/features/voice_mode/providers/voice_mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Task 3 of the selection-fork-chats feature: ForkChatNotifier streams the
// fork's replies into a per-fork transcript and persists every exchange as a
// user + assistant pair inside the hidden fork conversation.
//
// The duplex ChatService contract is faked per repo convention; the
// persistence boundary (loadForkMessages/persistMessage) is faked the same
// way ChatNotifier tests fake loadConversationMessages/persistMessage, since
// the host toolchain cannot load libobjectbox.so.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('submit streams into transcript and persists both turns', () async {
    final chatService = _StreamingChatService(const ['Hel', 'lo, how']);
    final saved = <Message>[];
    final container = await _forkTestContainer(
      chatService: chatService,
      onPersist: saved.add,
    );
    addTearDown(container.dispose);

    await container
        .read(chatProvider.notifier)
        .loadConversation(_mainConversation);
    final notifier = container.read(
      forkChatNotifierProvider('forkC1').notifier,
    );

    await notifier.submit(
      'forkC1',
      'who wrote it?',
      selectedText: 'Ada Lovelace wrote it',
      anchorMessageId: 'a-1',
    );

    final state = container.read(forkChatNotifierProvider('forkC1'));
    expect(state.isStreaming, isFalse);
    expect(state.failure, isNull);
    expect(state.transcript, hasLength(2));
    expect(state.transcript.first.role, MessageRole.user);
    expect(
      state.transcript.first.content,
      'Selected: "Ada Lovelace wrote it"\n\nwho wrote it?',
    );
    expect(state.transcript.last.role, MessageRole.assistant);
    expect(state.transcript.last.content, 'Hello, how');

    // Both turns persisted into the fork conversation with the fork id.
    expect(saved, hasLength(2));
    for (final row in saved) {
      expect(row.conversationId, 'forkC1');
    }
    expect(saved.first.role, MessageRole.user);
    expect(saved.last.role, MessageRole.assistant);
    expect(saved.last.status, MessageStatus.complete);
    expect(saved.last.modelId, 'model');

    // Wire request: composed system first, anchored main history, then the
    // quoted first fork turn last.
    expect(chatService.requests, hasLength(1));
    final wire = chatService.requests.single;
    expect(wire.first.role, MessageRole.system);
    expect(wire.last.role, MessageRole.user);
    expect(
      wire.last.content,
      contains('Selected: "Ada Lovelace wrote it"\n\nwho wrote it?'),
    );
    expect(wire.where((m) => m.role != MessageRole.system).length, 3);

    // The main thread is untouched by fork activity.
    final main = container.read(chatProvider);
    expect(main.isStreaming, isFalse);
    expect(main.messages, hasLength(2));

    // Follow-up turn: no re-quote, plain question on the wire, four rows
    // persisted in total.
    await notifier.submit(
      'forkC1',
      'and why?',
      selectedText: 'Ada Lovelace wrote it',
      anchorMessageId: 'a-1',
    );
    expect(chatService.requests, hasLength(2));
    expect(chatService.requests.last.last.content, 'and why?');
    expect(saved, hasLength(4));
    expect(
      container.read(forkChatNotifierProvider('forkC1')).transcript,
      hasLength(4),
    );
  });

  test(
    'rejects with a surfaced failure and zero writes when the anchor is in an inactive variant',
    () async {
      final chatService = _StreamingChatService(const ['reply']);
      final saved = <Message>[];
      final container = await _forkTestContainer(
        chatService: chatService,
        onPersist: saved.add,
        mainTimeline: [
          Message(
            id: 'u-1',
            conversationId: 'c-main',
            role: MessageRole.user,
            content: 'who?',
            createdAt: DateTime.utc(2026, 10, 8, 10, 1),
            status: MessageStatus.complete,
            variantGroupId: 'g-1',
            variantIndex: 0,
            threadOrder: 0,
            isActiveVariant: true,
          ),
          Message(
            id: 'a-1-0',
            conversationId: 'c-main',
            role: MessageRole.assistant,
            content: 'the active reply',
            createdAt: DateTime.utc(2026, 10, 8, 10, 2),
            status: MessageStatus.complete,
            variantGroupId: 'g-2',
            variantIndex: 0,
            threadOrder: 1,
            isActiveVariant: true,
            parentMessageId: 'u-1',
          ),
          Message(
            id: 'a-1-1',
            conversationId: 'c-main',
            role: MessageRole.assistant,
            content: 'the inactive variant reply',
            createdAt: DateTime.utc(2026, 10, 8, 10, 3),
            status: MessageStatus.complete,
            variantGroupId: 'g-2',
            variantIndex: 1,
            threadOrder: 1,
            isActiveVariant: false,
            parentMessageId: 'u-1',
          ),
          Message(
            id: 'u-2',
            conversationId: 'c-main',
            role: MessageRole.user,
            content: 'post-anchor question',
            createdAt: DateTime.utc(2026, 10, 8, 10, 4),
            status: MessageStatus.complete,
            variantGroupId: 'g-3',
            variantIndex: 0,
            threadOrder: 2,
            isActiveVariant: true,
            parentMessageId: 'a-1-1',
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(chatProvider.notifier)
          .loadConversation(_mainConversation);
      final notifier = container.read(
        forkChatNotifierProvider('forkC1').notifier,
      );

      await notifier.submit(
        'forkC1',
        'who wrote it?',
        selectedText: 'Ada Lovelace wrote it',
        // messageById can see the superset (inactive variants included) but
        // mainTimelineUpTo only resolves the active timeline — submit must
        // surface the mismatch instead of silently mis-slicing.
        anchorMessageId: 'a-1-1',
      );

      final state = container.read(forkChatNotifierProvider('forkC1'));
      expect(state.failure, isNotNull);
      expect(state.isStreaming, isFalse);
      expect(state.transcript, isEmpty);
      expect(chatService.requests, isEmpty);
      expect(saved, isEmpty);
    },
  );

  test(
    'sanitizes a dangling legacy tool-chain tail before building the fork request',
    () async {
      final chatService = _StreamingChatService(const ['fork reply']);
      final saved = <Message>[];
      final container = await _forkTestContainer(
        chatService: chatService,
        onPersist: saved.add,
        mainTimeline: [
          Message(
            id: 'lg-user-1',
            conversationId: 'c-main',
            role: MessageRole.user,
            content: 'search the web',
            createdAt: DateTime.utc(2026, 10, 8, 10, 1),
            status: MessageStatus.complete,
            variantGroupId: 'lg-turn',
            variantIndex: 0,
            threadOrder: 0,
            isActiveVariant: true,
          ),
          Message(
            id: 'lg-round-1',
            conversationId: 'c-main',
            role: MessageRole.assistant,
            content: '',
            createdAt: DateTime.utc(2026, 10, 8, 10, 2),
            status: MessageStatus.complete,
            toolCalls: [
              ToolCallData(
                id: 'call_legacy',
                toolName: 'web_search',
                arguments: {'query': 'legacy'},
                result: 'legacy result',
              ),
            ],
            variantGroupId: 'lg-turn',
            variantIndex: 0,
            threadOrder: 1,
            isActiveVariant: true,
            parentMessageId: 'lg-user-1',
          ),
          Message(
            id: 'lg-tool-1',
            conversationId: 'c-main',
            role: MessageRole.tool,
            content: 'legacy result',
            createdAt: DateTime.utc(2026, 10, 8, 10, 3),
            status: MessageStatus.complete,
            toolCallId: 'call_legacy',
            variantGroupId: 'lg-turn',
            variantIndex: 0,
            threadOrder: 1,
            isActiveVariant: true,
            parentMessageId: 'lg-round-1',
          ),
          Message(
            id: 'lg-answer',
            conversationId: 'c-main',
            role: MessageRole.assistant,
            content: 'the legacy final answer',
            createdAt: DateTime.utc(2026, 10, 8, 10, 4),
            status: MessageStatus.complete,
            variantGroupId: 'lg-turn',
            variantIndex: 1,
            threadOrder: 2,
            isActiveVariant: true,
            parentMessageId: 'lg-tool-1',
          ),
          Message(
            id: 'lg-user-2',
            conversationId: 'c-main',
            role: MessageRole.user,
            content: 'and one more thing',
            createdAt: DateTime.utc(2026, 10, 8, 10, 5),
            status: MessageStatus.complete,
            variantGroupId: 'lg-user-2',
            variantIndex: 0,
            threadOrder: 3,
            isActiveVariant: true,
            parentMessageId: 'lg-answer',
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(chatProvider.notifier)
          .loadConversation(_mainConversation);
      final notifier = container.read(
        forkChatNotifierProvider('forkC1').notifier,
      );

      // Anchoring on the legacy tool-chain round row: the sliced context
      // would otherwise end on assistant(tool_calls) + tool(result) with no
      // matching pair on the fork wire.
      await notifier.submit(
        'forkC1',
        'who wrote it?',
        selectedText: 'legacy result',
        anchorMessageId: 'lg-tool-1',
      );

      expect(chatService.requests, hasLength(1));
      final wire = chatService.requests.single;
      final nonSystem = wire.where((m) => m.role != MessageRole.system);
      // Trailing assistant(tool_calls) + tool rows are trimmed until the
      // main tail ends on the plain user row; the quoted fork turn follows.
      expect(
        nonSystem.map((m) => m.id).toList(),
        ['lg-user-1', wire.last.id],
      );
      expect(
        wire.any((m) => m.role == MessageRole.tool),
        isFalse,
        reason: 'a dangling tool(result) row breaks the OpenAI protocol',
      );
      expect(
        wire.any((m) => m.role == MessageRole.assistant && m.toolCalls != null),
        isFalse,
        reason: 'a dangling assistant(tool_calls) row has no tool result '
            'in the fork request',
      );

      final state = container.read(forkChatNotifierProvider('forkC1'));
      expect(state.failure, isNull);
      expect(state.transcript, hasLength(2));
    },
  );

  test('empty reply surfaces the failure and persists the error turn',
      () async {
    final chatService = _StreamingChatService(const []);
    final saved = <Message>[];
    final container = await _forkTestContainer(
      chatService: chatService,
      onPersist: saved.add,
    );
    addTearDown(container.dispose);

    await container
        .read(chatProvider.notifier)
        .loadConversation(_mainConversation);
    final notifier = container.read(
      forkChatNotifierProvider('forkC1').notifier,
    );

    await notifier.submit(
      'forkC1',
      'who wrote it?',
      selectedText: 'Ada Lovelace wrote it',
      anchorMessageId: 'a-1',
    );

    final state = container.read(forkChatNotifierProvider('forkC1'));
    expect(state.failure, isNotNull);
    expect(state.isStreaming, isFalse);
    expect(state.transcript.last.status, MessageStatus.error);
    expect(saved, hasLength(2));
    expect(saved.last.status, MessageStatus.error);
  });

  test('cancel() forwards to the active ChatService', () async {
    final chatService = _HangingChatService();
    final saved = <Message>[];
    final container = await _forkTestContainer(
      chatService: chatService,
      onPersist: saved.add,
    );
    addTearDown(container.dispose);

    await container
        .read(chatProvider.notifier)
        .loadConversation(_mainConversation);
    final notifier = container.read(
      forkChatNotifierProvider('forkC1').notifier,
    );

    final submitting = notifier.submit(
      'forkC1',
      'who wrote it?',
      selectedText: 'Ada Lovelace wrote it',
      anchorMessageId: 'a-1',
    );
    // Let the first delta land.
    await _drain();
    expect(
      container.read(forkChatNotifierProvider('forkC1')).isStreaming,
      isTrue,
    );

    notifier.cancel();
    await submitting;

    expect(chatService.cancelCalls, hasLength(1));
    final state = container.read(forkChatNotifierProvider('forkC1'));
    expect(state.isStreaming, isFalse);
    // Partially received content is kept in the transcript.
    expect(state.transcript.last.role, MessageRole.assistant);
    expect(state.transcript.last.content, 'Hel');
  });

  test('submit refuses ids from outside its own family slot', () async {
    final container = await _forkTestContainer(
      chatService: _StreamingChatService(const []),
      onPersist: (m) {},
    );
    addTearDown(container.dispose);

    final notifier = container.read(
      forkChatNotifierProvider('forkC1').notifier,
    );

    expect(
      () => notifier.submit(
        'other-fork',
        'why?',
        selectedText: 'text',
        anchorMessageId: 'a-1',
      ),
      throwsArgumentError,
    );
  });
}

Future<void> _drain([int iterations = 60]) async {
  for (var i = 0; i < iterations; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final _remoteServer = Server(
  id: 'remote',
  name: 'Remote',
  type: ServerType.ollama,
  host: '127.0.0.1',
  port: 11434,
  createdAt: DateTime.utc(2026, 10, 5),
  lastConnectedAt: DateTime.utc(2026, 10, 5),
  status: ConnectionStatus.connected,
);

final _mainConversation = Conversation(
  id: 'c-main',
  title: 'Main chat',
  createdAt: DateTime.utc(2026, 10, 8, 10),
  updatedAt: DateTime.utc(2026, 10, 8, 10),
);

List<Message> _defaultMainTimeline() {
  final u1 = Message(
    id: 'u-1',
    conversationId: 'c-main',
    role: MessageRole.user,
    content: 'who?',
    createdAt: DateTime.utc(2026, 10, 8, 10, 1),
    status: MessageStatus.complete,
    variantGroupId: 'g-1',
    variantIndex: 0,
    threadOrder: 0,
    isActiveVariant: true,
  );
  final a1 = Message(
    id: 'a-1',
    conversationId: 'c-main',
    role: MessageRole.assistant,
    content: 'Ada Lovelace wrote it',
    createdAt: DateTime.utc(2026, 10, 8, 10, 2),
    status: MessageStatus.complete,
    variantGroupId: 'g-2',
    variantIndex: 0,
    threadOrder: 1,
    isActiveVariant: true,
    parentMessageId: 'u-1',
  );
  return [u1, a1];
}

Future<ProviderContainer> _forkTestContainer({
  required ChatService chatService,
  required void Function(Message) onPersist,
  List<Message>? mainTimeline,
}) async {
  SharedPreferences.setMockInitialValues({});
  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(
        await SharedPreferences.getInstance(),
      ),
      activeChatTargetProvider.overrideWithValue(
        ActiveChatTarget(
          server: _remoteServer,
          selectedModel: null,
          effectiveModelId: 'model',
          modelLabel: 'Model',
        ),
      ),
      chatParamsProvider.overrideWithValue(ChatParameters.defaults()),
      chatMcpConfigProvider.overrideWith(_DisabledMcpNotifier.new),
      chatBackgroundServiceProvider.overrideWithValue(
        _TestChatBackgroundService(),
      ),
      settingsProvider.overrideWith(_TestSettingsNotifier.new),
      voiceModeProvider.overrideWith(_IdleVoiceModeNotifier.new),
      conv.conversationsProvider.overrideWith(_TestConversationsNotifier.new),
      onDeviceEngineProvider.overrideWith(_EmptyEngineNotifier.new),
      chatServiceFactoryProvider.overrideWithValue((_) => chatService),
      chatProvider.overrideWith(
        () => _MainTimelineChatNotifier(
          seed: mainTimeline ?? _defaultMainTimeline(),
        ),
      ),
      forkChatNotifierProvider.overrideWith2(
        (forkConversationId) => _SandboxForkChatNotifier(
          onPersist: onPersist,
          forkConversationId: forkConversationId,
        ),
      ),
    ],
  );
}

// Fork conversation rows come back from the persistence hook (empty unless a
// test seeds them), mirroring how ChatNotifier tests fake loadConversation.
class _SandboxForkChatNotifier extends ForkChatNotifier {
  _SandboxForkChatNotifier({
    required this.onPersist,
    super.forkConversationId = '',
  });

  final void Function(Message message) onPersist;

  @override
  Future<List<Message>> loadForkMessages(String forkConversationId) =>
      Future.value(const []);

  @override
  Future<void> persistMessage(Message message) => Future.sync(() {
        onPersist(message);
      });
}

class _MainTimelineChatNotifier extends ChatNotifier {
  _MainTimelineChatNotifier({required this.seed});

  final List<Message> seed;

  @override
  ChatState build() => const ChatState();

  @override
  Future<List<Message>> loadConversationMessages(String conversationId) async =>
      List.of(seed);

  @override
  Future<void> persistMessage(Message message) async {}
}

class _TestConversationsNotifier extends conv.ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [_mainConversation];

  @override
  Future<void> syncConversationStats(
    String id, {
    required int messageCount,
    required int characterCount,
    String? preview,
  }) async {}

  @override
  Future<void> updateTokenCount(String id, int totalTokenCount) async {}
}

class _DisabledMcpNotifier extends ChatMcpConfigNotifier {
  @override
  ChatMcpConfig build() => const ChatMcpConfig(enabled: false);
}

class _TestChatBackgroundService extends ChatBackgroundService {
  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

class _TestSettingsNotifier extends SettingsNotifier {
  @override
  AppSettings build() => AppSettings(
    resumeLastChat: false,
    autoGenerateTitle: false,
    showSystemMessages: true,
  );
}

class _IdleVoiceModeNotifier extends VoiceModeNotifier {
  @override
  VoiceModeState build() => const VoiceModeState();
}

class _EmptyEngineNotifier extends OnDeviceEngineNotifier {
  @override
  OnDeviceEngineState build() => const OnDeviceEngineState();
}

class _StreamingChatService implements ChatService {
  _StreamingChatService(this.chunks);

  final List<String> chunks;
  final List<List<Message>> requests = [];

  @override
  Stream<ChatResponse> sendMessage({
    required Server server,
    required String modelId,
    required List<Message> messages,
    required ChatParameters params,
    List<McpIntegration>? integrations,
    List<ToolDefinition>? tools,
    bool continueGeneration = false,
  }) async* {
    requests.add(messages);
    for (final chunk in chunks) {
      yield ChatResponse(type: ChatResponseType.message, content: chunk);
    }
    yield const ChatResponse(type: ChatResponseType.done);
  }

  @override
  void cancelStream() {}
}

/// Never closes on its own; [cancelStream] must be the closer.
class _HangingChatService implements ChatService {
  final List<String> cancelCalls = [];
  StreamController<ChatResponse>? _controller;

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
    _controller = StreamController<ChatResponse>();
    _controller!.add(
      const ChatResponse(type: ChatResponseType.message, content: 'Hel'),
    );
    return _controller!.stream;
  }

  @override
  void cancelStream() {
    cancelCalls.add('cancel');
    unawaited(_controller?.close());
  }
}
