import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/storage/entities.dart';
import 'package:localmind/features/chat/data/chat_service.dart'
    hide ToolCallData;
import 'package:localmind/features/chat/data/fork_service.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/providers/chat_notifier.dart';
import 'package:localmind/features/chat/providers/chat_params_providers.dart';
import 'package:localmind/features/chat/providers/chat_service_providers.dart';
import 'package:localmind/features/chat/providers/model_selection_providers.dart';
import 'package:localmind/objectbox.g.dart';

/// State of one fork (selection-anchored) chat.
///
/// [transcript] carries the fork conversation's own user + assistant turns
/// in chronological order; [failure] surfaces the last typed rejection
/// (e.g. an anchor no longer on the active timeline) or stream error, and
/// is reset when the next [ForkChatNotifier.submit] starts.
class ForkChatState {
  final List<Message> transcript;
  final bool isStreaming;
  final String? failure;

  const ForkChatState({
    this.transcript = const [],
    this.isStreaming = false,
    this.failure,
  });

  ForkChatState copyWith({
    List<Message>? transcript,
    bool? isStreaming,
    String? failure,
    bool clearFailure = false,
  }) {
    return ForkChatState(
      transcript: transcript ?? this.transcript,
      isStreaming: isStreaming ?? this.isStreaming,
      failure: clearFailure ? null : (failure ?? this.failure),
    );
  }
}

