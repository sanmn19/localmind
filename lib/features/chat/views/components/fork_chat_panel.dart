import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/l10n/app_localizations.dart';

import '../../data/fork_service.dart';
import '../../data/models/fork_anchor.dart';
import '../../data/models/message.dart';
import '../../providers/fork_chat_notifier.dart';
import 'chat_bubble/markdown/themed_gpt_markdown.dart';
import 'typing_indicator.dart';

/// The floating chat surface for one selection-anchored fork chat
/// (selection-fork-chats spec, UX items 4-7). Pure overlay content: no
/// route, no barrier — the anchored overlay host (`forkPanelOverlay`)
/// inserts it above the chat screen and owns dismissal plumbing.
///
/// - Transcript is pinned to the newest turn at the bottom (own
///   [ScrollController], reverse list).
/// - The input row submits through [forkChatNotifierProvider] with the
///   anchor context; it disables while the fork reply is streaming.
/// - A mid-stream failure renders as a banner; the send row re-enables so
///   the user can retry immediately.
/// - The panel never deletes fork data itself. The explicit delete action
///   cancels + settles the active exchange, drops the fork through
///   [ForkService.deleteFork] and invalidates the conversation's anchors so
///   the highlight band/chip disappears live.
class ForkChatPanel extends ConsumerStatefulWidget {
  const ForkChatPanel({
    super.key,
    required this.anchor,
    required this.onClose,
  });

  final ForkAnchor anchor;
  final VoidCallback onClose;

  @override
  ConsumerState<ForkChatPanel> createState() => _ForkChatPanelState();
}

class _ForkChatPanelState extends ConsumerState<ForkChatPanel> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _forkInputFocus = FocusNode();
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _inputController.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _forkInputFocus.dispose();
    super.dispose();
  }

  void _submit(ForkChatState fork) {
    final text = _inputController.text.trim();
    if (text.isEmpty || fork.isStreaming) {
      return;
    }
    _inputController.clear();
    unawaited(
      ref
          .read(
            forkChatNotifierProvider(widget.anchor.forkConversationId)
                .notifier,
          )
          .submit(
            widget.anchor.forkConversationId,
            text,
            selectedText: widget.anchor.selectedText,
            anchorMessageId: widget.anchor.anchorMessageId,
          ),
    );
  }

  Future<void> _deleteFork() async {
    if (_deleting) {
      return;
    }
    _deleting = true;
    final forkId = widget.anchor.forkConversationId;
    // Cancel + settle first: a mid-stream delete must not race the turn
    // finalize, otherwise an orphan fork row survives the deleted fork.
    await ref
        .read(forkChatNotifierProvider(forkId).notifier)
        .cancelAndSettle();
    await ref.read(forkServiceProvider).deleteFork(widget.anchor.id);
    // The highlight band/chip rebuilds as soon as the anchors provider
    // refreshes — refresh both bubble and panel against the deleted anchor.
    ref.invalidate(
      forkAnchorsForConversationProvider(widget.anchor.mainConversationId),
    );
    if (!mounted) {
      return;
    }
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final fork = ref.watch(
      forkChatNotifierProvider(widget.anchor.forkConversationId),
    );
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(l10n, theme),
          Divider(height: 1, thickness: 0.5, color: theme.colorScheme.outline),
          Expanded(child: _buildTranscript(fork, theme, l10n)),
          if (fork.failure != null) _buildFailureBanner(fork.failure!, theme),
          _buildInputRow(fork, theme, l10n),
        ],
      ),
    );
  }

  Widget _buildHeader(AppLocalizations l10n, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '"${widget.anchor.selectedText}"',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('fork_panel_delete'),
            tooltip: l10n.forkPanelDeleteTooltip,
            iconSize: 18,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: _deleting ? null : () => unawaited(_deleteFork()),
          ),
          IconButton(
            key: const ValueKey('fork_panel_close'),
            tooltip: l10n.forkPanelCloseTooltip,
            iconSize: 18,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            icon: const Icon(Icons.close_rounded),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _buildTranscript(
    ForkChatState fork,
    ThemeData theme,
    AppLocalizations l10n,
  ) {
    final transcript = fork.transcript;
    if (transcript.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: Text(
            l10n.forkPanelEmptyBody,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: transcript.length,
      itemBuilder: (context, index) {
        final message = transcript[transcript.length - 1 - index];
        return _ForkTurnRow(
          message: message,
          isStreamingRow: fork.isStreaming && index == 0,
          isDark: theme.brightness == Brightness.dark,
        );
      },
    );
  }

  Widget _buildFailureBanner(String failure, ThemeData theme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 14,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              failure,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputRow(
    ForkChatState fork,
    ThemeData theme,
    AppLocalizations l10n,
  ) {
    final canSend =
        !fork.isStreaming && _inputController.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('fork_panel_input'),
              controller: _inputController,
              focusNode: _forkInputFocus,
              enabled: !fork.isStreaming,
              maxLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(fork),
              style: TextStyle(
                fontSize: 14,
                color: theme.colorScheme.onSurface,
              ),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                filled: true,
                fillColor:
                    theme.colorScheme.onSurface.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                hintText: l10n.forkPanelInputHint,
                hintStyle: TextStyle(
                  fontSize: 14,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            key: const ValueKey('fork_panel_send'),
            color: theme.colorScheme.primary,
            icon: const Icon(Icons.send_rounded),
            onPressed: canSend ? () => _submit(fork) : null,
          ),
        ],
      ),
    );
  }
}

class _ForkTurnRow extends StatelessWidget {
  const _ForkTurnRow({
    required this.message,
    required this.isStreamingRow,
    required this.isDark,
  });

  final Message message;
  final bool isStreamingRow;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (message.role == MessageRole.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          constraints: const BoxConstraints(maxWidth: 380),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            message.content,
            style: TextStyle(
              fontSize: 14,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
      );
    }

    final isError = message.status == MessageStatus.error;
    final showDots = isStreamingRow &&
        message.content.isEmpty &&
        (message.reasoningContent == null ||
            message.reasoningContent!.isEmpty);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showDots)
            const TypingIndicator()
          else if (isError)
            Text(
              'An error occurred: ${message.errorMessage ?? message.content}',
              style: TextStyle(fontSize: 13, color: theme.colorScheme.error),
            )
          else
            MarkdownBodyContent(
              content: message.content,
              isDark: isDark,
              selectable: false,
            ),
        ],
      ),
    );
  }
}
