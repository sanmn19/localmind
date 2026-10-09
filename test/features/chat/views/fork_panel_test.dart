import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/features/chat/data/chat_service.dart'
    hide ToolCallData;
import 'package:localmind/features/chat/data/fork_service.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/fork_anchor.dart';
import 'package:localmind/features/chat/data/models/mcp_integration.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/providers/chat_providers.dart';
import 'package:localmind/features/chat/providers/fork_chat_notifier.dart';
import 'package:localmind/features/chat/providers/fork_panel_overlay.dart';
import 'package:localmind/features/chat/views/components/chat_bubble/assistant_bubble.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Task 5 of the selection-fork-chats feature: the anchored fork panel is a
// real chat surface floating over the main feed. It streams through the
// forkChatNotifierProvider slots Task 3 owns; the composer-focus auto-close
// bridge (UX 6a) folds it away without deleting fork data. The band/chip +
// overlay-entry fan-out is Task 4's assistant_bubble wiring, so the panel
// is exercised through the real overlay host path.

class _FakeForkService extends ForkService {
  _FakeForkService(this.seed) : super();

  final List<ForkAnchor> seed;
  int anchorsForCalls = 0;
  int deleteCalls = 0;
  /// persist / delete order probe: a proper mid-stream delete must settle
  /// the notifier's finalize (persist:assistant) BEFORE deleteFork runs.
  final List<String> events = [];

  @override
  Future<List<ForkAnchor>> anchorsFor(String mainConversationId) async {
    anchorsForCalls++;
    return List.of(seed);
  }

  @override
  Future<bool> deleteFork(String anchorId) async {
    deleteCalls++;
    events.add('delete:$anchorId');
    seed.removeWhere((anchor) => anchor.id == anchorId);
    return true;
  }
}

class _SeededMainChatNotifier extends ChatNotifier {
  _SeededMainChatNotifier({required this.seed});

  final List<Message> seed;

  @override
  ChatState build() =>
      ChatState(messages: List.of(seed), allMessages: List.of(seed));
}

class _SandboxForkChatNotifier extends ForkChatNotifier {
  _SandboxForkChatNotifier({
    required this.onPersist,
    this.seedTurns = const [],
    super.forkConversationId = '',
  });

  final void Function(Message message) onPersist;
  /// Persisted fork rows the fake disk-load returns — simulates what a
  /// restart-reopened fork reads from ObjectBox (final-review fix 1).
  final List<Message> seedTurns;

  @override
  Future<List<Message>> loadForkMessages(String forkConversationId) =>
      Future.value(List.of(seedTurns));

  @override
  Future<void> persistMessage(Message message) => Future.sync(() {
        onPersist(message);
      });
}

class _StreamingChatService implements ChatService {
  _StreamingChatService(this.chunks);

  final List<String> chunks;

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
    for (final chunk in chunks) {
      yield ChatResponse(type: ChatResponseType.message, content: chunk);
    }
    yield const ChatResponse(type: ChatResponseType.done);
  }

  @override
  void cancelStream() {}
}

/// Never finishes on its own; [cancelStream] is the closer. Lets the test
/// hold the fork exchange in the streaming phase while the panel is deleted.
class _HangingChatService implements ChatService {
  _HangingChatService();

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
    unawaited(_controller?.close());
  }
}

Message _assistantMessage(String content) {
  return Message(
    id: 'msg-done',
    conversationId: 'conv-1',
    role: MessageRole.assistant,
    content: content,
    createdAt: DateTime(2026, 10, 8, 12),
    status: MessageStatus.complete,
  );
}

Message _mainUserRow() {
  return Message(
    id: 'u-1',
    conversationId: 'conv-1',
    role: MessageRole.user,
    content: 'who?',
    createdAt: DateTime(2026, 10, 8, 11),
    status: MessageStatus.complete,
  );
}

ForkAnchor _seedAnchor({String id = 'anchor-seed'}) {
  return ForkAnchor(
    id: id,
    mainConversationId: 'conv-1',
    anchorMessageId: 'msg-done',
    selectedText: 'Ada Lovelace wrote it',
    forkConversationId: 'fork-seed',
    createdAt: DateTime(2026, 10, 8, 12),
  );
}

Server _remoteServer() {
  return Server(
    id: 'remote',
    name: 'Remote',
    type: ServerType.ollama,
    host: '127.0.0.1',
    port: 11434,
    createdAt: DateTime(2026, 10, 5),
    lastConnectedAt: DateTime(2026, 10, 5),
    status: ConnectionStatus.connected,
  );
}

