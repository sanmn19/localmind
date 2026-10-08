import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/chat_background_service_provider.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/services/chat_background_service.dart';
import 'package:localmind/features/chat/data/chat_service.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/message.dart'
    hide ToolCallData;
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/data/tools/tool_event.dart';
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

// Regression tests for over-burning anonymous keyless web vendors:
//
//   A multi-hop tool chain (the follow-up tool rounds of ONE assistant
//   reply) can issue arbitrarily many web.search / web.fetch calls; the
//   keyless ring (exa/parallel/DDG) runs out of quota after ~10 calls and
//   the whole turn degrades.
//
// A per-CHAIN turn budget now lives in the notifier's tool path: the first
// 3 searches / 6 fetches of one reply run, excess calls are SKIPPED (never
// touching the network) and rendered as failed tool events whose error text
// is also fed back to the model as a tool-role result so it wraps the turn
// up. Consecutive rounds of the SAME reply share the budget — the chain
// token is the assistant row's variantGroupId, inherited by every
// continuation round — while a brand-new send mints a fresh group and
// therefore a fresh budget.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SharedPreferences.setMockInitialValues({});

  test(
    'denies the 4th web.search of one chain with a budget failure event',
    () async {
      final harness = await _testHarness();
      harness.chat.rounds.addAll([
        ..._searchRounds(4),
        ..._answerRound('Answering with what I already found.'),
      ]);
      await harness.container.read(conv.conversationsProvider.future);
      await harness.notifier.loadConversation(_conversation);
      await harness.notifier.sendMessage('search the web please');
      await _drain();
      await _awaitChainCompletion(harness.container);

      expect(
        harness.web.executions,
        hasLength(3),
        reason:
            'exactly the budgeted 3 searches must execute; the 4th must '
            'never touch the network',
      );

      // The overdraw is rendered as a FAILED tool event carrying the copy.
      final skipEvents = _budgetSkipEvents(harness.notifier);
      expect(skipEvents, hasLength(1));
      expect(skipEvents.single.status, ToolEventStatus.failed);
      expect(skipEvents.single.toolName, 'web.search');
      expect(
        skipEvents.single.error,
        'web budget exhausted for this reply (searches 3/3, fetches 0/6). '
        'Answer with the results already fetched.',
      );

      // The failure is fed back the SAME way as completed results: a
      // tool-role row in the follow-up request, so the model can wrap up.
      final lastRequest = harness.chat.requests.last;
      expect(
        lastRequest
            .where((m) => m.role == MessageRole.tool)
            .where((m) => m.content.startsWith('web budget exhausted'))
            .toList(),
        hasLength(1),
      );

      // Round count: 3 executed searches + the denied round + the wrap-up.
      expect(harness.chat.requests, hasLength(5));
      expect(
        harness.notifier.saved.any(
          (m) =>
              m.role == MessageRole.assistant &&
              m.content.contains('Answering with what I already found.'),
        ),
        isTrue,
        reason: 'the model must produce the final answer after the budget cut',
      );
      expect(harness.container.read(chatProvider).isStreaming, isFalse);
      expect(harness.container.read(activeGenerationsProvider), isEmpty);
    },
  );

  test(
    'denies the 7th web.fetch of one chain, searches stay independent',
    () async {
      final harness = await _testHarness();
      harness.chat.rounds.addAll([
        ..._fetchRounds(7),
        ..._searchRound('fresh query'),
        ..._answerRound('Answering after the fetch limit.'),
      ]);
      await harness.container.read(conv.conversationsProvider.future);
      await harness.notifier.loadConversation(_conversation);
      await harness.notifier.sendMessage('fetch some pages');
      await _drain();
      await _awaitChainCompletion(harness.container);

      // 6 fetches run; the 7th is denied; the search is STILL allowed —
      // the two counters are fully independent.
      expect(
        harness.web.executions.where((e) => e.startsWith('web.fetch')),
        hasLength(6),
      );
      expect(harness.web.executions.where((e) => e.startsWith('web.search')), [
        'web.search:fresh query',
      ]);

      final skipEvents = _budgetSkipEvents(harness.notifier);
      expect(skipEvents, hasLength(1));
      expect(skipEvents.single.toolName, 'web.fetch');
      expect(
        skipEvents.single.error,
        'web budget exhausted for this reply (searches 0/3, fetches 6/6). '
        'Answer with the results already fetched.',
      );
      // The failure text reaches the model through the tool-role path too.
      expect(
        harness.chat.requests.last
            .where((m) => m.role == MessageRole.tool)
            .where((m) => m.content.startsWith('web budget exhausted'))
            .toList(),
        hasLength(1),
      );
    },
  );

  test(
    'a brand-new send mints a fresh chain and restarts the budget',
    () async {
      final harness = await _testHarness();
      harness.chat.rounds.addAll([
        ..._searchRounds(4),
        ..._answerRound('First reply done.'),
      ]);
      await harness.container.read(conv.conversationsProvider.future);
      await harness.notifier.loadConversation(_conversation);
      await harness.notifier.sendMessage('first send');
      await _drain();
      await _awaitChainCompletion(harness.container);
      expect(harness.web.executions, hasLength(3));

      // The next send creates a different variantGroupId → the budget
      // restarts: chain 2's very first search executes instead of being
      // denied by chain 1's leftover counter.
      harness.chat.rounds.addAll([
        ..._searchRound('fresh query'),
        ..._answerRound('Second reply done.'),
      ]);
      await harness.notifier.sendMessage('second send');
      await _drain();
      await _awaitChainCompletion(harness.container);

      expect(
        harness.web.executions,
        [
          'web.search:search 1',
          'web.search:search 2',
          'web.search:search 3',
          'web.search:fresh query',
        ],
        reason: 'the new chain must start from 0/3 searches',
      );
      expect(
        harness.notifier.saved.any(
          (m) =>
              m.role == MessageRole.assistant &&
              m.content.contains('Second reply done.'),
        ),
        isTrue,
      );
    },
  );
}

