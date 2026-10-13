import 'dart:async';

import 'package:async/async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/core/logger/app_logger.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/core/utils/uuid.dart';
import 'package:localmind/features/chat/data/chat_service.dart'
    hide ToolCallData;
import 'package:localmind/features/chat/data/chat_service.dart' as cs
    show ToolCallData;
import 'package:localmind/features/chat/data/fork_service.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/data/tool_rounds.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/providers/chat_notifier.dart';
import 'package:localmind/features/chat/providers/chat_params_providers.dart';
import 'package:localmind/features/chat/providers/chat_service_providers.dart';
import 'package:localmind/features/chat/providers/fork_panel_overlay.dart';
import 'package:localmind/features/chat/providers/model_selection_providers.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/mcp/data/terminal_mcp_server.dart';
import 'package:localmind/objectbox.g.dart';

/// Completer-bound ask-the-user record for ONE fork tool call: the panel
/// renders it as an in-transcript approval chip; approve()/deny() drive the
/// pending [Completer] the round is blocked on. Lives in ForkChatState —
/// fork approvals NEVER touch ChatNotifier's main-feed approval stream.
class PendingForkApproval {
  PendingForkApproval({
    required this.toolName,
    required this.arguments,
    required this.completer,
  });

  final String toolName;
  final Map<String, dynamic> arguments;
  final Completer<bool> completer;

  /// Completes the gate with an approval. Idempotent.
  Future<bool> approve() => _settle(true);

  /// Completes the gate with a denial (the model later receives the
  /// `denied by the user` feedback string). Idempotent.
  Future<bool> deny() => _settle(false);

  /// Completes the gate with a denial without UI involvement (panel-close
  /// / cancel settle paths deny implicitly).
  void settleAsDenied() => _settle(false);

  Future<bool> _settle(bool approved) {
    if (!completer.isCompleted) {
      completer.complete(approved);
    }
    return completer.future;
  }
}

/// State of one fork (selection-anchored) chat.
///
/// [transcript] carries the fork conversation's own user + assistant turns
/// in chronological order; [failure] surfaces the last typed rejection
/// (e.g. an anchor no longer on the active timeline) or stream error, and
/// is reset when the next [ForkChatNotifier.submit] starts. A non-null
/// [pendingApproval] pauses the active tool round on an in-panel chip.
class ForkChatState {
  final List<Message> transcript;
  final bool isStreaming;
  final String? failure;
  final PendingForkApproval? pendingApproval;

  const ForkChatState({
    this.transcript = const [],
    this.isStreaming = false,
    this.failure,
    this.pendingApproval,
  });

  ForkChatState copyWith({
    List<Message>? transcript,
    bool? isStreaming,
    String? failure,
    bool clearFailure = false,
    PendingForkApproval? pendingApproval,
    bool clearPendingApproval = false,
  }) {
    return ForkChatState(
      transcript: transcript ?? this.transcript,
      isStreaming: isStreaming ?? this.isStreaming,
      failure: clearFailure ? null : (failure ?? this.failure),
      pendingApproval: clearPendingApproval
          ? null
          : (pendingApproval ?? this.pendingApproval),
    );
  }
}

/// Streams replies for one fork (selection-anchored) conversation and
/// persists every exchange — user turn + assistant turn + any tool-round
/// rows — into its hidden fork conversation.
///
/// The family is keyed by the fork conversation id; each instance owns its
/// transcript and builds its ChatService through the same
/// [chatServiceFactoryProvider] the main sends use (no second Dio/config
/// path), with `cancel()` forwarding to `ChatService.cancelStream()` just
/// like `ChatNotifier.cancelStream` does. Tool support (task 5B): the fork
/// send carries the [forkChatToolsetProvider] definitions (structurally
/// minus `bg.*`/`notifications.*`), and dialog-worthy calls pause the round
/// on a completer-backed approval chip instead of running silently.
final forkChatNotifierProvider =
    NotifierProvider.family<ForkChatNotifier, ForkChatState, String>(
      (forkConversationId) =>
          ForkChatNotifier(forkConversationId: forkConversationId),
    );

