import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/core/logger/app_logger.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/core/utils/uuid.dart';
import 'package:localmind/objectbox.g.dart';
import 'package:localmind/features/ask_local/data/ask_local_card_bootstrap.dart';
import 'package:localmind/features/ask_local/data/ask_local_card_channel.dart';
import 'package:localmind/features/ask_local/data/ask_local_conversation_service.dart';
import 'package:localmind/features/chat/data/chat_service.dart'
    hide ToolCallData;
import 'package:localmind/features/chat/data/chat_service.dart' as cs
    show ToolCallData;
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/data/tool_rounds.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/data/tools/tool_registry.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart'
    show shouldAutoApproveTool;
import 'package:localmind/features/chat/utils/attachment_helpers.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/mcp/data/terminal_mcp_server.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';

/// Completer-bound in-card approval record for ONE tool call — the
/// fork-panel [PendingForkApproval] shape copied card-local (the overlay
/// approves with completer chips; NO modal dialogs over other apps). The
/// card never touches the main feed's approval stream; an approved call
/// ships to the MAIN engine's registry via the card channel's
/// `askLocalExecuteTool`.
class PendingAskLocalApproval {
  PendingAskLocalApproval({
    required this.toolName,
    required this.arguments,
    required this.completer,
  });

  final String toolName;
  final Map<String, dynamic> arguments;
  final Completer<bool> completer;

  Future<bool> approve() => _settle(true);

  Future<bool> deny() => _settle(false);

  void settleAsDenied() => _settle(false);

  Future<bool> _settle(bool approved) {
    if (!completer.isCompleted) {
      completer.complete(approved);
    }
    return completer.future;
  }
}

class AskLocalCardState {
  const AskLocalCardState({
    this.delivery,
    this.history = const [],
    this.transcript = const [],
    this.isStreaming = false,
    this.modelLabel = 'No model',
    this.pendingApproval,
    this.failure,
    this.captureEffectivePath,
  });

  final AskLocalCardDelivery? delivery;
  final List<Message> history;
  final List<Message> transcript;
  final bool isStreaming;
  final String modelLabel;
  final PendingAskLocalApproval? pendingApproval;
  final String? failure;
  final String? captureEffectivePath;

  bool get hasTarget => delivery?.bootstrap != null;

  String? get capturePath =>
      captureEffectivePath ?? delivery?.payload.capturePath;

  AskLocalCardState copyWith({
    AskLocalCardDelivery? delivery,
    List<Message>? history,
    List<Message>? transcript,
    bool? isStreaming,
    String? modelLabel,
    String? failure,
    bool clearFailure = false,
    PendingAskLocalApproval? pendingApproval,
    bool clearPendingApproval = false,
    String? captureEffectivePath,
  }) {
    return AskLocalCardState(
      delivery: delivery ?? this.delivery,
      history: history ?? this.history,
      transcript: transcript ?? this.transcript,
      isStreaming: isStreaming ?? this.isStreaming,
      modelLabel: modelLabel ?? this.modelLabel,
      pendingApproval: clearPendingApproval
          ? null
          : (pendingApproval ?? this.pendingApproval),
      failure: clearFailure ? null : (failure ?? this.failure),
      captureEffectivePath:
          captureEffectivePath ?? this.captureEffectivePath,
    );
  }
}

class AskLocalCardEnv {
  const AskLocalCardEnv({
    required this.conversationService,
    this.serviceFor,
    this.remoteExecuteTool,
    this.captureNow,
    this.attachmentsDirOf,
    this.closeCard,
    this.resizeCard,
    this.openCardInput,
    this.dragCard,
  });

  final AskLocalConversationService conversationService;

  final ChatService? Function(AskLocalCardBootstrapPayload bootstrap)?
      serviceFor;

  final Future<({bool success, String output, String? error})> Function(
    String toolName,
    Map<String, dynamic> arguments,
  )? remoteExecuteTool;

  final Future<String?> Function()? captureNow;

  final Directory? Function()? attachmentsDirOf;

  final Future<bool> Function()? closeCard;

  final Future<bool> Function(double contentHeightDp)? resizeCard;

  /// Opens the host's transparent input activity (in-card typing happens
  /// there — a real activity window hosts the IME). Null under tests
  /// without a window host.
  final Future<bool> Function()? openCardInput;

  /// Header-drag deltas for the movable surface (dp); null under tests
  /// without a window host.
  final Future<bool> Function(double dx, double dy)? dragCard;
}