Future<_TestHarness> _testHarness() async {
  final prefs = await SharedPreferences.getInstance();
  final chatService = _ScriptedChatService();
  final web = _WebToolProvider();
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
      toolRegistryProvider.overrideWithValue(ToolRegistry(providers: [web])),
      chatBackgroundServiceProvider.overrideWithValue(
        _TestChatBackgroundService(),
      ),
      settingsProvider.overrideWith(_WebEnabledSettingsNotifier.new),
      voiceModeProvider.overrideWith(_IdleVoiceModeNotifier.new),
      conv.conversationsProvider.overrideWith(_FakeConversationsNotifier.new),
    ],
  );
  addTearDown(container.dispose);
  final notifier = container.read(chatProvider.notifier) as _TestChatNotifier;
  return _TestHarness(
    container: container,
    notifier: notifier,
    chat: chatService,
    web: web,
  );
}

class _TestHarness {
  final ProviderContainer container;
  final _TestChatNotifier notifier;
  final _ScriptedChatService chat;
  final _WebToolProvider web;

  _TestHarness({
    required this.container,
    required this.notifier,
    required this.chat,
    required this.web,
  });
}

/// All failed budget-skip events the chain persisted, regardless of round.
/// Saved rows are deduped by id (latest copy wins) mirroring the database,
/// because each round is persisted twice: once with toolCalls and once as
/// the demoted inactive copy.
List<ToolEvent> _budgetSkipEvents(_TestChatNotifier notifier) {
  final rows = <String, Message>{};
  for (final saved in notifier.saved) {
    rows[saved.id] = saved;
  }
  return rows.values
      .expand((m) => m.toolEvents ?? const <ToolEvent>[])
      .where((e) => (e.error ?? '').startsWith('web budget exhausted'))
      .toList();
}

