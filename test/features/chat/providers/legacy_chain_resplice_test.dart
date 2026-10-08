import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/chat_background_service_provider.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/services/chat_background_service.dart';
import 'package:localmind/features/chat/data/chat_service.dart'
    hide ToolCallData;
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/providers/chat_mcp_providers.dart';
import 'package:localmind/features/chat/providers/chat_notifier.dart';
import 'package:localmind/features/chat/providers/chat_params_providers.dart';
import 'package:localmind/features/chat/providers/chat_service_providers.dart';
import 'package:localmind/features/chat/providers/model_selection_providers.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/on_device/providers/on_device_providers.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/servers/providers/server_providers.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/features/voice_mode/providers/voice_mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Regression test for the legacy-conversation wire duplication:
//
//   Conversations persisted before chain-consolidation (bb38e98) store tool
//   chains as a linear parentMessageId chain with every row flagged
//   isActiveVariant. `resolveActiveTimeline` therefore surfaces the round
//   rows themselves (assistant(tool_calls) + tool result) as timeline steps,
//   and `spliceToolChainContext` re-inserted the same rows from allMessages
//   ahead of the chain's tail — the follow-up request carried the same
//   assistant(tool_calls) + tool(result) pair TWICE, which vLLM/Ollama
//   reject as a protocol violation.
//
// Legacy shape (the user's existing chats):
//   legacy-user-1   user
//   legacy-round-1  assistant with toolCalls        (parent user-1)
//   legacy-tool-1   tool result for that call        (parent round-1)
//   legacy-answer   assistant final answer           (parent tool-1)
//   legacy-user-2   user follow-up                   (parent answer)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SharedPreferences.setMockInitialValues({});

  test(
    'follow-up request does not re-splice round rows the timeline already shows',
    () async {
      final chatService = _FreshReplyChatService();
      late ProviderContainer container;

      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          activeServerProvider.overrideWith(_RemoteServerNotifier.new),
          activeChatTargetProvider.overrideWithValue(
            ActiveChatTarget(
              server: _remoteServer,
              selectedModel: null,
              effectiveModelId: 'model',
              modelLabel: 'Model',
            ),
          ),
          onDeviceEngineProvider.overrideWith(_EmptyEngineNotifier.new),
          chatProvider.overrideWith(_LegacyConversationChatNotifier.new),
          chatServiceProvider.overrideWithValue(chatService),
          chatServiceFactoryProvider.overrideWithValue((_) => chatService),
          chatParamsProvider.overrideWithValue(ChatParameters.defaults()),
          chatMcpConfigProvider.overrideWith(_EnabledMcpNotifier.new),
          chatBackgroundServiceProvider.overrideWithValue(
            _TestChatBackgroundService(),
          ),
          settingsProvider.overrideWith(_TestSettingsNotifier.new),
          voiceModeProvider.overrideWith(_IdleVoiceModeNotifier.new),
          conv.conversationsProvider.overrideWith(
            _FakeConversationsNotifier.new,
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(conv.conversationsProvider.future);
      await container
          .read(chatProvider.notifier)
          .loadConversation(_conversation);
      await container.read(chatProvider.notifier).sendMessage('keep going');
      await _drain();

      expect(container.read(chatProvider).isStreaming, isFalse);
      expect(chatService.requests, hasLength(1));

      final request = chatService.requests.single
          .where((m) => m.role != MessageRole.system)
          .toList();
      final ids = request.map((m) => m.id).toList();

      // The round rows the legacy timeline already surfaces must appear
      // exactly once — no duplicate tool_call_ids on the wire.
      expect(
        ids.where((id) => id == 'legacy-round-1'),
        hasLength(1),
        reason:
            'legacy assistant(tool_calls) round row is already on the '
            'resolved timeline; the splice must not add it a second time',
      );
      expect(
        ids.where((id) => id == 'legacy-tool-1'),
        hasLength(1),
        reason:
            'legacy tool(result) row is already on the resolved timeline; '
            'the splice must not add it a second time',
      );

      // Protocol order stays intact: assistant(tool_calls) immediately
      // followed by its tool result, then the chain answer.
      final roundIdx = ids.indexOf('legacy-round-1');
      expect(roundIdx, greaterThanOrEqualTo(0));
      expect(ids[roundIdx + 1], 'legacy-tool-1');
      expect(ids[roundIdx + 2], 'legacy-answer');
    },
  );
}