class ForkChatNotifier extends Notifier<ForkChatState> {
  ForkChatNotifier({this.forkConversationId = ''});

  /// The fork conversation this notifier slot manages. [submit] refuses ids
  /// from outside this slot so UI wiring cannot cross two forks' streams.
  final String forkConversationId;

  /// Shared rejection copy for an anchor no longer resolvable on the active
  /// timeline (final-review: surface it at open time and at fork creation
  /// instead of failing only on submit).
  static const anchorUnavailableMessage =
      "This selection's anchor is unavailable — it may be an inactive "
      'variant. Re-create the fork from an active message.';

  ChatService? _chatService;
  StreamSubscription<ChatResponse>? _streamSubscription;
  bool _cancelled = false;
  /// Fix round 1: set when the overlay controller closes, swaps or tears
  /// down the panel over this fork while an exchange is live. Between tool
  /// rounds a detached panel must never fire the next generation — the
  /// exchange finalizes instead (no approval chip can re-raise behind a
  /// dead panel).
  bool _panelDetached = false;
  /// Notifier-held mirror of the current approval: resolves (deny) WITHOUT
  /// `state` usage when the container tears down — riverpod 3 forbids
  /// state access inside dispose life-cycles.
  PendingForkApproval? _pendingApproval;
  /// Set at the top of every [submit] and completed on every terminal path
  /// (typed failure, empty reply, error, cancel, success) — [cancelAndSettle]
  /// awaits it so downstream mutations (ForkService.deleteFork) cannot race
  /// the finalize into a deleted fork conversation.
  Completer<void>? _exchangeSettle;
  // Forensic context for the empty-reply failure branch: if THIS exchange
  // ever parked a fork approval chip, and the submit-start clock.
  bool exchangeHadApproval = false;

  @override
  ForkChatState build() {
    ref.onDispose(_disposeStream);
    return const ForkChatState();
  }

  /// Panel-open hook (final-review fixes 1 + 3): a fresh notifier slot —
  /// including the one built after an app restart — seeds its transcript
  /// from the persisted fork rows (spec Q1: forks survive restarts) and
  /// validates the anchor, so a band tap on a fork whose anchor left the
  /// active timeline (deleted row, inactive variant) surfaces the typed
  /// rejection as the panel's failure banner immediately instead of failing
  /// only when the user submits. [submit]'s own empty-transcript load stays
  /// as the second line of defense for exchanges racing this hook.
  Future<void> prepareForPanelOpen(String anchorMessageId) async {
    await _seedFromPersistedTurns();
    checkAnchorAvailability(anchorMessageId);
  }

  /// Loads the persisted fork conversation rows into the transcript, once
  /// per panel open. Guarded so seeding can never clobber an in-flight
  /// exchange or rows a concurrent [submit] already composed (seeding must
  /// never duplicate turns — identity is preserved).
  ///
  /// Best-effort: a storage failure logs and leaves the transcript empty
  /// instead of breaking the panel.
  Future<void> _seedFromPersistedTurns() async {
    if (state.isStreaming || state.transcript.isNotEmpty) {
      // A submit (or live exchange) already owns the transcript.
      return;
    }
    final List<Message> loaded;
    try {
      loaded = await loadForkMessages(forkConversationId);
    } catch (error) {
      Log.error('Failed to load fork transcript for seeding: $error');
      return;
    }
    if (!ref.mounted) return;
    final current = state;
    if (current.isStreaming || current.transcript.isNotEmpty) {
      return;
    }
    state = current.copyWith(transcript: loaded);
  }

  /// Active-timeline validation of the fork anchor (shared by panel open
  /// and [submit]): a null `mainTimelineUpTo` resolution — the anchor is
  /// gone or an inactive variant — surfaces [anchorUnavailableMessage].
  void checkAnchorAvailability(String anchorMessageId) {
    if (state.isStreaming) return;
    if (ref.read(chatProvider.notifier).mainTimelineUpTo(anchorMessageId) !=
        null) {
      return;
    }
    _failAndStop(anchorUnavailableMessage);
  }

