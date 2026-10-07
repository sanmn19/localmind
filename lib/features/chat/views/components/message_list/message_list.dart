import 'package:hugeicons/hugeicons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/data/tool_activity_grouping.dart';
import 'package:localmind/features/chat/providers/chat_providers.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart';
import 'package:localmind/l10n/app_localizations.dart';
import '../chat_bubble.dart';
import 'components/tool_activity_block.dart';

class MessageList extends StatelessWidget {
  const MessageList({
    super.key,
    required this.scrollController,
    required this.messages,
    required this.allMessages,
    required this.isStreaming,
    required this.onRetry,
    required this.onDelete,
    required this.onEdit,
    required this.onEditAssistant,
    required this.onBranch,
    required this.onContinue,
    required this.onCycleVariant,
    required this.onModelPicker,
    this.onModelLongPress,
    this.onSave,
    this.onShare,
    this.onGenerateResponse,
    this.hasSmartReplies = false,
    this.bottomInset = 0,
  });

  final ScrollController scrollController;
  final List<Message> messages;
  final List<Message> allMessages;
  final bool isStreaming;
  final void Function(String) onRetry;
  final void Function(String) onDelete;
  final void Function(String messageId, String currentContent) onEdit;
  final void Function(String messageId, String currentContent) onEditAssistant;
  final void Function(String messageId) onBranch;
  final void Function(String messageId) onContinue;
  final void Function(String messageId, int direction) onCycleVariant;
  final VoidCallback onModelPicker;
  final void Function(String modelId)? onModelLongPress;
  final void Function(Message message)? onSave;
  final void Function(Message message)? onShare;
  final VoidCallback? onGenerateResponse;
  final bool hasSmartReplies;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    return _MessageListConsumer(
      scrollController: scrollController,
      messages: messages,
      allMessages: allMessages,
      isStreaming: isStreaming,
      onRetry: onRetry,
      onDelete: onDelete,
      onEdit: onEdit,
      onEditAssistant: onEditAssistant,
      onBranch: onBranch,
      onContinue: onContinue,
      onCycleVariant: onCycleVariant,
      onModelPicker: onModelPicker,
      onModelLongPress: onModelLongPress,
      onSave: onSave,
      onShare: onShare,
      onGenerateResponse: onGenerateResponse,
      hasSmartReplies: hasSmartReplies,
      bottomInset: bottomInset,
    );
  }
}

class _MessageListConsumer extends ConsumerStatefulWidget {
  const _MessageListConsumer({
    required this.scrollController,
    required this.messages,
    required this.allMessages,
    required this.isStreaming,
    required this.onRetry,
    required this.onDelete,
    required this.onEdit,
    required this.onEditAssistant,
    required this.onBranch,
    required this.onContinue,
    required this.onCycleVariant,
    required this.onModelPicker,
    this.onModelLongPress,
    this.onSave,
    this.onShare,
    this.onGenerateResponse,
    this.hasSmartReplies = false,
    this.bottomInset = 0,
  });

  final ScrollController scrollController;
  final List<Message> messages;
  final List<Message> allMessages;
  final bool isStreaming;
  final void Function(String) onRetry;
  final void Function(String) onDelete;
  final void Function(String messageId, String currentContent) onEdit;
  final void Function(String messageId, String currentContent) onEditAssistant;
  final void Function(String messageId) onBranch;
  final void Function(String messageId) onContinue;
  final void Function(String messageId, int direction) onCycleVariant;
  final VoidCallback onModelPicker;
  final void Function(String modelId)? onModelLongPress;
  final void Function(Message message)? onSave;
  final void Function(Message message)? onShare;
  final VoidCallback? onGenerateResponse;
  final bool hasSmartReplies;
  final double bottomInset;

  @override
  ConsumerState<_MessageListConsumer> createState() =>
      _MessageListConsumerState();
}

class _MessageListConsumerState extends ConsumerState<_MessageListConsumer> {
  final _messageKeys = <String, GlobalKey>{};
  bool _checkedInitialScrollTarget = false;

  @override
  void didUpdateWidget(covariant _MessageListConsumer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final activeIds = widget.messages.map((m) => m.id).toSet();
    _messageKeys.removeWhere((id, _) => !activeIds.contains(id));
  }