Future<void> _drain([int iterations = 40]) async {
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

final _conversation = Conversation(
  id: 'conversation-legacy-chain',
  title: 'Legacy chain',
  createdAt: DateTime.utc(2026, 10, 5),
  updatedAt: DateTime.utc(2026, 10, 5),
);

class _FreshReplyChatService implements ChatService {
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
    yield const ChatResponse(
      type: ChatResponseType.message,
      content: 'fresh reply',
    );
    yield const ChatResponse(type: ChatResponseType.done);
  }

  @override
  void cancelStream() {}
}

class _LegacyConversationChatNotifier extends ChatNotifier {
  final List<Message> saved = [];

  @override
  ChatState build() => const ChatState();

  @override
  Future<List<Message>> loadConversationMessages(String conversationId) async {
    final legacyRows = <Message>[
      Message(
        id: 'legacy-user-1',
        conversationId: _conversation.id,
        role: MessageRole.user,
        content: 'search the web',
        createdAt: DateTime.utc(2026, 10, 5, 10),
        variantGroupId: 'legacy-turn',
        threadOrder: 0,
      ),
      Message(
        id: 'legacy-round-1',
        conversationId: _conversation.id,
        role: MessageRole.assistant,
        content: '',
        createdAt: DateTime.utc(2026, 10, 5, 10, 1),
        toolCalls: [
          ToolCallData(
            id: 'call_legacy_a',
            toolName: 'web_search',
            arguments: {'query': 'legacy'},
            result: 'legacy result',
          ),
        ],
        variantGroupId: 'legacy-turn',
        threadOrder: 1,
        parentMessageId: 'legacy-user-1',
      ),
      Message(
        id: 'legacy-tool-1',
        conversationId: _conversation.id,
        role: MessageRole.tool,
        content: 'legacy result',
        createdAt: DateTime.utc(2026, 10, 5, 10, 2),
        toolCallId: 'call_legacy_a',
        variantGroupId: 'legacy-turn',
        threadOrder: 1,
        parentMessageId: 'legacy-round-1',
      ),
      Message(
        id: 'legacy-answer',
        conversationId: _conversation.id,
        role: MessageRole.assistant,
        content: 'the legacy final answer',
        createdAt: DateTime.utc(2026, 10, 5, 10, 3),
        variantGroupId: 'legacy-turn',
        variantIndex: 1,
        threadOrder: 2,
        parentMessageId: 'legacy-tool-1',
      ),
      Message(
        id: 'legacy-user-2',
        conversationId: _conversation.id,
        role: MessageRole.user,
        content: 'and one more thing',
        createdAt: DateTime.utc(2026, 10, 5, 10, 4),
        variantGroupId: 'legacy-user-2',
        threadOrder: 3,
        parentMessageId: 'legacy-answer',
      ),
    ];
    // Every legacy row is active — the pre-consolidation convention.
    return legacyRows
        .map((m) => saved.lastWhere((s) => s.id == m.id, orElse: () => m))
        .toList();
  }

  @override
  Future<void> persistMessage(Message message) async {
    saved.add(message);
  }
}

class _EmptyEngineNotifier extends OnDeviceEngineNotifier {
  @override
  OnDeviceEngineState build() => const OnDeviceEngineState();
}

class _RemoteServerNotifier extends ActiveServerNotifier {
  @override
  Server? build() => _remoteServer;
}

class _EnabledMcpNotifier extends ChatMcpConfigNotifier {
  @override
  ChatMcpConfig build() => const ChatMcpConfig(enabled: true);
}

class _FakeConversationsNotifier extends conv.ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [_conversation];

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

class _TestChatBackgroundService extends ChatBackgroundService {
  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

class _TestSettingsNotifier extends SettingsNotifier {
  @override
  AppSettings build() =>
      AppSettings(resumeLastChat: false, autoGenerateTitle: false);
}

class _IdleVoiceModeNotifier extends VoiceModeNotifier {
  @override
  VoiceModeState build() => const VoiceModeState();
}
