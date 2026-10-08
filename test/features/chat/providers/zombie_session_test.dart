import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/chat_background_service_provider.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/services/chat_background_service.dart';
import 'package:localmind/features/chat/data/chat_service.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/message.dart'
    hide ToolCallData;
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/data/tools/tool_registry.dart';
import 'package:localmind/features/chat/providers/chat_mcp_providers.dart';
import 'package:localmind/features/chat/providers/chat_notifier.dart';
import 'package:localmind/features/chat/providers/chat_params_providers.dart';
import 'package:localmind/features/chat/providers/chat_service_providers.dart';
import 'package:localmind/features/chat/providers/model_selection_providers.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/on_device/providers/on_device_providers.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/servers/providers/server_providers.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/features/voice_mode/providers/voice_mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Regression test for the zombie generation-session bug:
//
//   When a streamed turn ends with tool calls, the session whose stream is
//   DONE hands the chain over to `_sendFollowupWithToolResults`, which
//   begins its OWN session via `_beginSession` and streams the follow-up.
//   Both post-stream call sites then `return` early on
//   `CollectedToolCallsOutcome.followUpStarted` WITHOUT ending the session
//   whose stream already completed. The retired session must be ended once
//   the handoff has happened — otherwise stale state (streaming flags,
//   active generations, background service claims) survives after the
//   chain finishes.
//
// Scripted rounds:
//   round 1: model emits tool call `calc.add`, then done
//   round 2: model emits the final answer text
//
// After the full chain completes, all streaming/generation state must be
// cleaned up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SharedPreferences.setMockInitialValues({});

  test(
    'ends the initial generation session once the follow-up owns the chain',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final chatService = _ScriptedChatService();
      final calcProvider = _CalcToolProvider();
      late ProviderContainer container;

      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
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
          chatProvider.overrideWith(_TestChatNotifier.new),
          chatServiceProvider.overrideWithValue(chatService),
          chatServiceFactoryProvider.overrideWithValue((_) => chatService),
          chatParamsProvider.overrideWithValue(ChatParameters.defaults()),
          chatMcpConfigProvider.overrideWith(_EnabledMcpNotifier.new),
          toolRegistryProvider.overrideWithValue(
            ToolRegistry(providers: [calcProvider]),
          ),
          chatBackgroundServiceProvider.overrideWithValue(
            _RecordingChatBackgroundService(),
          ),
          settingsProvider.overrideWith(_TestSettingsNotifier.new),
          voiceModeProvider.overrideWith(_IdleVoiceModeNotifier.new),
          conv.conversationsProvider.overrideWith(
            _FakeConversationsNotifier.new,
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier =
          container.read(chatProvider.notifier) as _TestChatNotifier;
      await container.read(conv.conversationsProvider.future);
      await notifier.loadConversation(_conversation);
      await notifier.sendMessage('use your calc tools');
      await _drain();

      expect(
        await _grantNextApproval(container, expectApproval: false),
        isFalse,
        reason: 'calc.add is always auto-approved; no dialog may appear',
      );
      await _drain();

      await _awaitChainCompletion(container);

      expect(calcProvider.executions, [
        'calc.add',
      ], reason: 'the tool call must run');
      expect(container.read(chatProvider).isStreaming, isFalse);
      expect(container.read(chatProvider).pendingToolApproval, isNull);
      expect(container.read(isStreamingProvider), isFalse);
      expect(container.read(activeGenerationsProvider), isEmpty);
    },
  );
}