  void _scrollToMessage(String messageId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key = _messageKeys[messageId];
      final targetContext = key?.currentContext;
      if (targetContext != null) {
        Scrollable.ensureVisible(
          targetContext,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: 0.3,
        );
      }
      ref.read(scrollToMessageIdProvider.notifier).clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(scrollToMessageIdProvider, (previous, next) {
      if (next != null) {
        _scrollToMessage(next);
      }
    });

    if (!_checkedInitialScrollTarget) {
      _checkedInitialScrollTarget = true;
      final pendingScroll = ref.read(scrollToMessageIdProvider);
      if (pendingScroll != null) {
        _scrollToMessage(pendingScroll);
      }
    }

    final streamingMessage = ref.watch(
      chatProvider.select((s) => s.streamingMessage),
    );

    return _MessageList(
      scrollController: widget.scrollController,
      messages: widget.messages,
      allMessages: widget.allMessages,
      streamingMessage: streamingMessage,
      isStreaming: widget.isStreaming,
      messageKeys: _messageKeys,
      onRetry: widget.onRetry,
      onDelete: widget.onDelete,
      onEdit: widget.onEdit,
      onEditAssistant: widget.onEditAssistant,
      onBranch: widget.onBranch,
      onContinue: widget.onContinue,
      onCycleVariant: widget.onCycleVariant,
      onModelPicker: widget.onModelPicker,
      onModelLongPress: widget.onModelLongPress,
      onSave: widget.onSave,
      onShare: widget.onShare,
      onGenerateResponse: widget.onGenerateResponse,
      hasSmartReplies: widget.hasSmartReplies,
      bottomInset: widget.bottomInset,
    );
  }
}

class _MessageList extends ConsumerWidget {
  const _MessageList({
    required this.scrollController,
    required this.messages,
    required this.allMessages,
    required this.streamingMessage,
    required this.isStreaming,
    required this.messageKeys,
    required this.onRetry,
    required this.onDelete,
    required this.onEdit,
    required this.onEditAssistant,
    required this.onBranch,
    required this.onContinue,
    required this.onCycleVariant,
    required this.onModelPicker,
    this.onModelLongPress,
    this.onSave,
    this.onShare,
    this.onGenerateResponse,
    this.hasSmartReplies = false,
    this.bottomInset = 0,
  });

  final ScrollController scrollController;
  final List<Message> messages;
  final List<Message> allMessages;
  final Message? streamingMessage;
  final bool isStreaming;
  final Map<String, GlobalKey> messageKeys;
  final void Function(String) onRetry;
  final void Function(String) onDelete;
  final void Function(String messageId, String currentContent) onEdit;
  final void Function(String messageId, String currentContent) onEditAssistant;
  final void Function(String messageId) onBranch;
  final void Function(String messageId) onContinue;
  final void Function(String messageId, int direction) onCycleVariant;
  final VoidCallback onModelPicker;
  final void Function(String modelId)? onModelLongPress;
  final void Function(Message message)? onSave;
  final void Function(Message message)? onShare;
  final VoidCallback? onGenerateResponse;
  final bool hasSmartReplies;
  final double bottomInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectionMode = ref.watch(messageSelectionModeProvider);
    final selectedIds = ref.watch(selectedMessageIdsProvider);
    final showSystemMessages = ref.watch(
      settingsProvider.select((s) => s.showSystemMessagesInChat),
    );
    final visibleMessages = <Message>[];

    // The streaming message only belongs at the end of the currently
    // displayed branch if that branch's active timeline actually resolves
    // to it — otherwise the user has cycled to a different variant while
    // a sibling variant is still generating in the background, and the
    // live bubble must not be appended to whatever branch is now on screen.
    final streamingBelongsToActiveTimeline =
        streamingMessage != null &&
        messages.any((m) => m.id == streamingMessage!.id);

    for (final message in messages) {
      if (!showSystemMessages && message.role == MessageRole.system) {
        continue;
      }
      if (streamingBelongsToActiveTimeline &&
          message.id == streamingMessage!.id &&
          isStreaming) {
        continue;
      }
      visibleMessages.add(message);
    }