Widget _buildHarness({
  required SharedPreferences prefs,
  required _FakeForkService service,
  required ChatService chatService,
  void Function(Message)? onPersist,
  FocusNode? composerFocusNode,
  List<Message> forkSeed = const [],
  List<Message>? mainSeed,
}) {
  final mainTimeline = mainSeed ?? [ _mainUserRow(), _assistantMessage('Ada Lovelace wrote it')];
  Widget body;
  if (composerFocusNode == null) {
    body = MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ListView(
          children: [
            const SizedBox(height: 40),
            AssistantBubble(
              message: _assistantMessage('Ada Lovelace wrote it'),
              isStreaming: false,
            ),
          ],
        ),
      ),
    );
  } else {
    // Mirrors chat_screen's wiring: the bridge listens on the composer's
    // focus node and folds the panel away on focus gain.
    body = MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ForkPanelAutoCloseBridge(
          focusNode: composerFocusNode,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    const SizedBox(height: 40),
                    AssistantBubble(
                      message: _assistantMessage('Ada Lovelace wrote it'),
                      isStreaming: false,
                    ),
                  ],
                ),
              ),
              TextField(focusNode: composerFocusNode),
            ],
          ),
        ),
      ),
    );
  }
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      forkServiceProvider.overrideWithValue(service),
      activeChatTargetProvider.overrideWithValue(
        ActiveChatTarget(
          server: _remoteServer(),
          selectedModel: null,
          effectiveModelId: 'model',
          modelLabel: 'Model',
        ),
      ),
      chatParamsProvider.overrideWithValue(ChatParameters.defaults()),
      chatServiceFactoryProvider.overrideWithValue((_) => chatService),
      chatProvider.overrideWith(
        () => _SeededMainChatNotifier(seed: mainTimeline),
      ),
      forkChatNotifierProvider.overrideWith2(
        (forkConversationId) => _SandboxForkChatNotifier(
          forkConversationId: forkConversationId,
          onPersist: onPersist ?? (m) {},
          seedTurns: forkSeed,
        ),
      ),
    ],
    child: body,
  );
}

Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}