Future<void> _drain([int iterations = 40]) async {
  for (var i = 0; i < iterations; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Auto-approved tool calls never surface a dialog, so callers assert a
/// short, bounded no-approval window instead of the grant path ({expectApproval: false}).
Future<bool> _grantNextApproval(
  ProviderContainer container, {
  bool expectApproval = true,
}) async {
  final deadline = DateTime.now().add(
    expectApproval ? const Duration(seconds: 10) : const Duration(milliseconds: 400),
  );
  while (DateTime.now().isBefore(deadline)) {
    final pending = container.read(chatProvider).pendingToolApproval;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(true);
      await _drain();
      return true;
    }
    await Future<void>.delayed(Duration.zero);
  }
  return false;
}

Future<void> _awaitChainCompletion(ProviderContainer container) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    if (!container.read(chatProvider).isStreaming &&
        container.read(activeGenerationsProvider).isEmpty) {
      await _drain();
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  // No [fail] here — the behavioral assertions diagnose what stalled.
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
  id: 'conversation-zombie-session',
  title: 'Zombie session',
  createdAt: DateTime.utc(2026, 10, 5),
  updatedAt: DateTime.utc(2026, 10, 5),
  mcpEnabled: true,
);

class _CalcToolProvider implements ToolProvider {
  final List<String> executions = [];

  @override
  Future<List<ToolDefinition>> listTools() async => const [
    ToolDefinition(
      name: 'calc.add',
      description: 'Adds two numbers',
      inputSchema: {},
      providerType: ToolProviderType.builtIn,
    ),
  ];

  @override
  Future<ToolExecutionResult> execute(
    String name,
    Map<String, dynamic> args,
  ) async {
    executions.add(name);
    final a = (args['a'] as num?) ?? 0;
    final b = (args['b'] as num?) ?? 0;
    switch (name) {
      case 'calc.add':
        return ToolExecutionResult.success('${a + b}');
      default:
        return ToolExecutionResult.failure('unknown calc tool');
    }
  }
}

/// Serves one scripted response list per chat completion: round 1 emits a
/// tool call, round 2 the final answer. Any extra round is a bug guard and
/// just terminates.
class _ScriptedChatService implements ChatService {
  final List<List<ChatResponse>> rounds = [
    [
      const ChatResponse(
        type: ChatResponseType.toolCall,
        toolCall: ToolCallData(tool: 'calc.add', arguments: {'a': 1, 'b': 2}),
      ),
      const ChatResponse(type: ChatResponseType.done),
    ],
    [
      const ChatResponse(
        type: ChatResponseType.message,
        content: 'The result is 3.0.',
      ),
      const ChatResponse(type: ChatResponseType.done),
    ],
  ];

  int roundIndex = 0;
  int cancelCount = 0;

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
    final round = roundIndex++;
    for (final response
        in round < rounds.length
            ? rounds[round]
            : [
                const ChatResponse(
                  type: ChatResponseType.message,
                  content: 'UNEXPECTED_EXTRA_ROUND',
                ),
                const ChatResponse(type: ChatResponseType.done),
              ]) {
      yield response;
    }
  }

  @override
  void cancelStream() {
    cancelCount++;
  }
}

class _TestChatNotifier extends ChatNotifier {
  final List<Message> saved = [];

  @override
  ChatState build() => const ChatState();

  @override
  Future<List<Message>> loadConversationMessages(String conversationId) async {
    final base = <Message>[
      Message(
        id: 'user-1',
        conversationId: _conversation.id,
        role: MessageRole.user,
        content: 'use your calc tools',
        createdAt: DateTime.utc(2026, 10, 5),
      ),
      Message(
        id: 'assistant-1',
        conversationId: _conversation.id,
        role: MessageRole.assistant,
        content: '',
        createdAt: DateTime.utc(2026, 10, 5),
      ),
    ];
    // Later saves replace the seeded copy, like the database would.
    return base.map((message) {
      return saved.lastWhere((s) => s.id == message.id, orElse: () => message);
    }).toList();
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

class _RecordingChatBackgroundService extends ChatBackgroundService {
  int startCount = 0;
  int stopCount = 0;

  @override
  Future<void> start() async {
    startCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }
}

class _TestSettingsNotifier extends SettingsNotifier {
  @override
  AppSettings build() => AppSettings(
    mcpEnabled: true,
    newChatMcpEnabled: true,
    resumeLastChat: false,
    autoGenerateTitle: false,
  );
}

class _IdleVoiceModeNotifier extends VoiceModeNotifier {
  @override
  VoiceModeState build() => const VoiceModeState();
}