/// Streams replies for one fork (selection-anchored) conversation and
/// persists every exchange — user turn + assistant turn — into its hidden
/// fork conversation.
///
/// The family is keyed by the fork conversation id; each instance owns its
/// transcript and builds its ChatService through the same
/// [chatServiceFactoryProvider] the main sends use (no second Dio/config
/// path), with `cancel()` forwarding to `ChatService.cancelStream()` just
/// like `ChatNotifier.cancelStream` does. Forks are plain Q/A v1: no
/// integrations, no tool loop, no background continuation machinery.
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

  ChatService? _chatService;
  StreamSubscription<ChatResponse>? _streamSubscription;
  bool _cancelled = false;

  @override
  ForkChatState build() {
    ref.onDispose(_disposeStream);
    return const ForkChatState();
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
      _failAndStop(
        'The anchored message is no longer part of the active timeline '
        '(it may be an inactive variant). Re-create the fork from an '
        'active message.',
      );
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
    var streamingAssistant = Message(
      id: _generateUuid(),
      conversationId: forkConversationId,
      role: MessageRole.assistant,
      content: '',
      createdAt: DateTime.now(),
      status: MessageStatus.streaming,
      modelId: effectiveModelId,
      threadOrder: forkTurns.length + 1,
    );

    state = state.copyWith(
      transcript: [...forkTurns, userRow, streamingAssistant],
    );

    // The user turn persists up front; the assistant row persists when it
    // finalizes (complete/error/cancelled) — one row per turn.
    await persistMessage(userRow);
    if (!ref.mounted) {
      _failAndStop('Chat closed before the fork reply started.');
      return;
    }

    _chatService = chatService;
    final finished = Completer<void>();

    _streamSubscription = chatService
        .sendMessage(
          server: server,
          modelId: effectiveModelId,
          messages: wire,
          params: ref.read(chatParamsProvider),
        )
        .listen(
          (response) async {
            switch (response.type) {
              case ChatResponseType.message:
                streamingAssistant = streamingAssistant.copyWith(
                  content:
                      streamingAssistant.content + (response.content ?? ''),
                  isProcessing: false,
                );
                _bumpTranscript(streamingAssistant);
                break;
              case ChatResponseType.reasoning:
                streamingAssistant = streamingAssistant.copyWith(
                  reasoningContent:
                      (streamingAssistant.reasoningContent ?? '') +
                      (response.reasoningContent ?? ''),
                  isProcessing: false,
                );
                _bumpTranscript(streamingAssistant);
                break;
              case ChatResponseType.processing:
                streamingAssistant = streamingAssistant.copyWith(
                  isProcessing: true,
                );
                _bumpTranscript(streamingAssistant);
                break;
              case ChatResponseType.error:
              case ChatResponseType.timeoutError:
                final failure =
                    response.content ?? 'The model failed to respond.';
                await _finalize(
                  streamingAssistant.copyWith(
                    status: MessageStatus.error,
                    errorMessage: failure,
                    isProcessing: false,
                  ),
                  failure: failure,
                );
                if (!finished.isCompleted) finished.complete();
                break;
              case ChatResponseType.toolCall:
              case ChatResponseType.invalidToolCall:
              case ChatResponseType.done:
                // Forks are plain Q/A v1: no tool loop. The `done` event is
                // finalized by the stream's own onDone below.
                break;
            }
          },
          onDone: () async {
            final hasContent =
                streamingAssistant.content.trim().isNotEmpty ||
                (streamingAssistant.reasoningContent?.trim().isNotEmpty ??
                    false);
            if (_cancelled) {
              // A forwarded cancel keeps the partially received content in
              // the transcript instead of surfacing a failure.
              await _finalize(
                streamingAssistant.copyWith(
                  status: MessageStatus.complete,
                  isProcessing: false,
                  stopReason: 'cancelled',
                ),
              );
            } else if (!hasContent) {
              await _finalize(
                streamingAssistant.copyWith(
                  status: MessageStatus.error,
                  errorMessage:
                      'Model failed to respond. This may happen with free '
                      'tier models that refuse certain prompts or when the '
                      'service is busy.',
                  isProcessing: false,
                ),
                failure: 'The model returned an empty reply for this fork.',
              );
            } else {
              await _finalize(
                streamingAssistant.copyWith(
                  status: MessageStatus.complete,
                  isProcessing: false,
                  stopReason: 'complete',
                ),
              );
            }
            if (!finished.isCompleted) finished.complete();
          },
          onError: (Object error, StackTrace stackTrace) async {
            await _finalize(
              streamingAssistant.copyWith(
                status: MessageStatus.error,
                errorMessage: error.toString(),
                isProcessing: false,
              ),
              failure: error.toString(),
            );
            if (!finished.isCompleted) finished.complete();
          },
          cancelOnError: true,
        );

    try {
      await finished.future;
    } finally {
      _disposeStream();
    }
  }

  /// Forwards cancellation to the active fork reply's [ChatService] — the
  /// same mechanism `ChatNotifier.cancelStream` uses for main-chat replies.
  void cancel() {
    if (!state.isStreaming) return;
    _cancelled = true;
    _chatService?.cancelStream();
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

  void _bumpTranscript(Message updated) {
    if (!ref.mounted) return;
    state = state.copyWith(transcript: _replaceLast(state.transcript, updated));
  }

  Future<void> _finalize(Message finalRow, {String? failure}) async {
    await persistMessage(finalRow);
    if (!ref.mounted) return;
    state = state.copyWith(
      transcript: _replaceLast(state.transcript, finalRow),
      isStreaming: false,
      failure: failure,
      clearFailure: failure == null,
    );
  }

  void _failAndStop(String message) {
    if (!ref.mounted) return;
    state = state.copyWith(isStreaming: false, failure: message);
  }

  static List<Message> _replaceLast(List<Message> rows, Message replacement) {
    final copy = List.of(rows);
    if (copy.isEmpty) {
      copy.add(replacement);
      return copy;
    }
    copy[copy.length - 1] = replacement;
    return copy;
  }

  void _disposeStream() {
    final subscription = _streamSubscription;
    _streamSubscription = null;
    _chatService = null;
    _cancelled = false;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
  }

  static String _generateUuid() {
    final secure = Random.secure();
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final r1 = secure.nextInt(0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    final r2 = secure.nextInt(0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    return '$now-$r1-$r2';
  }
}