final askLocalCardEnvProvider = Provider<AskLocalCardEnv>((ref) {
  throw UnimplementedError('Must be overridden by askLocalCardMain boot');
});

final askLocalCardNotifierProvider =
    NotifierProvider<AskLocalCardNotifier, AskLocalCardState>(
  AskLocalCardNotifier.new,
);

/// Card-side ToolProvider over the payload's fork-parity toolset: the
/// definitions classify families (`local://web` etc.) for the approval
/// gate WITHOUT the card constructing its own servers; execution routes
/// to the MAIN engine's registry across the card channel.
class PayloadToolRegistryProvider implements ToolProvider {
  PayloadToolRegistryProvider({required List<ToolDefinition> defs, required this.executeRemotely})
      : _defs = List.of(defs);

  final List<ToolDefinition> _defs;
  final Future<({bool success, String output, String? error})> Function(
    String toolName,
    Map<String, dynamic> arguments,
  ) executeRemotely;

  @override
  Future<List<ToolDefinition>> listTools() async => List.of(_defs);

  @override
  Future<ToolExecutionResult> execute(
    String name,
    Map<String, dynamic> args,
  ) async {
    final outcome = await executeRemotely(name, args);
    return outcome.success
        ? ToolExecutionResult.success(outcome.output)
        : ToolExecutionResult.failure(
            outcome.error ?? 'tool failed on the main engine',
          );
  }
}

class AskLocalCardNotifier extends Notifier<AskLocalCardState> {
  ChatService? _chatService;
  bool _cancelled = false;
  PendingAskLocalApproval? _pendingApproval;
  Completer<void>? _exchangeSettle;
  String? _lastDeliveryId;
  String? _exchangeDeliveryId;
  String? _unsentCapturePath;

  @override
  AskLocalCardState build() {
    ref.onDispose(_disposeExchange);
    return const AskLocalCardState();
  }

  /// Newest-delivered-wins hand-off with re-delivery idempotence: the same
  /// delivery id (main engine requestId, else the staging composite) is an
  /// ignore; a NEW id cancels any in-flight exchange (approvals settle
  /// denied) and opens the fresh round.
  Future<void> applyDelivery(
    AskLocalCardDelivery delivery, {
    bool forceReanchor = false,
  }) async {
    // Dedupe: the same delivery re-pushed while live is an exact no-op —
    // EXCEPT a forced re-anchor (window re-mount after minimize), which
    // must rebuild + resize the fresh view even for the same id.
    // ignore: avoid_print
    print('DBG card apply: force=$forceReanchor id=${delivery.deliveryId} last=$_lastDeliveryId');
    if (!forceReanchor && delivery.deliveryId == _lastDeliveryId) return;
    _lastDeliveryId = delivery.deliveryId;
    if (state.isStreaming) {
      cancel();
      final settle = _exchangeSettle;
      if (settle != null) await settle.future;
    }
    _deleteFileBestEffort(_unsentCapturePath);
    _unsentCapturePath = delivery.payload.capturePath;
    if (!ref.mounted) return;
    state = AskLocalCardState(
      delivery: delivery,
      history: state.history,
      captureEffectivePath: delivery.payload.capturePath,
      modelLabel: delivery.bootstrap?.modelId ?? 'No model',
    );
    try {
      final conversation = await ref
          .read(askLocalCardEnvProvider)
          .conversationService
          .resolve(delivery.bootstrap?.conversationId);
      final rows = await loadRows(conversation.id);
      if (ref.mounted && identical(_lastDeliveryId, delivery.deliveryId)) {
        state = state.copyWith(history: rows);
      }
    } catch (error) {
      Log.error('Ask Local history seed failed: $error');
    }
  }

  /// Window torn down without a card-side close (permission revoked, token
  /// teardown). The engine lives on — reap = cancel the exchange; rows
  /// already persisted stay in the conversation.
  void reapClosed() {
    if (!state.isStreaming) return;
    cancel();
  }

  Future<bool> recapture() async {
    if (state.isStreaming) return false;
    final hook = ref.read(askLocalCardEnvProvider).captureNow;
    if (hook == null) return false;
    final path = await hook();
    if (path == null || !ref.mounted) return false;
    final replaced = state.captureEffectivePath;
    if (replaced != null && replaced != path) {
      _deleteFileBestEffort(replaced);
      if (identical(_unsentCapturePath, replaced)) {
        _unsentCapturePath = path;
      }
    }
    state = state.copyWith(captureEffectivePath: path);
    return true;
  }