    final showTrailingStreamingBubble =
        streamingBelongsToActiveTimeline && isStreaming;

    // Multi-round tool chains resolve into their newest round only; the
    // per-round activity (searches, fetches, thinking) is consolidated into
    // one "Web activity" card rendered above the answering tail. Rows whose
    // parent assistant turn got resolved into a block disappear from the
    // list; anything else (orphan tool rows) keeps its original rendering.
    final blockByMessageId = <String, ToolActivitySnapshot>{};
    final consumedToolRowIds = <String>{};
    for (final message in visibleMessages) {
      if (message.role != MessageRole.assistant) continue;
      final snapshot = toolActivityForChain(allMessages, message);
      if (snapshot == null) continue;
      blockByMessageId[message.id] = snapshot;
      for (final row in chainToolMessages(allMessages, message)) {
        consumedToolRowIds.add(row.id);
      }
    }

    final timeline = visibleMessages
        .where(
          (message) =>
              !(message.role == MessageRole.tool &&
                  consumedToolRowIds.contains(message.id)),
        )
        .toList();

    return ListView.builder(
      controller: scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.only(
        top: 16,
        bottom: 120 + (hasSmartReplies ? 64 : 0) + bottomInset,
      ),
      itemCount: timeline.length + (showTrailingStreamingBubble ? 1 : 0),
      itemBuilder: (context, index) {
        if (showTrailingStreamingBubble && index == timeline.length) {
          final live = streamingMessage!;
          final streamingSnapshot = live.role == MessageRole.assistant
              ? toolActivityForChain(allMessages, live)
              : null;
          final bubble = ChatBubble(
            key: ValueKey(live.id),
            message: live,
            allMessages: allMessages,
            isStreaming: true,
            onModelTap: onModelPicker,
            showReasoning: streamingSnapshot?.reasoning?.isNotEmpty != true,
          );
          if (streamingSnapshot == null) return bubble;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ToolActivityBlock(snapshot: streamingSnapshot),
              bubble,
            ],
          );
        }

        final message = timeline[index];
        final isLast = index == timeline.length - 1;
        final itemKey = messageKeys.putIfAbsent(message.id, GlobalKey.new);
        final snapshot = blockByMessageId[message.id];
        final showsThinking = snapshot?.reasoning?.isNotEmpty == true;

        final bubble = ChatBubble(
          key: itemKey,
          message: message,
          allMessages: allMessages,
          isStreaming:
              isLast &&
              showTrailingStreamingBubble &&
              message.id == streamingMessage?.id,
          showReasoning: !showsThinking,
          onRetry: () => onRetry(message.id),
          onDelete: () => onDelete(message.id),
          onEdit: message.role == MessageRole.user
              ? () => onEdit(message.id, message.content)
              : message.role == MessageRole.assistant
              ? () => onEditAssistant(message.id, message.content)
              : null,
          onBranch: () => onBranch(message.id),
          onContinue: message.role == MessageRole.assistant && isLast
              ? () => onContinue(message.id)
              : null,
          onCycleVariant: (direction) => onCycleVariant(message.id, direction),
          onModelTap: onModelPicker,
          onModelLongPress:
              message.modelId != null &&
                  message.role == MessageRole.assistant &&
                  onModelLongPress != null
              ? () => onModelLongPress!(message.modelId!)
              : null,
          onSave: onSave,
          onShare: onShare == null ? null : () => onShare!(message),
        );
        final wrappedBubble = snapshot == null
            ? bubble
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ToolActivityBlock(snapshot: snapshot),
                  bubble,
                ],
              );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (selectionMode)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: selectedIds.contains(message.id),
                    onChanged: (_) => ref
                        .read(selectedMessageIdsProvider.notifier)
                        .toggle(message.id),
                  ),
                  Expanded(child: wrappedBubble),
                ],
              )
            else
              wrappedBubble,
            if (!isStreaming &&
                isLast &&
                message.role == MessageRole.user &&
                onGenerateResponse != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: onGenerateResponse,
                    icon: const HugeIcon(
                      icon: HugeIcons.strokeRoundedSparkles,
                      size: 16,
                    ),
                    label: Text(
                      AppLocalizations.of(context)!.generate_ai_response,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
