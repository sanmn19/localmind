import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/chat_background_service_provider.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/services/chat_background_service.dart';
import 'package:localmind/core/services/device_tools_service.dart';
import 'package:localmind/features/chat/data/chat_service.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/message.dart'
    hide ToolCallData;
import 'package:localmind/features/chat/data/tools/mcp_tool_provider.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/data/tools/tool_registry.dart';
import 'package:localmind/features/chat/providers/chat_mcp_providers.dart';
import 'package:localmind/features/chat/providers/chat_notifier.dart';
import 'package:localmind/features/chat/providers/chat_params_providers.dart';
import 'package:localmind/features/chat/providers/chat_service_providers.dart';
import 'package:localmind/features/chat/providers/model_selection_providers.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/mcp/data/device_mcp_server.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/on_device/providers/on_device_providers.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/servers/providers/server_providers.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/features/voice_mode/providers/voice_mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Task: an `apps.screenshot` tool result carries the captured image file.
// The follow-up request must carry that image to the vision-capable model,
// so the chat layer inserts a USER-role message with the screenshot as an
// attachment (saved + injected, no generation):
//
//   round 1: model emits tool call `apps.screenshot`
//            -> executes -> result contains `[path=<file>]`
//            -> user row `📸 [screenshot of <package or screen>]` attached
//   round 2 (the follow-up): model answers from the image
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SharedPreferences.setMockInitialValues({});

  test(
    'a completed apps.screenshot inserts the image as a user attachment row',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final chatService = _ScriptedChatService(rounds: _screenshotRounds());
      final attachmentsDir = _tempAttachmentsDir();
      final shotFile = _writeFakePng();

      final screenshotService = _RecordingScreenshotService(
        'Screenshot captured (3 screens stitched)\n'
        '[path=${shotFile.path}]\n'
        '[frames=3]',
      );
      final manager = McpServerManager();
      await manager.addDeviceServer(
        DeviceServices(
          contacts: _FakeDeviceContacts(),
          launcher: _FakeDeviceLauncher(),
          screenshot: screenshotService,
        ),
      );
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
            ToolRegistry(providers: [McpToolProvider(serverManager: manager)]),
          ),
          chatBackgroundServiceProvider.overrideWithValue(
            _TestChatBackgroundService(),
          ),
          settingsProvider.overrideWith(_DeviceToolsSettingsNotifier.new),
          voiceModeProvider.overrideWith(_IdleVoiceModeNotifier.new),
          conv.conversationsProvider.overrideWith(
            _FakeConversationsNotifier.new,
          ),
          storageDirectoryProvider.overrideWith((_) async => attachmentsDir),
        ],
      );
      addTearDown(container.dispose);

      final notifier =
          container.read(chatProvider.notifier) as _TestChatNotifier;
      await container.read(conv.conversationsProvider.future);
      await notifier.loadConversation(_conversation);
      await notifier.sendMessage('what am I looking at? use screenshot');
      await _drain();
      await _awaitChainCompletion(container);

      // The tool really executed through the device server dispatch.
      expect(screenshotService.calls, hasLength(1));
      expect(screenshotService.calls.single.package, 'com.example.app');
      expect(screenshotService.calls.single.scroll, isFalse);

      // A NEW user-role row with the screenshot attached got inserted,
      // persisted, and carried into the follow-up request messages.
      final attachedUserRows = notifier.saved
          .where(
            (m) =>
                m.role == MessageRole.user &&
                m.attachmentPaths != null &&
                m.attachmentPaths!.isNotEmpty,
          )
          .toList();
      expect(attachedUserRows, hasLength(1));
      final attachRow = attachedUserRows.single;
      expect(attachRow.content, '📸 [screenshot of com.example.app]');
      final savedPath = attachRow.attachmentPaths!.single;
      expect(savedPath, endsWith('.png'));
      expect(
        File(savedPath).existsSync(),
        isTrue,
        reason: 'the attachment must be copied into the attachments dir',
      );

      // The follow-up request mirrors the database and carries the row.
      expect(chatService.requests, hasLength(2));
      final followUpRequest = chatService.requests.last;
      final requestRows = followUpRequest
          .where(
            (m) =>
                m.role == MessageRole.user &&
                m.attachmentPaths != null &&
                m.attachmentPaths!.isNotEmpty,
          )
          .toList();
      expect(requestRows, hasLength(1));
      expect(requestRows.single.attachmentPaths!.single, savedPath);
      final finalReply = notifier.saved.lastWhere(
        (m) => m.role == MessageRole.assistant && m.content.contains('12.0'),
      );
      expect(finalReply.status, MessageStatus.complete);
      expect(container.read(chatProvider).isStreaming, isFalse);
    },
  );

  test(
    'a screenshot result without a path marker inserts nothing extra',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final chatService = _ScriptedChatService(rounds: _screenshotRounds());
      final attachmentsDir = _tempAttachmentsDir();

      final screenshotService = _RecordingScreenshotService(
        'ERROR: enable LocalMind\'s Screen Capture in Accessibility settings',
      );
      final manager = McpServerManager();
      await manager.addDeviceServer(
        DeviceServices(
          contacts: _FakeDeviceContacts(),
          launcher: _FakeDeviceLauncher(),
          screenshot: screenshotService,
        ),
      );
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
            ToolRegistry(providers: [McpToolProvider(serverManager: manager)]),
          ),
          chatBackgroundServiceProvider.overrideWithValue(
            _TestChatBackgroundService(),
          ),
          settingsProvider.overrideWith(_DeviceToolsSettingsNotifier.new),
          voiceModeProvider.overrideWith(_IdleVoiceModeNotifier.new),
          conv.conversationsProvider.overrideWith(
            _FakeConversationsNotifier.new,
          ),
          storageDirectoryProvider.overrideWith((_) async => attachmentsDir),
        ],
      );
      addTearDown(container.dispose);

      final notifier =
          container.read(chatProvider.notifier) as _TestChatNotifier;
      await container.read(conv.conversationsProvider.future);
      await notifier.loadConversation(_conversation);
      await notifier.sendMessage('what am I looking at? use screenshot');
      await _drain();
      await _awaitChainCompletion(container);

      expect(screenshotService.calls, hasLength(1));
      final attachedUserRows = notifier.saved
          .where(
            (m) =>
                m.role == MessageRole.user &&
                m.attachmentPaths != null &&
                m.attachmentPaths!.isNotEmpty,
          )
          .toList();
      expect(
        attachedUserRows,
        isEmpty,
        reason: 'no [path=…] marker → nothing may be attached',
      );
      final finalReply = notifier.saved.lastWhere(
        (m) => m.role == MessageRole.assistant && m.content.contains('12.0'),
      );
      expect(finalReply.status, MessageStatus.complete);
    },
  );

  test('a path marker whose file is gone inserts nothing extra', () async {
    final prefs = await SharedPreferences.getInstance();
    final chatService = _ScriptedChatService(rounds: _screenshotRounds());
    final attachmentsDir = _tempAttachmentsDir();

    final screenshotService = _RecordingScreenshotService(
      'Screenshot captured (1 screen)\n'
      '[path=/nonexistent/tool_42.png]\n'
      '[frames=1]',
    );
    final manager = McpServerManager();
    await manager.addDeviceServer(
      DeviceServices(
        contacts: _FakeDeviceContacts(),
        launcher: _FakeDeviceLauncher(),
        screenshot: screenshotService,
      ),
    );
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
          ToolRegistry(providers: [McpToolProvider(serverManager: manager)]),
        ),
        chatBackgroundServiceProvider.overrideWithValue(
          _TestChatBackgroundService(),
        ),
        settingsProvider.overrideWith(_DeviceToolsSettingsNotifier.new),
        voiceModeProvider.overrideWith(_IdleVoiceModeNotifier.new),
        conv.conversationsProvider.overrideWith(_FakeConversationsNotifier.new),
        storageDirectoryProvider.overrideWith((_) async => attachmentsDir),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(chatProvider.notifier) as _TestChatNotifier;
    await container.read(conv.conversationsProvider.future);
    await notifier.loadConversation(_conversation);
    await notifier.sendMessage('what am I looking at? use screenshot');
    await _drain();
    await _awaitChainCompletion(container);

    final attachedUserRows = notifier.saved
        .where(
          (m) =>
              m.role == MessageRole.user &&
              m.attachmentPaths != null &&
              m.attachmentPaths!.isNotEmpty,
        )
        .toList();
    expect(
      attachedUserRows,
      isEmpty,
      reason: 'a parsed-but-missing file must not become an attachment',
    );
    final finalReply = notifier.saved.lastWhere(
      (m) => m.role == MessageRole.assistant && m.content.contains('12.0'),
    );
    expect(finalReply.status, MessageStatus.complete);
  });
}

