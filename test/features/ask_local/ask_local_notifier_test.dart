import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/logger/app_logger.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/ask_local/ask_local_notifier.dart';
import 'package:localmind/features/ask_local/data/ask_local_card_bootstrap.dart';
import 'package:localmind/features/ask_local/data/ask_local_card_channel.dart';
import 'package:localmind/features/ask_local/data/ask_local_conversation_service.dart';
import 'package:localmind/features/ask_local/data/ask_local_payload.dart';
import 'package:localmind/features/chat/data/chat_service.dart' hide ToolCallData;
import 'package:localmind/features/chat/data/chat_service.dart' as cs
    show ToolCallData;
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/mcp_integration.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/mail/mail_mcp_server.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:logger/logger.dart';

// Card pipeline tests (task 4): delivery idempotence, the send rounds
// (framer header + streamed rows), in-card approval chips (deny = the
// denial string the model receives; approve = the main-engine forward),
// the closed-event reap and the degraded no-bootstrap failure.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Log.attachOutput(_DiscardingLogOutput());
  });

  test('payload→send→rows: framer header, staged attachment, streamed answer',
      () async {
    final service = _FakeCardChatService(script: ['Hel', 'lo world']);
    final harness = _CardTestHarness(chatService: service);
    addTearDown(harness.container.dispose);

    final notifier = harness.container.read(askLocalCardNotifierProvider.notifier);
    await notifier.applyDelivery(_bootstrapDelivery());
    await notifier.send('What does this screen show?');

    final state = harness.container.read(askLocalCardNotifierProvider);
    expect(state.isStreaming, isFalse);
    expect(state.transcript, isEmpty);
    expect(state.history, hasLength(2));

    final userRow = state.history.first;
    expect(userRow.role, MessageRole.user);
    expect(
      userRow.content,
      'From screen: "$_selectedText"\n\nWhat does this screen show?',
    );
    expect(userRow.attachmentPaths, ['/staged/copied.png']);
    final assistantRow = state.history.last;
    expect(assistantRow.role, MessageRole.assistant);
    expect(assistantRow.content, 'Hello world');

    final wire = service.requests.single;
    expect(wire.first.role, MessageRole.system);
    expect(wire.first.content, 'persona framing');
    expect(wire.last.role, MessageRole.user);
    expect(wire.last.content, contains('screen show?'));
  });

  test('auto-approvable family runs remotely and feeds the feedback row to '
      'the follow-up round', () async {
    final service = _FakeCardChatService(rounds: [
      ['searching…', cs.ToolCallData(tool: 'web.search', arguments: {'query': 'rive'})],
      ['done — rive runs locally'],
    ]);
    final remoteCalls = <String>[];
    final harness = _CardTestHarness(
      chatService: service,
      onRemoteExecute: (name, args) async {
        remoteCalls.add(name);
        return (success: true, output: 'Rive docs found', error: null);
      },
    );
    addTearDown(harness.container.dispose);

    final notifier = harness.container.read(askLocalCardNotifierProvider.notifier);
    await notifier.applyDelivery(_bootstrapDelivery(webTools: true));
    await notifier.send('search rive');

    expect(remoteCalls, ['web.search']);

    final state = harness.container.read(askLocalCardNotifierProvider);
    expect(state.isStreaming, isFalse);
    expect(state.history, hasLength(4));
    final feedback = state.history[2];
    expect(feedback.role, MessageRole.tool);
    expect(feedback.content, 'Rive docs found');
    expect(state.history[1].toolCalls, isNotNull);
    expect(state.history.last.content, 'done — rive runs locally');

    expect(service.requests, hasLength(2));
    final secondWire = service.requests[1];
    expect(
      secondWire.any((row) => row.role == MessageRole.tool),
      isTrue,
    );
  });

  test('dialog-worthy tool parks an in-card chip; DENY feeds the denial '
      'string and never executes', () async {
    final service = _FakeCardChatService(rounds: [
      [
        'running shell…',
        cs.ToolCallData(tool: 'mail.send', arguments: {'to': 'a@b.c'}),
      ],
      ['ok, moving on'],
    ]);
    final remoteCalls = <String>[];
    final harness = _CardTestHarness(
      chatService: service,
      onRemoteExecute: (name, args) async {
        remoteCalls.add(name);
        return (success: true, output: 'ran', error: null);
      },
    );
    addTearDown(harness.container.dispose);

    final notifier = harness.container.read(askLocalCardNotifierProvider.notifier);
    await notifier.applyDelivery(_bootstrapDelivery());
    final sending = notifier.send('run doom');
    final parked = await _waitForChip(harness.container);
    expect(parked.pendingApproval, isNotNull);
    expect(parked.pendingApproval!.toolName, 'mail.send');

    notifier.denyPending();
    await sending;

    expect(remoteCalls, isEmpty);
    final state = harness.container.read(askLocalCardNotifierProvider);
    expect(state.pendingApproval, isNull);
    final feedback = state.history.firstWhere(
      (row) => row.role == MessageRole.tool,
    );
    expect(feedback.content, contains('denied by the user'));
    expect(state.history.last.content, 'ok, moving on');
  });

  test('dialog-worthy tool APPROVED: chip settle executes via the main '
      'engine forward', () async {
    final service = _FakeCardChatService(rounds: [
      [
        'sending…',
        cs.ToolCallData(tool: 'mail.send', arguments: {'to': 'a@b.c'}),
      ],
      ['sent'],
    ]);
    final remoteCalls = <(String, String?)>[];
    final harness = _CardTestHarness(
      chatService: service,
      onRemoteExecute: (name, args) async {
        remoteCalls.add((name, args['to']));
        return (success: true, output: 'mail sent', error: null);
      },
    );
    addTearDown(harness.container.dispose);

    final notifier = harness.container.read(askLocalCardNotifierProvider.notifier);
    await notifier.applyDelivery(_bootstrapDelivery());
    final sending = notifier.send('mail her');
    final parked = await _waitForChip(harness.container);
    expect(parked.pendingApproval, isNotNull);

    notifier.approvePending();
    await sending;

    expect(remoteCalls, hasLength(1));
    expect(remoteCalls.single.$1, 'mail.send');
    expect(remoteCalls.single.$2, 'a@b.c');
    final state = harness.container.read(askLocalCardNotifierProvider);
    expect(state.pendingApproval, isNull);
    final feedback = state.history.firstWhere(
      (row) => row.role == MessageRole.tool,
    );
    expect(feedback.content, 'mail sent');
  });

  test('re-delivery idempotence: the SAME delivery id never resets state',
      () async {
    final harness = _CardTestHarness(chatService: _FakeCardChatService(script: ['a']));
    addTearDown(harness.container.dispose);

    final notifier = harness.container.read(askLocalCardNotifierProvider.notifier);
    final delivery = _bootstrapDelivery();
    await notifier.applyDelivery(delivery);
    final stateAfterFirst = harness.container.read(askLocalCardNotifierProvider);

    await notifier.applyDelivery(delivery);
    final stateAfterSecond = harness.container.read(askLocalCardNotifierProvider);

    expect(identical(stateAfterFirst, stateAfterSecond), isTrue);
  });

  test('a NEW delivery replaces the active prompt (fresh round)', () async {
    final service = _FakeCardChatService(script: ['resp']);
    final harness = _CardTestHarness(chatService: service);
    addTearDown(harness.container.dispose);

    final notifier = harness.container.read(askLocalCardNotifierProvider.notifier);
    await notifier.applyDelivery(_bootstrapDelivery());
    await notifier.send('first question');
    expect(
      harness.container.read(askLocalCardNotifierProvider).transcript,
      isEmpty,
    );

    await notifier.applyDelivery(_bootstrapDelivery(requestId: 'req-2'));
    final swapped = harness.container.read(askLocalCardNotifierProvider);
    expect(swapped.delivery!.deliveryId, 'req-2');
    expect(swapped.transcript, isEmpty);
    expect(swapped.history, hasLength(2));
    expect(swapped.capturePath, '/staged/ask_local_1.png');
  });

  test('closed-event reap cancels the streaming round and settles chips',
      () async {
    final controller = StreamController<ChatResponse>();
    final service = _StreamingUntilClosedChatService(controller);
    final harness = _CardTestHarness(chatService: service);
    addTearDown(harness.container.dispose);

    final notifier = harness.container.read(askLocalCardNotifierProvider.notifier);
    await notifier.applyDelivery(_bootstrapDelivery());
    final sending = notifier.send('long stream please');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      harness.container.read(askLocalCardNotifierProvider).isStreaming,
      isTrue,
    );

    notifier.reapClosed();
    await sending;

    final state = harness.container.read(askLocalCardNotifierProvider);
    expect(state.isStreaming, isFalse);
    expect(state.pendingApproval, isNull);
    expect(service.cancelCount, 1);
    expect(state.history, hasLength(2));
    expect(state.history.last.stopReason, 'cancelled');
  });

  test('a delivery swap mid-stream keeps the dead round rows out of the '
      'new round transcript', () async {
    final controller = StreamController<ChatResponse>();
    final service = _StreamingUntilClosedChatService(controller);
    final harness = _CardTestHarness(chatService: service);
    addTearDown(harness.container.dispose);

    final notifier = harness.container.read(askLocalCardNotifierProvider.notifier);
    await notifier.applyDelivery(_bootstrapDelivery());
    final sending = notifier.send('stream and stall');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await notifier.applyDelivery(_bootstrapDelivery(requestId: 'req-2'));
    // The swap cancels the exchange; the service closes its stream on
    // cancel; the dead exchange finalizes into the store only.
    await sending;
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final state = harness.container.read(askLocalCardNotifierProvider);
    expect(state.transcript, isEmpty);
    expect(state.delivery!.deliveryId, 'req-2');
    expect(state.failure, isNull);
    // The aborted exchange still persisted its user row (+ its cancelled
    // partial assistant) into the store.
    expect(
      harness.persisted.every(
        (row) => row.conversationId == 'ask-local-conv',
      ),
      isTrue,
    );
    expect(harness.persisted.length, greaterThanOrEqualTo(2));
  });

  test('degraded delivery (no bootstrap) fails the send typed, row-less',
      () async {
    final harness =
        _CardTestHarness(chatService: _FakeCardChatService(script: []));
    addTearDown(harness.container.dispose);

    final notifier = harness.container.read(askLocalCardNotifierProvider.notifier);
    await notifier.applyDelivery(
      AskLocalCardDelivery(
        payload: const AskLocalRequestPayload(
          selectedText: 'text',
          capturePath: '/staged/ask_local_1.png',
        ),
        deliveryId: 'req-degraded',
      ),
    );
    await notifier.send('anything');
    final state = harness.container.read(askLocalCardNotifierProvider);
    expect(state.isStreaming, isFalse);
    expect(state.failure, isNotNull);
    expect(state.hasTarget, isFalse);
    expect(harness.persisted, isEmpty);
  });

  test('assembleCardWire: system framing from params, empty error rows '
      'dropped, user row last', () {
    final bootstrap = _bootstrapPayload();
    final userRow = _message(id: 'u1', role: MessageRole.user, content: 'hello');
    final rows = [
      _message(id: 'a1', role: MessageRole.assistant, content: 'answer'),
      _message(
        id: 'a2',
        role: MessageRole.assistant,
        content: '',
        status: MessageStatus.error,
        errorMessage: 'boom',
      ),
      _message(id: 'r1', role: MessageRole.tool, content: 'result'),
    ];

    final wire = AskLocalCardNotifier.assembleCardWire(rows, userRow, bootstrap);

    expect(wire, hasLength(4));
    expect(wire.last.id, 'u1');
    expect(wire.first.role, MessageRole.system);
    expect(wire.any((row) => row.id == 'a2'), isFalse);
  });

  group('card delivery codec', () {
    test('bootstrap envelope round-trips', () {
      final envelope = bootstrapToWire(_bootstrapPayload());
      final decoded = bootstrapFromMap(envelope);
      expect(decoded, isNotNull);
      expect(decoded!.requestId, 'req-1');
      expect(decoded.storeDir, '/docs/localmind_objectbox');
      expect(decoded.modelId, 'model-x');
      expect(decoded.params.systemPrompt, 'persona framing');
      expect(decoded.toolDefs, hasLength(2));
      expect(decoded.toolDefs[0].name, 'web.search');
      expect(decoded.toolDefs[0].providerRef, webMcpServerUrl);
      expect(decoded.settingsJson, isNotEmpty);
    });

    test('malformed bootstrap decodes null (degraded card)', () {
      expect(bootstrapFromMap(<String, Object?>{}), isNull);
      expect(bootstrapFromMap('nope'), isNull);
      expect(
        bootstrapFromMap(<String, Object?>{
          'storeDir': '/x',
          'modelId': 'm',
          'server': {'host': 'h', 'port': 1, 'type': 'openAICompatible'},
        }),
        isNull,
      );
    });

    test('delivery id prefers requestId, falls back composite', () {
      final withId = AskLocalCardDelivery.fromMap(<String, Object?>{
        'selectedText': 'pick',
        'requestId': 'req-9',
      });
      expect(withId!.deliveryId, 'req-9');

      final composite = AskLocalCardDelivery.fromMap(<String, Object?>{
        'selectedText': 'pick',
      });
      expect(composite!.deliveryId, 'pick\x00');
      expect(composite.deliveryId, isNot(withId.deliveryId));
    });
  });
}