  void cancel() {
    if (!state.isStreaming) return;
    _cancelled = true;
    _chatService?.cancelStream();
    _settlePendingApproval();
  }

  void approvePending() => _pendingApproval?.approve();

  void denyPending() => _pendingApproval?.deny();

  void _settlePendingApproval() {
    final pending = _pendingApproval;
    if (pending == null) return;
    pending.settleAsDenied();
    if (identical(_pendingApproval, pending)) _pendingApproval = null;
    if (ref.mounted && identical(state.pendingApproval, pending)) {
      state = state.copyWith(clearPendingApproval: true);
    }
  }

  Future<void> send(String question) async {
    final trimmed = question.trim();
    // An empty question is legal: the selection + screenshot ARE the
    // context — "send without typing anything" runs a context-only ask.
    if (state.isStreaming) return;

    final delivery = state.delivery;
    if (delivery == null) return;
    final bootstrap = delivery.bootstrap;
    if (bootstrap == null) {
      state = state.copyWith(
        isStreaming: false,
        failure: 'No model connected — reopen the card from the main app.',
      );
      return;
    }

    state = state.copyWith(isStreaming: true, clearFailure: true);
    _cancelled = false;
    final finished = Completer<void>();
    _exchangeSettle = finished;
    final exchangeDeliveryId = delivery.deliveryId;
    _exchangeDeliveryId = exchangeDeliveryId;
    final clock = Stopwatch()..start();

    final Conversation conversation;
    try {
      conversation = await ref
          .read(askLocalCardEnvProvider)
          .conversationService
          .resolve(bootstrap.conversationId);
    } catch (error) {
      Log.error('Ask Local conversation resolve failed: $error');
      _failExchange(finished, 'Could not reach the Ask Local conversation storage.');
      return;
    }
    if (_exchangeAborted(finished, exchangeDeliveryId)) return;

    final chatService = ref
        .read(askLocalCardEnvProvider)
        .serviceFor
        ?.call(bootstrap);
    if (chatService == null) {
      _failExchange(
        finished,
        'No chat service available for ${bootstrap.server.name}.',
      );
      return;
    }

    final attachmentRows = await stageCapture(bootstrap);
    if (_exchangeAborted(finished, exchangeDeliveryId)) return;

    final rows = await loadRows(conversation.id);
    if (!ref.mounted) {
      _settleIfOpen(finished);
      return;
    }

    final selectedText = delivery.payload.selectedText.trim();
    final excerpt = clipScreenExcerpt(selectedText);
    final content = trimmed.isEmpty
        ? (excerpt.isEmpty ? 'What is on my screen?' : 'From screen: "$excerpt"')
        : (excerpt.isEmpty
            ? trimmed
            : 'From screen: "$excerpt"\n\n$trimmed');
    final userRow = Message(
      id: generateUuidV4(),
      conversationId: conversation.id,
      role: MessageRole.user,
      content: content,
      createdAt: DateTime.now(),
      status: MessageStatus.complete,
      attachmentPaths: attachmentRows.isEmpty ? null : attachmentRows,
      threadOrder: nextThreadOrderOf(rows),
    );
    state = state.copyWith(transcript: [userRow]);
    await persistRow(userRow);
    if (_exchangeAborted(finished, exchangeDeliveryId)) return;
    consumeStagedCapture();
    _chatService = chatService;

    final wire = assembleCardWire(rows, userRow, bootstrap);
    final toolDefs = [
      for (final wireDef in bootstrap.toolDefs) wireDef.toDefinition(),
    ];
    final allowedToolNames = {for (final def in toolDefs) def.name};
    final cardRegistry = ToolRegistry(
      providers: [
        PayloadToolRegistryProvider(
          defs: toolDefs,
          executeRemotely: _executeRemotely,
        ),
      ],
    );
    final settings = _frozenSettings(bootstrap);
    var nextThreadOrder = userRow.threadOrder + 1;

    Future<void> runRound(int roundIndex) async {
      var streamingRow = Message(
        id: generateUuidV4(),
        conversationId: conversation.id,
        role: MessageRole.assistant,
        content: '',
        createdAt: DateTime.now(),
        status: MessageStatus.streaming,
        modelId: bootstrap.modelId,
        threadOrder: nextThreadOrder,
      );
      _upsertTranscript(streamingRow);

      var content = '';
      var reasoningContent = '';
      final roundCalls = <cs.ToolCallData>[];

      final responseQueue = StreamQueue<ChatResponse>(
        chatService.sendMessage(
          server: bootstrap.server.toServer(),
          modelId: bootstrap.modelId,
          messages: List.of(wire),
          params: bootstrap.params,
          tools: toolDefs.isEmpty ? null : List.of(toolDefs),
        ),
      );

      var errorFinalized = false;
      try {
        while (await responseQueue.hasNext) {
          final response = await responseQueue.next;
          switch (response.type) {
            case ChatResponseType.message:
              content += response.content ?? '';
              streamingRow = streamingRow.copyWith(
                content: streamingRow.content + (response.content ?? ''),
                isProcessing: false,
              );
              _upsertTranscript(streamingRow);
            case ChatResponseType.reasoning:
              reasoningContent += response.reasoningContent ?? '';
              streamingRow = streamingRow.copyWith(
                reasoningContent: reasoningContent,
                isProcessing: false,
              );
              _upsertTranscript(streamingRow);
            case ChatResponseType.processing:
              streamingRow = streamingRow.copyWith(isProcessing: true);
              _upsertTranscript(streamingRow);
            case ChatResponseType.toolCall:
              if (response.toolCall != null) roundCalls.add(response.toolCall!);
            case ChatResponseType.error:
            case ChatResponseType.timeoutError:
              errorFinalized = true;
              streamingRow = streamingRow.copyWith(
                status: MessageStatus.error,
                errorMessage:
                    response.content ?? 'The model failed to respond.',
                isProcessing: false,
              );
              await _finalize(streamingRow, failure: streamingRow.errorMessage);
              _settleIfOpen(finished);
              return;
            case ChatResponseType.invalidToolCall:
            case ChatResponseType.done:
              break;
          }
        }
      } catch (error) {
        errorFinalized = true;
        try {
          streamingRow = streamingRow.copyWith(
            status: MessageStatus.error,
            errorMessage: error.toString(),
            isProcessing: false,
          );
          await _finalize(streamingRow, failure: error.toString());
        } catch (finalizeError) {
          Log.error('Ask Local stream-throw finalize failed: $finalizeError');
          if (ref.mounted) {
            state = state.copyWith(isStreaming: false, failure: error.toString());
          }
        } finally {
          _settleIfOpen(finished);
        }
        return;
      }

      if (errorFinalized) {
        _settleIfOpen(finished);
        return;
      }

      if (roundCalls.isEmpty) {
        final hasContent = content.trim().isNotEmpty ||
            reasoningContent.trim().isNotEmpty;
        if (_cancelled) {
          await _finalize(
            streamingRow.copyWith(
              status: MessageStatus.complete,
              isProcessing: false,
              stopReason: 'cancelled',
            ),
          );
        } else if (!hasContent) {
          Log.error(
            'Ask Local empty reply {delivery: $exchangeDeliveryId, '
            'round: $roundIndex, wireRoles: ${wire.length}, '
            'toolsSent: ${toolDefs.length}, '
            'elapsedMs: ${clock.elapsedMilliseconds}}',
          );
          await _finalize(
            streamingRow.copyWith(
              status: MessageStatus.error,
              errorMessage: 'The model failed to respond. This may happen '
                  'with free tier models that refuse certain prompts or '
                  'when the service is busy.',
              isProcessing: false,
            ),
            failure: 'The model returned an empty reply.',
          );
        } else {
          await _finalize(
            streamingRow.copyWith(
              status: MessageStatus.complete,
              isProcessing: false,
              stopReason: 'complete',
            ),
          );
        }
        _settleIfOpen(finished);
        return;
      }

      if (roundIndex >= bgMaxToolRounds) {
        streamingRow = streamingRow.copyWith(
          status: MessageStatus.error,
          errorMessage:
              'Tool round limit reached ($bgMaxToolRounds) without a '
              'final answer.',
          isProcessing: false,
        );
        await _finalize(streamingRow, failure: streamingRow.errorMessage);
        _settleIfOpen(finished);
        return;
      }

      final ToolRoundRows roundResult;
      try {
        roundResult = await executeToolRound(
          ToolRoundSpec(
            conversationId: conversation.id,
            wire: wire,
            nextThreadOrder: nextThreadOrder,
            streamedContent: content,
            calls: List.of(roundCalls),
            allowedToolNames: allowedToolNames,
            approvalGate: (toolName, arguments) => _cardApprovalGate(
              toolName,
              arguments,
              cardRegistry: cardRegistry,
              settings: settings,
            ),
            executeTool: (toolName, arguments) =>
                _executeCardTool(toolName, arguments),
            persistRow: persistRow,
            buildRoundRow: ({
              required content,
              required toolCalls,
              required threadOrder,
            }) =>
                Message(
              id: streamingRow.id,
              conversationId: conversation.id,
              role: MessageRole.assistant,
              content: content,
              createdAt: DateTime.now(),
              status: MessageStatus.complete,
              modelId: bootstrap.modelId,
              toolCalls: toolCalls,
              isActiveVariant: false,
              threadOrder: threadOrder,
            ),
            buildFeedbackRow: ({
              required callId,
              required resultText,
              required threadOrder,
            }) =>
                Message(
              id: 'tool_$callId',
              conversationId: conversation.id,
              role: MessageRole.tool,
              content: resultText,
              createdAt: DateTime.now(),
              status: MessageStatus.complete,
              toolCallId: callId,
              isActiveVariant: false,
              threadOrder: threadOrder,
            ),
          ),
        );
      } catch (error) {
        streamingRow = streamingRow.copyWith(
          status: MessageStatus.error,
          errorMessage: error.toString(),
          isProcessing: false,
        );
        await _finalize(streamingRow, failure: error.toString());
        _settleIfOpen(finished);
        return;
      }

      nextThreadOrder = roundResult.nextThreadOrder;
      _upsertTranscript(roundResult.roundRow);
      for (final feedback in roundResult.feedbackRows) {
        _upsertTranscript(feedback);
      }
      if (!ref.mounted) {
        _settleIfOpen(finished);
        return;
      }
      if (_cancelled) {
        try {
          await _finalize(
            roundResult.roundRow.copyWith(
              status: MessageStatus.complete,
              isProcessing: false,
              stopReason: 'cancelled',
            ),
          );
        } catch (finalizeError) {
          Log.error('Ask Local orphaned-exchange finalize failed: $finalizeError');
          if (ref.mounted) state = state.copyWith(isStreaming: false);
        } finally {
          _settleIfOpen(finished);
        }
        return;
      }
      return runRound(roundIndex + 1);
    }

    try {
      await runRound(0);
      await finished.future;
    } finally {
      _exchangeSettle = null;
      _exchangeDeliveryId = null;
    }
    if (ref.mounted && exchangeDeliveryId == _lastDeliveryId) {
      state = state.copyWith(
        history: [...state.history, ...state.transcript],
        transcript: const [],
        isStreaming: false,
      );
    }
  }