/// Rounds of `web.search` tool calls; the chain has ONE search per round
/// (the notifier dedupes collected calls by tool name within a round).
List<List<ChatResponse>> _searchRounds(int searchCount) => [
  for (var i = 1; i <= searchCount; i++) _oneRoundOfSearch('search $i'),
];

List<List<ChatResponse>> _searchRound(String query) => [
  _oneRoundOfSearch(query),
];

List<ChatResponse> _oneRoundOfSearch(String query) => [
  ChatResponse(
    type: ChatResponseType.toolCall,
    toolCall: ToolCallData(tool: 'web.search', arguments: {'query': query}),
  ),
  const ChatResponse(type: ChatResponseType.done),
];

List<List<ChatResponse>> _fetchRounds(int fetchCount) => [
  for (var i = 1; i <= fetchCount; i++)
    [
      ChatResponse(
        type: ChatResponseType.toolCall,
        toolCall: ToolCallData(
          tool: 'web.fetch',
          arguments: {'url': 'https://example.com/$i'},
        ),
      ),
      const ChatResponse(type: ChatResponseType.done),
    ],
];

List<List<ChatResponse>> _answerRound(String content) => [
  [
    ChatResponse(type: ChatResponseType.message, content: content),
    const ChatResponse(type: ChatResponseType.done),
  ],
];

Future<void> _drain([int iterations = 40]) async {
  for (var i = 0; i < iterations; i++) {
    await Future<void>.delayed(Duration.zero);
  }
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
  createdAt: DateTime.utc(2026, 10, 7),
  lastConnectedAt: DateTime.utc(2026, 10, 7),
  status: ConnectionStatus.connected,
);

final _conversation = Conversation(
  id: 'conversation-web-budget',
  title: 'Web budget',
  createdAt: DateTime.utc(2026, 10, 7),
  updatedAt: DateTime.utc(2026, 10, 7),
  mcpEnabled: true,
);

/// In-process web MCP stand-in: advertises `web.search` / `web.fetch` with
/// the local web server's providerRef so the auto-approval path sees local
/// web tools, and records every executed call with its main argument.
class _WebToolProvider implements ToolProvider {
  final List<String> executions = [];

  @override
  Future<List<ToolDefinition>> listTools() async => [
    ToolDefinition(
      name: 'web.search',
      description: 'Search the web',
      inputSchema: {},
      providerType: ToolProviderType.mcp,
      providerRef: webMcpServerUrl,
    ),
    ToolDefinition(
      name: 'web.fetch',
      description: 'Fetch a page',
      inputSchema: {},
      providerType: ToolProviderType.mcp,
      providerRef: webMcpServerUrl,
    ),
  ];

  @override
  Future<ToolExecutionResult> execute(
    String name,
    Map<String, dynamic> args,
  ) async {
    final arg = args['query'] ?? args['url'];
    executions.add('$name:${arg ?? '?'}');
    return ToolExecutionResult.success('result for ${arg ?? name}');
  }
}

/// Serves one scripted response list per chat completion round. Extra
/// rounds hit the bug-guard terminator.
class _ScriptedChatService implements ChatService {
  final List<List<ChatResponse>> rounds = [];

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
        content: 'search the web please',
        createdAt: DateTime.utc(2026, 10, 7),
      ),
      Message(
        id: 'assistant-1',
        conversationId: _conversation.id,
        role: MessageRole.assistant,
        content: '',
        createdAt: DateTime.utc(2026, 10, 7),
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

class _WebEnabledSettingsNotifier extends SettingsNotifier {
  @override
  AppSettings build() => AppSettings(
    mcpEnabled: true,
    newChatMcpEnabled: true,
    resumeLastChat: false,
    autoGenerateTitle: false,
    webToolsEnabled: true,
  );
}

class _IdleVoiceModeNotifier extends VoiceModeNotifier {
  @override
  VoiceModeState build() => const VoiceModeState();
}