const _selectedText = 'Ledger line about the screen';

Future<AskLocalCardState> _waitForChip(ProviderContainer container) async {
  for (var i = 0; i < 50; i++) {
    final state = container.read(askLocalCardNotifierProvider);
    if (state.pendingApproval != null) return state;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return container.read(askLocalCardNotifierProvider);
}

Message _message({
  required String id,
  required MessageRole role,
  required String content,
  MessageStatus status = MessageStatus.complete,
  String? errorMessage,
  List<String>? attachmentPaths,
  int threadOrder = 0,
  List<ToolCallData>? toolCalls,
}) =>
    Message(
      id: id,
      conversationId: 'conv',
      role: role,
      content: content,
      createdAt: DateTime.now(),
      status: status,
      errorMessage: errorMessage,
      attachmentPaths: attachmentPaths,
      threadOrder: threadOrder,
      toolCalls: toolCalls,
    );

AskLocalCardDelivery _bootstrapDelivery({
  String requestId = 'req-1',
  bool webTools = false,
}) =>
    AskLocalCardDelivery(
      payload: const AskLocalRequestPayload(
        selectedText: _selectedText,
        capturePath: '/staged/ask_local_1.png',
      ),
      deliveryId: requestId,
      bootstrap: _bootstrapPayload(webTools: webTools),
    );

AskLocalCardBootstrapPayload _bootstrapPayload({bool webTools = false}) {
  final settings = AppSettings().copyWith(
    webToolsEnabled: webTools,
    defaultSystemPrompt: 'persona framing',
  );
  return bootstrapFromMap(
    <String, Object?>{
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
      'params': chatParametersToWire(
        ChatParameters.defaults().copyWith(systemPrompt: 'persona framing'),
      ),
      'toolDefs': [
        AskLocalCardToolDefWire(
          name: 'web.search',
          description: 'search',
          inputSchema: const <String, dynamic>{},
          providerType: 'mcp',
          providerRef: webMcpServerUrl,
        ).toWire(),
        AskLocalCardToolDefWire(
          name: 'mail.send',
          description: 'send mail',
          inputSchema: const <String, dynamic>{},
          providerType: 'mcp',
          providerRef: mailMcpServerUrl,
        ).toWire(),
      ],
      'settings': settings.toJson(),
    },
  )!;
}

/// Streams a fixed script; each [sendMessage] call consumes the NEXT round's
/// script — one call per tool round, fork-loop parity.
class _FakeCardChatService implements ChatService {
  _FakeCardChatService({List<Object>? script, List<List<Object>>? rounds})
      : _script = rounds ?? [script ?? const <Object>[]];

  final List<List<Object>> _script;
  int _round = 0;
  final List<List<Message>> requests = [];
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
  }) {
    requests.add(messages);
    final round =
        _round < _script.length ? _script[_round] : const <Object>[];
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
  void cancelStream() => cancelCount++;
}