  Future<({bool success, String output, String? error})> _executeRemotely(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final hook = ref.read(askLocalCardEnvProvider).remoteExecuteTool;
    if (hook == null) {
      return (
        success: false,
        output: '',
        error: 'tool execution unavailable in this card mode',
      );
    }
    return hook(toolName, arguments);
  }

  Future<ToolExecutionResult> _executeCardTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final outcome = await _executeRemotely(toolName, arguments);
    return outcome.success
        ? ToolExecutionResult.success(outcome.output)
        : ToolExecutionResult.failure(outcome.error ?? 'tool failed');
  }

  /// The card's approval gate (fork `shouldAutoApproveTool` parity over the
  /// FROZEN settings snapshot + the payload-defs registry). Auto-approved
  /// calls run; dialog-worthy calls park on an in-card chip whose settle
  /// resolves the awaiting round.
  Future<bool> _cardApprovalGate(
    String toolName,
    Map<String, dynamic> arguments, {
    required ToolRegistry cardRegistry,
    required AppSettings settings,
  }) async {
    var auto = false;
    try {
      auto = await shouldAutoApproveTool(
        toolName,
        args: arguments,
        webToolsEnabled: settings.webToolsEnabled,
        terminalToolsEnabled: settings.terminalToolsEnabled,
        deviceToolsEnabled: settings.deviceToolsEnabled,
        mailAccountsConnected: settings.mailConnectorAccounts.isNotEmpty,
        skillsEnabled: settings.skillsEnabled,
        backgroundTasksEnabled: settings.backgroundTasksEnabled,
        notificationToolsEnabled: settings.notificationToolsEnabled,
        registry: cardRegistry,
        whitelist: TerminalWhitelist(settings.toolWhitelist),
      );
    } catch (_) {
      auto = false;
    }
    if (auto) return true;
    if (!ref.mounted) return false;
    final completer = Completer<bool>();
    final approval = PendingAskLocalApproval(
      toolName: toolName,
      arguments: arguments,
      completer: completer,
    );
    _pendingApproval = approval;
    state = state.copyWith(pendingApproval: approval);
    final approved = await completer.future;
    if (identical(_pendingApproval, approval)) _pendingApproval = null;
    if (ref.mounted && identical(state.pendingApproval, approval)) {
      state = state.copyWith(clearPendingApproval: true);
    }
    return approved;
  }

  /// The card's wire: optional system framing from the frozen params + the
  /// persisted conversation tail through the shared context predicate + the
  /// new user row LAST (fork context assembly parity at card scale).
  @visibleForTesting
  static List<Message> assembleCardWire(
    List<Message> rows,
    Message userRow,
    AskLocalCardBootstrapPayload bootstrap,
  ) {
    final messages = <Message>[];
    final systemPrompt = bootstrap.params.systemPrompt?.trim();
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      messages.add(
        Message(
          id: 'ask-local-system-${userRow.id}',
          conversationId: userRow.conversationId,
          role: MessageRole.system,
          content: systemPrompt,
          createdAt: userRow.createdAt,
          status: MessageStatus.complete,
        ),
      );
    }
    for (final row in rows) {
      if (row.role == MessageRole.system) continue;
      if (!shouldIncludeMessageInChatContext(row)) continue;
      messages.add(row);
    }
    messages.add(userRow);
    return messages;
  }

  @visibleForTesting
  static String clipScreenExcerpt(String selectedText) {
    final trimmed = selectedText.trim();
    if (trimmed.isEmpty) return '';
    const maxChars = 180;
    if (trimmed.length <= maxChars) return trimmed;
    return '${trimmed.substring(0, maxChars)}…';
  }

  static int nextThreadOrderOf(List<Message> rows) {
    if (rows.isEmpty) return 0;
    return rows.map((row) => row.threadOrder).reduce(
          (a, b) => a > b ? a : b,
        ) +
        1;
  }

  /// Copies the staged capture into the house attachments directory; the
  /// persisted row references the SAVED copy (post-consume deletion of the
  /// staged file can never orphan the thumbnail — house send parity).
  @protected
  @visibleForTesting
  Future<List<String>> stageCapture(
    AskLocalCardBootstrapPayload bootstrap,
  ) async {
    final staged = state.capturePath;
    if (staged == null || staged.isEmpty) return const [];
    try {
      final file = File(staged);
      if (!await file.exists()) return const [];
      final dir = await _attachmentsDir(bootstrap);
      final saved = await AttachmentHelpers.saveAttachment(file, dir);
      return saved == null ? const [] : [saved];
    } catch (error) {
      Log.error('Ask Local capture staging failed: $error');
      return const [];
    }
  }

  /// The capture's save directory. Envelope v2: the MAIN engine resolved the
  /// attachments dir at hand-off and ships it explicitly — v2 cards consume
  /// it verbatim. A v2 envelope MISSING the path is logged typed (contract:
  /// tolerate missing optional strings with the documented fallback), and a
  /// v1 envelope (schemaVersion 0 / absent paths) keeps the historical
  /// storeDir-parent inference.
  Future<Directory> _attachmentsDir(
    AskLocalCardBootstrapPayload bootstrap,
  ) async {
    final override = ref.read(askLocalCardEnvProvider).attachmentsDirOf;
    final overridden = override?.call();
    if (overridden != null) return overridden;
    final shipped = bootstrap.attachmentsDirPath;
    if (shipped != null && shipped.isNotEmpty) {
      return Directory(shipped);
    }
    if (bootstrap.schemaVersion >=
        AskLocalCardBootstrapPayload.currentSchemaVersion) {
      Log.error(
        'Ask Local envelope v${bootstrap.schemaVersion} missing '
        'attachmentsDirPath — falling back to the v1 inference',
      );
    }
    final docsDir = File(bootstrap.storeDir).parent;
    return Directory('${docsDir.path}${Platform.pathSeparator}attachments');
  }

  void consumeStagedCapture() {
    _deleteFileBestEffort(_unsentCapturePath);
    _unsentCapturePath = null;
  }

  void _deleteFileBestEffort(String? path) {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (error) {
      Log.error('Ask Local staged capture cleanup failed: $error');
    }
  }

  AppSettings _frozenSettings(AskLocalCardBootstrapPayload bootstrap) {
    final json = bootstrap.settingsJson;
    if (json.isEmpty) return AppSettings();
    try {
      return AppSettings.fromJson(json);
    } catch (error) {
      Log.error('Ask Local settings snapshot decode failed: $error');
      return AppSettings();
    }
  }

  void _upsertTranscript(Message row) {
    if (!ref.mounted) return;
    if (_exchangeDeliveryId != null && _exchangeDeliveryId != _lastDeliveryId) {
      // A delivery swap cancelled this exchange — no row of a dead round
      // may land in the NEW round's transcript.
      return;
    }
    final copy = List.of(state.transcript);
    final index = copy.indexWhere((existing) => existing.id == row.id);
    if (index >= 0) {
      copy[index] = row;
    } else {
      copy.add(row);
    }
    state = state.copyWith(transcript: copy);
  }

  Future<void> _finalize(Message finalRow, {String? failure}) async {
    await persistRow(finalRow);
    if (!ref.mounted) return;
    _upsertTranscript(finalRow);
    state = state.copyWith(
      isStreaming: false,
      failure: failure,
      clearFailure: failure == null,
    );
  }

  void _failExchange(Completer<void> finished, String message) {
    if (ref.mounted) {
      state = state.copyWith(isStreaming: false, failure: message);
    }
    _settleIfOpen(finished);
  }

  void _settleIfOpen(Completer<void> finished) {
    if (!finished.isCompleted) finished.complete();
  }

  /// Abort probe between stage boundaries: cancel, torn-down container, or
  /// a delivery swap mid-exchange (the window re-show racing the round).
  /// Aborting settles the exchange so awaiting callers resolve.
  bool _exchangeAborted(Completer<void> finished, String exchangeDeliveryId) {
    final aborted =
        _cancelled || !ref.mounted || exchangeDeliveryId != _lastDeliveryId;
    if (aborted) _settleIfOpen(finished);
    return aborted;
  }

  @protected
  @visibleForTesting
  Future<List<Message>> loadRows(String conversationId) async {
    final db = ref.watch(databaseProvider);
    return db.store.runInTransactionAsync(
      TxMode.read,
      _loadCardRowsInBackground,
      conversationId,
    );
  }

  static List<Message> _loadCardRowsInBackground(
    Store store,
    String conversationId,
  ) {
    final messageBox = store.box<MessageEntity>();
    final query = messageBox
        .query(MessageEntity_.conversationUid.equals(conversationId))
        .build();
    final entities = query.find();
    query.close();
    final messages = entities.map((entity) => entity.toDomain()).toList()
      ..sort((a, b) {
        final orderCompare = a.threadOrder.compareTo(b.threadOrder);
        if (orderCompare != 0) return orderCompare;
        return a.createdAt.compareTo(b.createdAt);
      });
    return messages;
  }

  @protected
  @visibleForTesting
  Future<void> persistRow(Message message) async {
    final db = ref.watch(databaseProvider);
    await db.store.runInTransactionAsync(
      TxMode.write,
      _persistCardRowInBackground,
      message,
    );
  }

  static void _persistCardRowInBackground(Store store, Message message) {
    final box = store.box<MessageEntity>();
    final convBox = store.box<ConversationEntity>();

    final query = box.query(MessageEntity_.id.equals(message.id)).build();
    final existing = query.findFirst();
    query.close();

    final entity = MessageEntity.fromDomain(message);
    if (existing != null) {
      entity.internalId = existing.internalId;
    }

    final convQuery = convBox
        .query(ConversationEntity_.id.equals(message.conversationId))
        .build();
    final convEntity = convQuery.findFirst();
    convQuery.close();

    if (convEntity != null) {
      entity.conversation.target = convEntity;
      entity.conversationUid = convEntity.id;
    } else {
      entity.conversationUid = message.conversationId;
    }

    box.put(entity);
  }

  /// Dispose: stop the exchange + settle a pending chip WITHOUT state use
  /// (riverpod 3 forbids state access in dispose life-cycles).
  void _disposeExchange() {
    _chatService?.cancelStream();
    _chatService = null;
    _cancelled = false;
    final pending = _pendingApproval;
    _pendingApproval = null;
    if (pending != null) {
      pending.settleAsDenied();
    }
  }
}