  /// Fork chat toolset: FULL toggled registry minus the structural
  /// bg.*/notifications.* families (see [forkChatToolset]). Dialog-worthy
  /// tools STAY — forks approve in-panel. Best-effort: any registry
  /// resolution failure (fresh install, missing plugin in early boot) falls
  /// back to `null` — a plain tool-less fork send, the pre-task-5 behavior.
  Future<List<ToolDefinition>?> _resolveForkTools() async {
    try {
      final defs = await ref.read(forkChatToolsetProvider.future);
      return defs.isEmpty ? null : defs;
    } catch (error) {
      Log.error('Fork toolset resolution failed (tool-less fork): $error');
      return null;
    }
  }

  /// The fork approval gate for the shared round executor: auto-approve
  /// when the toggles already allow the call (same verdict the main chat
  /// uses); otherwise park the completer-backed
  /// [PendingForkApproval] in state and await the panel chip.
  ToolApprovalGate _forkApprovalGate() {
    return (toolName, arguments) async {
      var auto = false;
      try {
        final settings = ref.read(settingsProvider);
        final registry = ref.read(toolRegistryProvider);
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
          registry: registry,
          whitelist: TerminalWhitelist(settings.toolWhitelist),
        );
      } catch (_) {
        auto = false;
      }
      if (auto) return true;
      if (!ref.mounted) return false;
      final completer = Completer<bool>();
      final approval = PendingForkApproval(
        toolName: toolName,
        arguments: arguments,
        completer: completer,
      );
      _pendingApproval = approval;
      exchangeHadApproval = true;
      state = state.copyWith(pendingApproval: approval);
      final approved = await completer.future;
      if (identical(_pendingApproval, approval)) {
        _pendingApproval = null;
      }
      if (ref.mounted && identical(state.pendingApproval, approval)) {
        state = state.copyWith(clearPendingApproval: true);
      }
      return approved;
    };
  }

  /// Completes a pending approval as DENIED and clears it. Called by the
  /// overlay controller when a panel closes (or a cancel/settle) over a
  /// live chip — the awaiting round then resumes with the denial feedback
  /// instead of dead-waiting. Never touches the main feed.
  void settlePendingApproval() {
    final pending = _pendingApproval;
    if (pending == null) return;
    pending.settleAsDenied();
    if (identical(_pendingApproval, pending)) {
      _pendingApproval = null;
    }
    if (ref.mounted && identical(state.pendingApproval, pending)) {
      state = state.copyWith(clearPendingApproval: true);
    }
  }

  /// Submits [question] to the fork conversation whose slot this notifier
  /// was created for.
  ///
  /// Contract (selection-fork-chats, Task 3):
  /// - `ChatNotifier.mainTimelineUpTo(anchorMessageId)` failing to resolve —
  ///   the anchor is gone or an inactive variant — rejects the submit with a
  ///   surfaced failure and persists nothing;
  /// - a sliced main tail ending on dangling assistant(tool_calls)/tool
  ///   rows is trimmed until it ends on a plain assistant(content) or user
  ///   row, so the fork wire never carries an unfinished protocol pair;
  /// - the fork's FIRST user turn carries the quoted selection, follow-ups
  ///   pass the question plain ([ForkService.buildForkContextMessages]);
  /// - both turns of an exchange are persisted through the [MessageEntity]
  ///   path with `conversationUid` = the fork conversation id.
  Future<void> submit(
    String forkConversationId,
    String question, {
    required String selectedText,
    required String anchorMessageId,
  }) async {
    if (forkConversationId != this.forkConversationId) {
      throw ArgumentError.value(
        forkConversationId,
        'forkConversationId',
          'belongs to another fork slot; this notifier manages '
            '${this.forkConversationId}',
      );
    }
    if (state.isStreaming) return;

    state = state.copyWith(isStreaming: true, clearFailure: true);
    _cancelled = false;
    // Per-exchange panel-detachment probe reset (see [notePanelDetached]).
    _panelDetached = false;
    // Forensics: fresh approval flag + per-exchange clock for the empty
    // reply log bundle.
    exchangeHadApproval = false;
    final exchangeClock = Stopwatch()..start();
    // Every terminal path completes this; see cancelAndSettle.
    final finished = Completer<void>();
    _exchangeSettle = finished;

    final target = ref.read(activeChatTargetProvider);
    final server = target.server;
    final effectiveModelId = target.effectiveModelId;
    if (server == null || effectiveModelId == null) {
      _failAndStop('No model connected — pick a server/model first.');
      return;
    }
    final chatService = ref.read(chatServiceFactoryProvider)(server);
    if (chatService == null) {
      _failAndStop('No chat service available for ${server.name}.');
      return;
    }

    final mainSlice = ref
        .read(chatProvider.notifier)
        .mainTimelineUpTo(anchorMessageId);
    if (mainSlice == null) {
      _failAndStop(ForkChatNotifier.anchorUnavailableMessage);
      return;
    }
    final sanitizedMain = _trimDanglingToolTail(mainSlice);

    var forkTurns = List.of(state.transcript);
    if (forkTurns.isEmpty) {
      // Forks survive restarts (spec Q1): seed the transcript from the
      // persisted fork rows before composing context, so follow-ups after a
      // relaunch stay un-quoted and full-context.
      forkTurns = await loadForkMessages(forkConversationId);
      if (forkTurns.isNotEmpty && ref.mounted) {
        state = state.copyWith(transcript: forkTurns);
      }
    }

    final wire = ForkService().buildForkContextMessages(
      mainTimelineUpToAnchor: sanitizedMain,
      forkTurns: forkTurns,
      question: question,
      selectedText: selectedText,
    );

    final userRow = wire.last.copyWith(
      conversationId: forkConversationId,
      threadOrder: forkTurns.length,
    );

    state = state.copyWith(transcript: [...forkTurns, userRow]);

    // The user turn persists up front; the assistant row persists when it
    // finalizes (complete/error/cancelled) — one row per turn.
    await persistMessage(userRow);
    if (!ref.mounted) {
      _failAndStop('Chat closed before the fork reply started.');
      return;
    }

    _chatService = chatService;
    // Mirrors ChatNotifier's streamHadError guard: real services yield the
    // error/timeoutError as a data event and then return, which closes the
    // stream — the done branch must not re-finalize over the error state.
    var errorFinalized = false;

    // Fork tool loop (task 5B): the fork partner speaks with the same
    // toolset the main chat would send minus the bg.*/notifications.* families;
    // dialog-worthy calls pause the round on an in-panel approval chip.
    final forkTools = await _resolveForkTools();
    var nextThreadOrder = forkTurns.length + 1;

    // Drives ONE generation round: streams against the (frozen) wire,
    // mirrors the main pipeline's feedback protocol, and finalizes at a
    // content-only close. Tool rounds persist the round rows, then the
    // next round streams over the grown wire. Errors finalize ONCE.
    Future<void> runRound(int roundIndex) async {
      var streamingRow = Message(
        id: generateUuidV4(),
        conversationId: forkConversationId,
        role: MessageRole.assistant,
        content: '',
        createdAt: DateTime.now(),
        status: MessageStatus.streaming,
        modelId: effectiveModelId,
        threadOrder: nextThreadOrder,
      );
      _upsertTranscript(streamingRow);

      var content = '';
      var reasoningContent = '';
      final roundCalls = <cs.ToolCallData>[];

      final responseQueue = StreamQueue<ChatResponse>(
        chatService.sendMessage(
          server: server,
          modelId: effectiveModelId,
          messages: List.of(wire),
          params: ref.read(chatParamsProvider),
          tools: forkTools == null ? null : List.of(forkTools),
        ),
      );

      // A stream that THROWS (as opposed to yielding an error-data event)
      // must still finalize once and settle — an escaping error would
      // leave _exchangeSettle pending forever and cancelAndSettle
      // dead-waits.
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
              _bumpTranscript(streamingRow);
            case ChatResponseType.reasoning:
              reasoningContent += response.reasoningContent ?? '';
              streamingRow = streamingRow.copyWith(
                reasoningContent: reasoningContent,
                isProcessing: false,
              );
              _bumpTranscript(streamingRow);
            case ChatResponseType.processing:
              streamingRow = streamingRow.copyWith(
                isProcessing: true,
              );
              _bumpTranscript(streamingRow);
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
              await _finalize(
                streamingRow,
                failure: streamingRow.errorMessage,
              );
              if (!finished.isCompleted) finished.complete();
              return;
            case ChatResponseType.invalidToolCall:
            case ChatResponseType.done:
              break;
          }
        }
      } catch (error) {
        // Same guard semantics as the error-data branch: finalize ONCE as
        // an error turn (no done re-finalization), surface the failure and
        // settle — the settle deliberately cannot fail to complete.
        errorFinalized = true;
        try {
          streamingRow = streamingRow.copyWith(
            status: MessageStatus.error,
            errorMessage: error.toString(),
            isProcessing: false,
          );
          await _finalize(streamingRow, failure: error.toString());
        } catch (finalizeError) {
          Log.error('Fork stream-throw finalize failed: $finalizeError');
          if (ref.mounted) {
            state = state.copyWith(
              isStreaming: false,
              failure: error.toString(),
            );
          }
        } finally {
          if (!finished.isCompleted) finished.complete();
        }
        return;
      }

      if (errorFinalized) {
        // The error branch already finalized this turn and left the
        // failure surfaced — do not overwrite the error state when the
        // stream simply closes after the error response.
        if (!finished.isCompleted) finished.complete();
        return;
      }
      if (roundCalls.isEmpty) {
        final hasContent = content.trim().isNotEmpty ||
            reasoningContent.trim().isNotEmpty;
        if (_cancelled) {
          // A forwarded cancel keeps the partially received content in
          // the transcript instead of surfacing a failure.
          await _finalize(
            streamingRow.copyWith(
              status: MessageStatus.complete,
              isProcessing: false,
              stopReason: 'cancelled',
            ),
          );
        } else if (!hasContent) {
          // Forensics for the no-token close (device round: GLM spends 60s+
          // pre-first-token — the wire/tool/approval context distinguishes a
          // dead uplink from a refused prompt). User-facing copy unchanged.
          Log.error(
            'Fork empty reply {fork: $forkConversationId, round: $roundIndex, '
            'wireRoles: ${wire.length}, toolsSent: ${forkTools?.length ?? 0}, '
            'hadApproval: $exchangeHadApproval, '
            'elapsedMs: ${exchangeClock.elapsedMilliseconds}}',
          );
          await _finalize(
            streamingRow.copyWith(
              status: MessageStatus.error,
              errorMessage:
                  'Model failed to respond. This may happen with free tier '
                  'models that refuse certain prompts or when the service is '
                  'busy.',
              isProcessing: false,
            ),
            failure: 'The model returned an empty reply for this fork.',
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
        if (!finished.isCompleted) finished.complete();
        return;
      }

      // A tool round: the stream closed with pending calls — budget guard,
      // then persist round + feedback rows through the SHARED executor with
      // the fork approval gate.
      if (roundIndex >= bgMaxToolRounds) {
        streamingRow = streamingRow.copyWith(
          status: MessageStatus.error,
          errorMessage:
              'Tool round limit reached ($bgMaxToolRounds) without a '
              'final answer.',
          isProcessing: false,
        );
        await _finalize(
          streamingRow,
          failure: streamingRow.errorMessage,
        );
        if (!finished.isCompleted) finished.complete();
        return;
      }
      final ToolRoundRows roundResult;
      try {
        roundResult = await executeToolRound(
          ToolRoundSpec(
            conversationId: forkConversationId,
            wire: wire,
            nextThreadOrder: nextThreadOrder,
            streamedContent: content,
            calls: List.of(roundCalls),
            allowedToolNames: {
              for (final def in forkTools ?? const <ToolDefinition>[])
                def.name,
            },
            approvalGate: _forkApprovalGate(),
            executeTool: (toolName, arguments) =>
                ref.read(toolRegistryProvider).execute(toolName, arguments),
            persistRow: persistMessage,
            buildRoundRow: ({
              required content,
              required toolCalls,
              required threadOrder,
            }) =>
                Message(
              id: streamingRow.id,
              conversationId: forkConversationId,
              role: MessageRole.assistant,
              content: content,
              createdAt: DateTime.now(),
              status: MessageStatus.complete,
              modelId: effectiveModelId,
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
              conversationId: forkConversationId,
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
        // The tool round machinery itself must not tear the whole exchange
        // down without a persisted turn: finalize the reset streaming row.
        streamingRow = streamingRow.copyWith(
          status: MessageStatus.error,
          errorMessage: error.toString(),
          isProcessing: false,
        );
        await _finalize(
          streamingRow,
          failure: error.toString(),
        );
        if (!finished.isCompleted) finished.complete();
        return;
      }

      nextThreadOrder = roundResult.nextThreadOrder;

      // Transcript mirrors the persisted protocol: the round row replaces
      // its streaming twin (same id), then each feedback row lands.
      _upsertTranscript(roundResult.roundRow);
      for (final feedback in roundResult.feedbackRows) {
        _upsertTranscript(feedback);
      }
      if (!ref.mounted) {
        if (!finished.isCompleted) finished.complete();
        return;
      }
      // Fix round 1: no round EVER follows a cancelled exchange or a panel
      // that went away mid-round — firing the next generation here would
      // (worst case) raise a fresh approval chip behind a dead panel that
      // nobody can settle. Finalize ONCE with the current exchange
      // content: the round row keeps its toolCalls (same id, upsert).
      if (_exchangeOrphaned) {
        final orphanedRow = roundResult.roundRow.copyWith(
          status: MessageStatus.complete,
          isProcessing: false,
          stopReason: 'cancelled',
        );
        try {
          await _finalize(orphanedRow);
        } catch (finalizeError) {
          Log.error('Fork orphaned-exchange finalize failed: $finalizeError');
          if (ref.mounted) {
            state = state.copyWith(isStreaming: false);
          }
        } finally {
          if (!finished.isCompleted) finished.complete();
        }
        return;
      }
      return runRound(roundIndex + 1);
    }

    await runRound(0);

    try {
      await finished.future;
    } finally {
      _exchangeSettle = null;
      _disposeStream();
    }
  }

  /// Marks the exchange's owning panel as detached. Called by the overlay
  /// controller whenever the panel over THIS fork closes, swaps to another
  /// anchor or tears down. Between tool rounds the notifier then finalizes
  /// instead of firing the next generation behind a dead panel (no chip
  /// can re-raise somewhere invisible). Reset per [submit].
  void notePanelDetached() {
    _panelDetached = true;
  }

  /// Whether the active exchange lost its owner surface and must not fire
  /// further generations: it was cancelled, the container is gone, or the
  /// panel detached from THIS fork and is not (re-)open for it now. A
  /// panel that is open again for this fork resumes the live exchange —
  /// the round actor is still producing its answer for that same surface.
  bool get _exchangeOrphaned {
    if (_cancelled) return true;
    if (!ref.mounted) return true;
    final anchor = ref.read(forkPanelOverlayProvider).anchor;
    final panelMine =
        anchor != null && anchor.forkConversationId == forkConversationId;
    return _panelDetached && !panelMine;
  }

  /// Forwards cancellation to the active fork reply's [ChatService] — the
  /// same mechanism `ChatNotifier.cancelStream` uses for main-chat replies.
  /// A pending approval (the round sits inside the gate) is settled as a
  /// denial so the awaiting exchange cannot dead-wait on a gone panel.
  void cancel() {
    if (!state.isStreaming) return;
    _cancelled = true;
    _chatService?.cancelStream();
    settlePendingApproval();
  }

  /// Cancels the active fork reply (if any) and awaits its terminal
  /// finalize so callers that mutate persisted fork data (deleteFork) can
  /// never race an in-flight exchange: after this resolves, every turn the
  /// notifier was going to persist has been persisted.
  Future<void> cancelAndSettle() async {
    if (!state.isStreaming) return;
    cancel();
    final Completer<void>? settle = _exchangeSettle;
    if (settle != null) {
      await settle.future;
    }
  }

  /// Reads the fork conversation's own persisted turns. Overridden in tests
  /// (the host unit-test toolchain cannot load libobjectbox.so).
  @protected
  @visibleForTesting
  Future<List<Message>> loadForkMessages(String forkConversationId) async {
    final db = ref.read(databaseProvider);
    return db.store.runInTransactionAsync(
      TxMode.read,
      _loadForkMessagesInBackground,
      forkConversationId,
    );
  }

  static List<Message> _loadForkMessagesInBackground(
    Store store,
    String forkConversationId,
  ) {
    final messageBox = store.box<MessageEntity>();
    final query = messageBox
        .query(MessageEntity_.conversationUid.equals(forkConversationId))
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

  /// Writes a fork turn to ObjectBox. Overridden in tests.
  @protected
  @visibleForTesting
  Future<void> persistMessage(Message message) async {
    final db = ref.read(databaseProvider);
    await db.store.runInTransactionAsync(
      TxMode.write,
      _persistForkMessageInBackground,
      message,
    );
  }

  /// Same save pattern as ChatNotifier's message persistence: upsert by
  /// message id and link/set `conversationUid` to the fork conversation id.
  static void _persistForkMessageInBackground(Store store, Message message) {
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

  /// Trims trailing dangling tool-chain rows (assistant(tool_calls) + tool)
  /// from a sliced main-context tail. Never touches system rows; a plain
  /// assistant(content) or user tail row ends the trim.
  static List<Message> _trimDanglingToolTail(List<Message> assembled) {
    var end = assembled.length;
    bool isDangling(Message message) {
      if (message.role == MessageRole.tool) return true;
      return message.role == MessageRole.assistant &&
          (message.toolCalls?.isNotEmpty ?? false);
    }

    while (end > 0 && isDangling(assembled[end - 1])) {
      end--;
    }
    return assembled.sublist(0, end);
  }

  /// Transcript seam that ADDS or replaces-by-id: streaming rounds bump the
  /// active assistant row, tool rounds append their feedback rows, and
  /// final rows append themselves — replace-by-id is what keeps the round
  /// row (same id as its streamed twin) a single transcript entry.
  void _upsertTranscript(Message row) {
    if (!ref.mounted) return;
    final copy = List.of(state.transcript);
    final index = copy.indexWhere((existing) => existing.id == row.id);
    if (index >= 0) {
      copy[index] = row;
    } else {
      copy.add(row);
    }
    state = state.copyWith(transcript: copy);
  }

  void _bumpTranscript(Message updated) => _upsertTranscript(updated);

  Future<void> _finalize(Message finalRow, {String? failure}) async {
    await persistMessage(finalRow);
    if (!ref.mounted) return;
    _upsertTranscript(finalRow);
    state = state.copyWith(
      isStreaming: false,
      failure: failure,
      clearFailure: failure == null,
    );
  }

  void _failAndStop(String message) {
    if (!ref.mounted) return;
    state = state.copyWith(isStreaming: false, failure: message);
    // Typed rejections never start the stream; the settle future would
    // otherwise stay pending for anyone awaiting cancelAndSettle.
    final Completer<void>? settle = _exchangeSettle;
    if (settle != null && !settle.isCompleted) {
      settle.complete();
    }
  }

  void _disposeStream() {
    final subscription = _streamSubscription;
    _streamSubscription = null;
    _chatService = null;
    _cancelled = false;
    _panelDetached = false;
    // Defense in depth: a torn-down slot must never leave a pending
    // approval completer dangling (settle is idempotent). The mirror is
    // resolved WITHOUT touching `state` — riverpod 3 forbids state use in
    // dispose life-cycles.
    final pending = _pendingApproval;
    _pendingApproval = null;
    if (pending != null) {
      pending.settleAsDenied();
    }
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
  }
}
