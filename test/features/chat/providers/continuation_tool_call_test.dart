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
import 'package:localmind/features/chat/utils/message_variants.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/on_device/providers/on_device_providers.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/servers/providers/server_providers.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/features/voice_mode/providers/voice_mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Regression test for the multi-hop tool chain bug:
//
//   search -> fetch -> answer style chains stall because the continuation
//   stream (the follow-up after tool results are fed back, built by
//   `_runAssistantStream`) silently DROPPED any NEW tool call the model
//   emitted. Only the FIRST send executed tool calls.
//
// Scripted rounds:
//   round 1: model emits tool call `calc.add`, then done
//   round 2 (the follow-up): model emits ANOTHER tool call `calc.multiply`,
//                            then done
//   round 3: model emits the final answer text
//
// Both tool calls must be executed through the approval path and the final
// answer must complete the conversation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SharedPreferences.setMockInitialValues({});

  test(
    'executes tool calls emitted by the continuation stream and finishes the chain',
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

      final notifier =
          container.read(chatProvider.notifier) as _TestChatNotifier;
      await container.read(conv.conversationsProvider.future);
      await notifier.loadConversation(_conversation);
      await notifier.sendMessage('use your calc tools');
      await _drain();

      // Round 1 (`calc.add`): calc tools always auto-approve (user spec),
      // so the execution runs without surfacing `pendingToolApproval`.
      expect(
        await _grantNextApproval(container, expectApproval: false),
        isFalse,
        reason: 'calc.add is always auto-approved; no dialog may appear',
      );
      await _drain();

      // Round 2 runs on the continuation stream (`_runAssistantStream`).
      // calc.multiply is also always auto-approved, so the second hop must
      // complete without surfacing an approval dialog either.
      expect(
        await _grantNextApproval(container, expectApproval: false),
        isFalse,
        reason: 'calc.multiply is always auto-approved; no dialog either',
      );
      await _drain();

      await _awaitChainCompletion(container);

      // Both tool calls executed, in order.
      expect(
        calcProvider.executions,
        ['calc.add', 'calc.multiply'],
        reason: 'both the initial and the continuation tool call must run',
      );
      // Each executed turn persisted its tool-role result message.
      final toolMessages = notifier.saved
          .where((m) => m.role == MessageRole.tool)
          .toList();
      expect(toolMessages, hasLength(2));
      // The chain produced the final assistant answer.
      final finalReply = notifier.saved.lastWhere(
        (m) => m.role == MessageRole.assistant && m.content.contains('12.0'),
      );
      expect(finalReply.status, MessageStatus.complete);
      expect(container.read(chatProvider).isStreaming, isFalse);
      expect(container.read(chatProvider).pendingToolApproval, isNull);
      expect(container.read(activeGenerationsProvider), isEmpty);
    },
  );

  /// Regression for the multi-round tool-chain UI bug: every continuation
  /// round used to open its own variant "page" (1/N .. N/N pager) on top of
  /// the turn's answer, and the resolver kept landing on the first
  /// tool-result row of the turn instead of the newest round.
  ///
  /// The chain must behave like ONE turn: tool-chain rounds are timeline
  /// history, not variants. After a 2-round chain
  /// (`calc.add` -> `calc.multiply` -> final answer):
  ///   * exactly the LAST assistant row of the turn stays `isActiveVariant`,
  ///   * the resolver surfaces only that tail for the turn,
  ///   * the follow-up requests still carry every round's
  ///     assistant(tool_calls) + tool(result) protocol pair.
  test('treats tool-chain rounds as timeline steps, not variants', () async {
    final chatService = _ScriptedChatService();
    final calcProvider = _CalcToolProvider();
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
        chatProvider.overrideWith(_TestChatNotifier.new),
        chatServiceProvider.overrideWithValue(chatService),
        chatServiceFactoryProvider.overrideWithValue((_) => chatService),
        chatParamsProvider.overrideWithValue(ChatParameters.defaults()),
        chatMcpConfigProvider.overrideWith(_EnabledMcpNotifier.new),
        toolRegistryProvider.overrideWithValue(
          ToolRegistry(providers: [calcProvider]),
        ),
        chatBackgroundServiceProvider.overrideWithValue(
          _TestChatBackgroundService(),
        ),
        settingsProvider.overrideWith(_TestSettingsNotifier.new),
        voiceModeProvider.overrideWith(_IdleVoiceModeNotifier.new),
        conv.conversationsProvider.overrideWith(_FakeConversationsNotifier.new),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(chatProvider.notifier) as _TestChatNotifier;
    await container.read(conv.conversationsProvider.future);
    await notifier.loadConversation(_conversation);
    await notifier.sendMessage('use your calc tools');
    await _drain();
    expect(
      await _grantNextApproval(container, expectApproval: false),
      isFalse,
      reason: 'calc calls auto-approve without a dialog',
    );
    await _drain();
    expect(
      await _grantNextApproval(container, expectApproval: false),
      isFalse,
      reason: 'calc calls auto-approve without a dialog',
    );
    await _drain();
    await _awaitChainCompletion(container);

    // Mirror the database: latest persisted copy of each row wins.
    final rows = <String, Message>{};
    for (final saved in notifier.saved) {
      rows[saved.id] = saved;
    }

    final tail = rows.values
        .where(
          (m) => m.role == MessageRole.assistant && m.content.contains('12.0'),
        )
        .single;
    final chainGroupId = MessageVariants.groupId(tail);
    final chainAssistants = rows.values
        .where((m) => m.role == MessageRole.assistant)
        .where((m) => MessageVariants.groupId(m) == chainGroupId)
        .toList();

    expect(chainAssistants, hasLength(3), reason: '2 tool rounds + final tail');
    final activeAssistants = chainAssistants
        .where((m) => m.isActiveVariant)
        .map((m) => m.id)
        .toSet();
    expect(
      activeAssistants,
      {tail.id},
      reason:
          'only the chain tail (the round that answers the turn) may stay '
          'active — earlier rounds are timeline steps, not variants',
    );

    // The resolver surfaces only the tail for this turn's group.
    final state = container.read(chatProvider);
    final resolved = MessageVariants.resolveActiveTimeline(state.allMessages);
    final resolvedChain = resolved
        .where((m) => MessageVariants.groupId(m) == chainGroupId)
        .toList();
    expect(
      resolvedChain.map((m) => m.id),
      {tail.id},
      reason: 'resolver shows ONLY the newest round of the turn',
    );

    // Follow-up requests keep the assistant(tool_calls) + tool(result)
    // pairing for BOTH rounds (the flip side of collapsing variants: the
    // chain context must not leak away from the API payload).
    final requests = chatService.requests;
    expect(requests, hasLength(3));
    final lastRequest = requests[2];
    final toolRows = lastRequest
        .where((m) => m.role == MessageRole.tool)
        .toList();
    expect(toolRows, hasLength(2));
    final callRows = lastRequest
        .where((m) => m.role == MessageRole.assistant && m.toolCalls != null)
        .toList();
    expect(callRows, hasLength(2));
    // Each pair ordered: assistant(tool_calls) immediately followed by its
    // tool result, round 1 then round 2.
    final a1Row = callRows.first;
    final c2Row = callRows.last;
    expect(a1Row.toolCalls!.map((tc) => tc.id), [toolRows.first.toolCallId]);
    expect(c2Row.toolCalls!.map((tc) => tc.id), [toolRows.last.toolCallId]);
    final a1Idx = lastRequest.indexOf(a1Row);
    expect(lastRequest[a1Idx + 1], toolRows.first);
    final c2Idx = lastRequest.indexOf(c2Row);
    expect(lastRequest[c2Idx + 1], toolRows.last);
  });
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
    expectApproval
        ? const Duration(seconds: 10)
        : const Duration(milliseconds: 400),
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
  id: 'conversation-multi-hop',
  title: 'Multi-hop',
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
    ToolDefinition(
      name: 'calc.multiply',
      description: 'Multiplies two numbers',
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
      case 'calc.multiply':
        return ToolExecutionResult.success('${a * b}');
      default:
        return ToolExecutionResult.failure('unknown calc tool');
    }
  }
}

/// Serves one scripted response list per chat completion: round 1 emits a
/// tool call, round 2 (the follow-up) emits ANOTHER tool call, round 3 the
/// final answer. Any extra round is a bug guard and just terminates.
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
        type: ChatResponseType.toolCall,
        toolCall: ToolCallData(
          tool: 'calc.multiply',
          arguments: {'a': 2, 'b': 3},
        ),
      ),
      const ChatResponse(type: ChatResponseType.done),
    ],
    [
      const ChatResponse(
        type: ChatResponseType.message,
        content: 'The result is 12.0.',
      ),
      const ChatResponse(type: ChatResponseType.done),
    ],
  ];

  final List<List<Message>> requests = [];
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
    requests.add(messages);
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

class _TestChatBackgroundService extends ChatBackgroundService {
  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
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