class _StreamingUntilClosedChatService implements ChatService {
  _StreamingUntilClosedChatService(this._controller);

  final StreamController<ChatResponse> _controller;
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
  }) {
    _controller.add(
      const ChatResponse(type: ChatResponseType.processing),
    );
    return _controller.stream;
  }

  @override
  void cancelStream() {
    cancelCount++;
    _controller.close();
  }
}

class _DiscardingLogOutput extends LogOutput {
  @override
  void output(OutputEvent event) {}
}

class _FakeConversationService implements AskLocalConversationService {
  @override
  Future<Conversation> create() async => conversation;

  @override
  Future<Conversation> resolve(String? conversationId) async => conversation;


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

/// Harness: fake rows loads/saves (host tests cannot run libobjectbox) +
/// no-op capture staging.
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

class _CardTestHarness {
  _CardTestHarness({
    required ChatService chatService,
    Future<({bool success, String output, String? error})> Function(
      String, Map<String, dynamic>)? onRemoteExecute,
  }) : persisted = [] {
    container = ProviderContainer(
      overrides: [
        askLocalCardEnvProvider.overrideWithValue(
          AskLocalCardEnv(
            conversationService: _FakeConversationService(),
            serviceFor: (bootstrap) => chatService,
            remoteExecuteTool: onRemoteExecute,
            captureNow: () async => '/staged/ask_local_1.png',
          ),
        ),
        askLocalCardNotifierProvider.overrideWith(
          () => _HarnessCardNotifier(recorded: persisted),
        ),
      ],
    );
  }

  final List<Message> persisted;
  late final ProviderContainer container;
}