/// Lets the fork exchange walk through its async submit steps: each pump
/// flushes one batch of microtasks (fake services yield without real IO).
Future<void> _pumpStreaming(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets(
    'submit streams the fork exchange into the panel; main feed keeps its own turns',
    (tester) async {
      final service = _FakeForkService([_seedAnchor()]);
      final chatService = _StreamingChatService(const ['Hel', 'lo, how']);

      await tester.pumpWidget(
        _buildHarness(
          prefs: await _prefs(),
          service: service,
          chatService: chatService,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(kForkPanelContainerKey), findsOneWidget);
      expect(find.byKey(const ValueKey('fork_panel_input')), findsOneWidget);

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('fork_panel_input')),
      );
      expect(field.textInputAction, TextInputAction.send);

      await tester.enterText(
        find.byKey(const ValueKey('fork_panel_input')),
        'who wrote it?',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fork_panel_send')));
      await _pumpStreaming(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('who wrote it?'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(kForkPanelContainerKey)),
      );
      final state = container.read(forkChatNotifierProvider('fork-seed'));
      expect(state.isStreaming, isFalse);
      expect(state.failure, isNull);
      expect(state.transcript, hasLength(2));
      expect(state.transcript.first.content, contains('who wrote it?'));
      expect(state.transcript.last.content, 'Hello, how');

      // The main feed never gained fork turns.
      final main = container.read(chatProvider);
      expect(main.messages, hasLength(2));
      expect(main.isStreaming, isFalse);
    },
  );

  testWidgets(
    'focusing the main composer closes the panel without deleting; reopening shows the transcript',
    (tester) async {
      final service = _FakeForkService([_seedAnchor()]);
      final chatService = _StreamingChatService(const ['Hel', 'lo, how']);
      final composerFocus = FocusNode();

      await tester.pumpWidget(
        _buildHarness(
          prefs: await _prefs(),
          service: service,
          chatService: chatService,
          composerFocusNode: composerFocus,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('fork_panel_input')),
        'who wrote it?',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fork_panel_send')));
      await _pumpStreaming(tester);
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(kForkPanelContainerKey)),
      );

      // Main composer gains focus: the panel folds away without deleting.
      composerFocus.requestFocus();
      await tester.pumpAndSettle();
      expect(find.byKey(kForkPanelContainerKey), findsNothing);
      expect(container.read(forkPanelOverlayProvider).isOpen, isFalse);
      expect(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
        findsOneWidget,
      );
      expect(service.deleteCalls, 0);

      // Reopening reaches the same notifier slot, so the transcript is kept.
      await tester.tap(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(kForkPanelContainerKey), findsOneWidget);
      final reopenedState = container.read(
        forkChatNotifierProvider('fork-seed'),
      );
      expect(reopenedState.transcript, hasLength(2));
      expect(find.textContaining('who wrote it?'), findsOneWidget);
    },
  );

  testWidgets(
    'close button and outside tap both close the panel',
    (tester) async {
      final service = _FakeForkService([_seedAnchor()]);
      final chatService = _StreamingChatService(const []);

      await tester.pumpWidget(
        _buildHarness(
          prefs: await _prefs(),
          service: service,
          chatService: chatService,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(kForkPanelContainerKey), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('fork_panel_close')));
      await tester.pumpAndSettle();
      expect(find.byKey(kForkPanelContainerKey), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(kForkPanelContainerKey), findsOneWidget);
      await tester.tapAt(const Offset(760, 16));
      await tester.pumpAndSettle();
      expect(find.byKey(kForkPanelContainerKey), findsNothing);
    },
  );

  testWidgets(
    'deleting the fork invalidates the anchors and removes the band live',
    (tester) async {
      final service = _FakeForkService([_seedAnchor()]);
      final chatService = _StreamingChatService(const []);

      await tester.pumpWidget(
        _buildHarness(
          prefs: await _prefs(),
          service: service,
          chatService: chatService,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(kForkPanelContainerKey), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('fork_panel_delete')));
      await tester.pumpAndSettle();

      expect(find.byKey(kForkPanelContainerKey), findsNothing);
      expect(service.deleteCalls, 1);
      expect(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('fork_chip_anchor-seed')),
        findsNothing,
      );
      // The anchors family rebuilt after the deletion.
      expect(service.anchorsForCalls, greaterThan(1));
    },
  );

  testWidgets(
    'deleting while the fork reply streams cancels, settles the finalize, then deletes',
    (tester) async {
      final service = _FakeForkService([_seedAnchor()]);
      final chatService = _HangingChatService();
      final saved = <Message>[];

      await tester.pumpWidget(
        _buildHarness(
          prefs: await _prefs(),
          service: service,
          chatService: chatService,
          onPersist: (m) {
            saved.add(m);
            service.events.add('persist:${m.role.name}');
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('fork_panel_input')),
        'who wrote it?',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fork_panel_send')));
      await tester.pump(const Duration(milliseconds: 40));

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(kForkPanelContainerKey)),
      );
      expect(
        container.read(forkChatNotifierProvider('fork-seed')).isStreaming,
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('fork_panel_delete')));
      await tester.pumpAndSettle();

      expect(find.byKey(kForkPanelContainerKey), findsNothing);
      expect(service.deleteCalls, 1);
      expect(
        container.read(forkChatNotifierProvider('fork-seed')).isStreaming,
        isFalse,
      );
      // The cancelled partial was finalized before the delete and nothing
      // persists afterwards: the panel deletes only after the settle.
      final deleteMarker = service.events.lastIndexWhere(
        (e) => e.startsWith('delete:'),
      );
      expect(deleteMarker, isNonNegative);
      expect(
        service.events
            .skip(deleteMarker + 1)
            .where((e) => e.startsWith('persist:')),
        isEmpty,
      );
      final assistantRows = saved
          .where((m) => m.role == MessageRole.assistant)
          .toList();
      expect(assistantRows, hasLength(1));
      expect(assistantRows.single.stopReason, 'cancelled');
      expect(assistantRows.single.content, 'Hel');
      expect(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'restart-reopen shows the persisted fork transcript without submit '
    '(fix 1)',
    (tester) async {
      final service = _FakeForkService([_seedAnchor()]);
      // A fresh harness/container IS the restart: nothing submitted here.
      final chatService = _StreamingChatService(const []);
      final saved = <Message>[];

      await tester.pumpWidget(
        _buildHarness(
          prefs: await _prefs(),
          service: service,
          chatService: chatService,
          onPersist: saved.add,
          forkSeed: [
            Message(
              id: 'rk-u-1',
              conversationId: 'fork-seed',
              role: MessageRole.user,
              content: 'who wrote it?',
              createdAt: DateTime(2026, 10, 8, 10),
              status: MessageStatus.complete,
            ),
            Message(
              id: 'rk-a-1',
              conversationId: 'fork-seed',
              role: MessageRole.assistant,
              content: 'Persisted fork reply',
              createdAt: DateTime(2026, 10, 8, 10, 1),
              status: MessageStatus.complete,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(kForkPanelContainerKey), findsOneWidget);
      // The seeded transcript renders immediately — no submit required.
      expect(find.text('Persisted fork reply'), findsOneWidget);
      expect(find.textContaining('who wrote it?'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(kForkPanelContainerKey)),
      );
      final state = container.read(forkChatNotifierProvider('fork-seed'));
      expect(state.transcript, hasLength(2));
      expect(state.transcript.first.id, 'rk-u-1');
      expect(state.transcript.last.id, 'rk-a-1');
      // Seeding never re-persisted the seeded rows.
      expect(saved, isEmpty);
    },
  );

  testWidgets(
    'band tap on an anchor whose message left the active timeline shows the '
    'failure banner at open time (fix 3)',
    (tester) async {
      final service = _FakeForkService([_seedAnchor()]);
      final chatService = _StreamingChatService(const []);

      await tester.pumpWidget(
        _buildHarness(
          prefs: await _prefs(),
          service: service,
          chatService: chatService,
          // The fork's anchor row is missing from the resolved main
          // timeline (e.g. an inactive variant): mainTimelineUpTo is null.
          mainSeed: [_mainUserRow()],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
      );
      await tester.pumpAndSettle();

      // Panel opens straight into the typed rejection — no submit happened.
      expect(find.byKey(kForkPanelContainerKey), findsOneWidget);
      expect(
        find.textContaining("This selection's anchor is unavailable"),
        findsOneWidget,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(kForkPanelContainerKey)),
      );
      final state = container.read(forkChatNotifierProvider('fork-seed'));
      expect(state.failure, ForkChatNotifier.anchorUnavailableMessage);
      expect(state.transcript, isEmpty);
    },
  );
}