/// Round 1 emits the screenshot tool call, round 2 the final answer.
List<List<ChatResponse>> _screenshotRounds() => [
  [
    const ChatResponse(
      type: ChatResponseType.toolCall,
      toolCall: ToolCallData(
        tool: 'apps.screenshot',
        arguments: {'package': 'com.example.app'},
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

Directory _tempAttachmentsDir() {
  final dir = Directory.systemTemp.createTempSync('localmind_ss_attach');
  Directory('${dir.path}${Platform.pathSeparator}attachments').createSync();
  return Directory('${dir.path}${Platform.pathSeparator}attachments');
}

File _writeFakePng() {
  final dir = Directory.systemTemp.createTempSync('localmind_ss_capture');
  final file = File(
    '${dir.path}${Platform.pathSeparator}tool_${DateTime.now().microsecondsSinceEpoch}.png',
  );
  // A valid-enough image byte blob: only the path/extension matter here.
  file.writeAsBytesSync([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  return file;
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
  id: 'conversation-screenshot-attach',
  title: 'Screenshot attach',
  createdAt: DateTime.utc(2026, 10, 5),
  updatedAt: DateTime.utc(2026, 10, 5),
  mcpEnabled: true,
);

class _RecordingScreenshotService implements DeviceScreenshotService {
  _RecordingScreenshotService(this.next);

  final calls = <({String? package, bool scroll})>[];
  String next;

  @override
  Future<String> screenshot({String? package, bool scroll = false}) async {
    calls.add((package: package, scroll: scroll));
    return next;
  }
}

class _FakeDeviceLauncher implements DeviceAppLauncher {
  @override
  Future<String> composeEmail({
    required String to,
    required String subject,
    required String body,
    List<String>? cc,
  }) async => 'compose:$to';

  @override
  Future<String> open(String target) async => 'open:$target';

  @override
  Future<List<DeviceAppEntry>> listInstalled() async => const [];
}

class _FakeDeviceContacts implements DeviceContactsService {
  @override
  Future<List<ContactSummary>> search(String query) async => const [];

  @override
  Future<List<ContactSummary>> byEmail(String email) async => const [];

  @override
  Future<List<ContactSummary>> byPhone(String phone) async => const [];
}

/// Serves the scripted rounds (see [ChatNotifier]): the chain is one
/// message-stream per round, exactly like the real `_runAssistantStream`.
class _ScriptedChatService implements ChatService {
  _ScriptedChatService({required this.rounds});

  final List<List<ChatResponse>> rounds;
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
        content: 'what am I looking at? use screenshot',
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

class _DeviceToolsSettingsNotifier extends SettingsNotifier {
  @override
  AppSettings build() => AppSettings(
    mcpEnabled: true,
    newChatMcpEnabled: true,
    resumeLastChat: false,
    autoGenerateTitle: false,
    deviceToolsEnabled: true,
  );
}

class _IdleVoiceModeNotifier extends VoiceModeNotifier {
  @override
  VoiceModeState build() => const VoiceModeState();
}
