import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/logger/app_logger.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/ask_local/ask_local_notifier.dart';
import 'package:localmind/features/ask_local/data/ask_local_card_bootstrap.dart';
import 'package:localmind/features/ask_local/data/ask_local_card_channel.dart';
import 'package:localmind/features/ask_local/data/ask_local_conversation_service.dart';
import 'package:localmind/features/ask_local/data/ask_local_payload.dart';
import 'package:localmind/features/ask_local/views/ask_local_card.dart';
import 'package:localmind/features/chat/data/chat_service.dart' hide ToolCallData;
import 'package:localmind/features/chat/data/chat_service.dart' as cs
    show ToolCallData;
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/mcp_integration.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/mail/mail_mcp_server.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:logger/logger.dart';

// Card widget tests (task 4): the compact card surface renders the
// delivered ask (thumbnail present vs the null-capture guard), the send
// interaction streams rows in-card, the approval chips settle in-card,
// close runs the card-channel close and re-capture swaps the capture.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Log.attachOutput(_DiscardingLogOutput());
  });

  testWidgets('renders header, input and the capture thumbnail for a capture '
      'carrying delivery', (tester) async {
    final harness = _CardWidgetHarness(script: ['answer']);
    addTearDown(harness.container.dispose);
    await harness.pump(tester, delivery: _bootstrapDelivery());

    expect(find.byKey(const ValueKey('ask_local_card_header')), findsOneWidget);
    expect(find.byKey(const ValueKey('ask_local_card_input')), findsOneWidget);
    expect(find.byKey(const ValueKey('ask_local_card_send')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ask_local_capture_thumbnail')),
      findsOneWidget,
    );
  });

  testWidgets('no-capture delivery renders the thumbnail GUARD (placeholder '
      'icon, no image widget)', (tester) async {
    final harness = _CardWidgetHarness(script: ['answer']);
    addTearDown(harness.container.dispose);
    await harness.pump(
      tester,
      delivery: AskLocalCardDelivery(
        payload: const AskLocalRequestPayload(selectedText: 'selection only'),
        deliveryId: 'req-nc',
        bootstrap: _bootstrapPayload(),
      ),
    );

    expect(
      find.byKey(const ValueKey('ask_local_capture_thumbnail')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('ask_local_selected_text')),
      findsOneWidget,
    );
  });

  testWidgets('send streams the user row + streamed answer in-card',
      (tester) async {
    final harness = _CardWidgetHarness(script: ['Hello world']);
    addTearDown(harness.container.dispose);
    await harness.pump(tester, delivery: _bootstrapDelivery());

    await tester.enterText(
      find.byKey(const ValueKey('ask_local_card_input')),
      'What changed here?',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ask_local_card_send')));
    await tester.pumpAndSettle();
    final state = harness.container.read(askLocalCardNotifierProvider);
    expect(state.isStreaming, isFalse, reason: 'failure: ${state.failure}');
    expect(state.history, hasLength(2), reason: 'failure: ${state.failure}');
    expect(state.history.last.content, 'Hello world');
    expect(find.textContaining('What changed here?'), findsOneWidget);
  });

  testWidgets('approval chip: deny settles denied, never executes',
      (tester) async {
    final remoteCalls = <String>[];
    final harness = _CardWidgetHarness(
      rounds: [
        [
          'thinking about it…',
          cs.ToolCallData(tool: 'mail.send', arguments: {'to': 'a@b.c'}),
        ],
        ['ok, moving on'],
      ],
      onRemoteExecute: (name, args) async {
        remoteCalls.add(name);
        return (success: true, output: 'sent', error: null);
      },
    );
    addTearDown(harness.container.dispose);
    await harness.pump(tester, delivery: _bootstrapDelivery());

    await tester.enterText(
      find.byKey(const ValueKey('ask_local_card_input')),
      'mail her',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ask_local_card_send')));
    await _pumpUntil(
      tester,
      () => harness.container
          .read(askLocalCardNotifierProvider)
          .pendingApproval != null,
    );

    expect(
      find.byKey(const ValueKey('ask_local_approval_chip')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('ask_local_chip_deny')));
    await tester.pumpAndSettle();

    expect(remoteCalls, isEmpty);
    final state = harness.container.read(askLocalCardNotifierProvider);
    expect(state.pendingApproval, isNull);
    expect(
      find.byKey(const ValueKey('ask_local_approval_chip')),
      findsNothing,
    );
    final feedback = state.history.firstWhere(
      (row) => row.role == MessageRole.tool,
    );
    expect(feedback.content, contains('denied by the user'));
  });

  testWidgets('approval chip: approve forwards the tool to the main engine',
      (tester) async {
    final remoteCalls = <String>[];
    final harness = _CardWidgetHarness(
      rounds: [
        [
          'sending…',
          cs.ToolCallData(tool: 'mail.send', arguments: {'to': 'a@b.c'}),
        ],
        ['sent'],
      ],
      onRemoteExecute: (name, args) async {
        remoteCalls.add(name);
        return (success: true, output: 'mail sent', error: null);
      },
    );
    addTearDown(harness.container.dispose);
    await harness.pump(tester, delivery: _bootstrapDelivery());

    await tester.enterText(
      find.byKey(const ValueKey('ask_local_card_input')),
      'mail her',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ask_local_card_send')));
    await _pumpUntil(
      tester,
      () => harness.container
          .read(askLocalCardNotifierProvider)
          .pendingApproval != null,
    );

    await tester.tap(find.byKey(const ValueKey('ask_local_chip_approve')));
    await tester.pumpAndSettle();

    expect(remoteCalls, ['mail.send']);
    final state = harness.container.read(askLocalCardNotifierProvider);
    final feedback = state.history.firstWhere(
      (row) => row.role == MessageRole.tool,
    );
    expect(feedback.content, 'mail sent');
  });

  testWidgets('close X runs the card-channel close; re-capture swaps the '
      'round capture', (tester) async {
    final closes = <bool>[];
    final harness = _CardWidgetHarness(
      script: ['answer'],
      onClose: () async {
        closes.add(true);
        return true;
      },
    );
    addTearDown(harness.container.dispose);
    await harness.pump(tester, delivery: _bootstrapDelivery());

    await tester.tap(find.byKey(const ValueKey('ask_local_card_close')));
    await tester.pumpAndSettle();
    expect(closes, [true]);

    var captureCalls = 0;
    final recaptures = _CardWidgetHarness(
      script: [],
      onCaptureNow: () async {
        captureCalls++;
        return '/staged/ask_local_2.png';
      },
    );
    addTearDown(recaptures.container.dispose);
    await recaptures.pump(tester, delivery: _bootstrapDelivery());
    await tester.tap(find.byKey(const ValueKey('ask_local_card_recapture')));
    await tester.pumpAndSettle();

    expect(captureCalls, 1);
    expect(
      recaptures.container
          .read(askLocalCardNotifierProvider)
          .capturePath,
      '/staged/ask_local_2.png',
    );
  });
}

const _selectedText = 'Ledger line about the screen';

Future<void> _pumpUntil(WidgetTester tester, bool Function() probe) async {
  for (var i = 0; i < 60; i++) {
    if (probe()) return;
    await tester.pump(const Duration(milliseconds: 25));
  }
}

AskLocalCardDelivery _bootstrapDelivery() => AskLocalCardDelivery(
      payload: const AskLocalRequestPayload(
        selectedText: _selectedText,
        capturePath: '/staged/ask_local_1.png',
      ),
      deliveryId: 'req-1',
      bootstrap: _bootstrapPayload(),
    );

AskLocalCardBootstrapPayload _bootstrapPayload() {
  final settings = AppSettings().copyWith(defaultSystemPrompt: 'persona');
  return bootstrapFromMap(<String, Object?>{
    'requestId': 'req-1',
    'storeDir': '/docs/localmind_objectbox',
    'modelId': 'model-x',
    'server': AskLocalCardServerWire(
      id: 'srv-1',
      name: 'remote',
      type: 'openAICompatible',
      host: '10.0.0.2',
      port: 8000,
    ).toWire(),
    'params': chatParametersToWire(ChatParameters.defaults()),
    'toolDefs': [
      AskLocalCardToolDefWire(
        name: 'mail.send',
        description: 'send mail',
        inputSchema: const <String, dynamic>{},
        providerType: 'mcp',
        providerRef: mailMcpServerUrl,
      ).toWire(),
    ],
    'settings': settings.toJson(),
  })!;
}

class _CardWidgetHarness {
  _CardWidgetHarness({
    List<Object>? script,
    List<List<Object>>? rounds,
    this.onRemoteExecute,
    this.onCaptureNow,
    this.onClose,
  }) {
    _service = _FakeCardChatService(rounds ?? [(script ?? const [])]);
    container = ProviderContainer(

      overrides: [
        askLocalCardEnvProvider.overrideWithValue(
          AskLocalCardEnv(
            conversationService: _FakeConversationService(),
            serviceFor: (bootstrap) => _service,
            remoteExecuteTool: onRemoteExecute,
            captureNow: onCaptureNow,
            closeCard: onClose,
          ),
        ),
        askLocalCardNotifierProvider.overrideWith(
          () => _HarnessCardNotifier(recorded: recorded),
        ),
      ],
    );
  }

  late final _FakeCardChatService _service;
  final Future<({bool success, String output, String? error})> Function(
    String, Map<String, dynamic>)? onRemoteExecute;
  final Future<String?> Function()? onCaptureNow;
  final Future<bool> Function()? onClose;
  late final ProviderContainer container;

  Future<void> pump(
    WidgetTester tester, {
    required AskLocalCardDelivery delivery,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const AskLocalCardApp(),
      ),
    );
    await container
        .read(askLocalCardNotifierProvider.notifier)
        .applyDelivery(delivery);
    await tester.pumpAndSettle();
  }

  final List<Message> recorded = [];
}

class _FakeCardChatService implements ChatService {
  _FakeCardChatService(List<List<Object>> rounds) : _rounds = rounds;

  final List<List<Object>> _rounds;
  int _round = 0;
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
  }) {
    requests.add(messages);
    final round =
        _round < _rounds.length ? _rounds[_round] : const <Object>[];
    _round++;
    return Stream.fromIterable([
      for (final entry in round)
        entry is cs.ToolCallData
            ? ChatResponse(type: ChatResponseType.toolCall, toolCall: entry)
            : ChatResponse(
                type: ChatResponseType.message,
                content: entry as String,
              ),
    ]);
  }

  @override
  void cancelStream() {}
}

class _DiscardingLogOutput extends LogOutput {
  @override
  void output(OutputEvent event) {}
}

class _FakeConversationService implements AskLocalConversationService {
  final Conversation conversation = Conversation(
    id: 'ask-local-conv',
    title: askLocalConversationTitle,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    specialKind: askLocalConversationKind,
  );

  @override
  Future<Conversation> ensure() async => conversation;
}

class _HarnessCardNotifier extends AskLocalCardNotifier {
  _HarnessCardNotifier({required this.recorded});

  final List<Message> recorded;

  @override
  Future<List<String>> stageCapture(
    AskLocalCardBootstrapPayload bootstrap,
  ) async {
    if (state.capturePath == null) return const [];
    return ['/staged/copied.png'];
  }

  @override
  Future<void> persistRow(Message message) async => recorded.add(message);

  @override
  Future<List<Message>> loadRows(String conversationId) async =>
      List.of(recorded);
}
