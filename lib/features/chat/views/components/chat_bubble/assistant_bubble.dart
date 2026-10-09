import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/l10n/app_localizations.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/theme/colors.dart';
import 'package:localmind/features/chat/data/fork_service.dart';
import 'package:localmind/features/chat/data/models/fork_anchor.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/providers/fork_panel_overlay.dart';
import 'package:localmind/features/chat/views/components/processing_indicator.dart';
import 'package:localmind/features/chat/views/components/typing_indicator.dart';
import 'package:localmind/features/chat/views/components/reasoning_widget.dart';
import 'package:localmind/features/chat/views/components/message_action_bar.dart';
import 'package:localmind/features/chat/views/components/message_actions_sheet.dart';
import 'package:localmind/features/chat/views/components/message_variant_navigator.dart';
import 'markdown/themed_gpt_markdown.dart';
import 'tool_bubble/tool_timeline.dart';
import 'chat_error_display.dart';

const Color kForkHighlightColor = Color(0xFFFEF3C7);

class AssistantBubble extends StatelessWidget {
  const AssistantBubble({
    super.key,
    required this.message,
    this.onCopy,
    this.onRetry,
    this.onDelete,
    this.onEdit,
    this.onBranch,
    this.onContinue,
    this.onModelTap,
    this.onModelLongPress,
    this.onCycleVariant,
    this.onSave,
    this.onShare,
    this.allMessages = const [],
    this.isStreaming = false,
    this.showReasoning = true,
  });

  final Message message;
  final List<Message> allMessages;
  final VoidCallback? onCopy;
  final VoidCallback? onRetry;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;
  final VoidCallback? onBranch;
  final VoidCallback? onContinue;
  final void Function(Message message)? onSave;
  final VoidCallback? onShare;
  final VoidCallback? onModelTap;
  final VoidCallback? onModelLongPress;
  final void Function(int direction)? onCycleVariant;
  final bool isStreaming;

  /// Whether the bubble renders its own expandable reasoning block. Set to
  /// false when a chain's web activity card above the bubble already shows
  /// this round's thinking.
  final bool showReasoning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final muted = isDark ? AppColors.darkMutedText : AppColors.lightMutedText;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showReasoning &&
              message.reasoningContent != null &&
              message.reasoningContent!.isNotEmpty)
            ReasoningWidget(
              reasoningContent: message.reasoningContent,
              isStreaming: isStreaming,
              hasMainContent: message.content.trim().isNotEmpty,
            ),
          if (isStreaming && message.content.isEmpty && message.isProcessing)
            const ProcessingIndicator()
          else if (isStreaming && message.content.isEmpty)
            const TypingIndicator()
          else if (isStreaming)
            _StreamingContent(content: message.content, isDark: isDark)
          else if (message.content.isEmpty &&
              (message.reasoningContent?.isEmpty ?? true))
            Text(
              AppLocalizations.of(context)!.no_response,
              style: TextStyle(
                fontSize: 14,
                fontStyle: FontStyle.italic,
                color: muted,
              ),
            )
          else if (message.content.trim().isNotEmpty)
            _ForkAwareAssistantContent(message: message, isDark: isDark),
          if (message.status == MessageStatus.error &&
              message.errorMessage != null &&
              message.errorMessage!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
                ),
                child: ChatErrorDisplay(errorMessage: message.errorMessage!),
              ),
            ),
          if (message.toolEvents != null && message.toolEvents!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ToolTimeline(events: message.toolEvents!),
            ),
          if (isStreaming && message.content.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: _StreamingIndicator(),
            ),
          // The model name, time and generation stats live in the
          // actions sheet ("more") rather than under every reply.
          if (!isStreaming)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Transform.translate(
                    offset: const Offset(-10, 0),
                    child: MessageActionBar(
                      actions: MessageActions(
                        content: message.content.isEmpty
                            ? AppLocalizations.of(context)!.no_response
                            : message.content,
                        messageId: message.id,
                        conversationId: message.conversationId,
                        modelId: message.modelId,
                        createdAt: message.createdAt,
                        tokenCount: message.tokenCount,
                        inputTokenCount: message.inputTokenCount,
                        generationTimeMs: message.generationTimeMs,
                        ttftMs: message.ttftMs,
                        tokensPerSecond: message.tokensPerSecond,
                        stopReason: message.stopReason,
                        onCopy: onCopy,
                        onRetry: onRetry,
                        onDelete: onDelete,
                        onEdit: onEdit,
                        onBranch: onBranch,
                        onContinue: onContinue,
                        onSave: onSave == null ? null : () => onSave!(message),
                        onShare: onShare,
                        onModelInfo: onModelLongPress,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (onCycleVariant != null)
                    MessageVariantNavigator(
                      message: message,
                      allMessages: allMessages,
                      onCycle: onCycleVariant!,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StreamingContent extends StatefulWidget {
  const _StreamingContent({required this.content, required this.isDark});

  final String content;
  final bool isDark;

  @override
  State<_StreamingContent> createState() => _StreamingContentState();
}

class _StreamingContentState extends State<_StreamingContent> {
  static const Duration _updateInterval = Duration(milliseconds: 80);
  Timer? _flushTimer;
  String _visibleContent = '';

  @override
  void initState() {
    super.initState();
    _visibleContent = widget.content;
  }

  @override
  void didUpdateWidget(covariant _StreamingContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content == widget.content) {
      return;
    }

    if (widget.content.length < _visibleContent.length) {
      _flushTimer?.cancel();
      _visibleContent = widget.content;
      return;
    }

    _flushTimer ??= Timer(_updateInterval, () {
      _flushTimer = null;
      if (mounted) {
        setState(() {
          _visibleContent = widget.content;
        });
      }
    });
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MarkdownBodyContent(
      content: _visibleContent,
      isDark: widget.isDark,
      selectable: false,
    );
  }
}

class _StreamingIndicator extends StatefulWidget {
  const _StreamingIndicator();

  @override
  State<_StreamingIndicator> createState() => _StreamingIndicatorState();
}

class _StreamingIndicatorState extends State<_StreamingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<Animation<double>> _animations;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1100),
      vsync: this,
    )..repeat();

    _animations = List.generate(3, (index) {
      return Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(
          parent: _controller,
          curve: Interval(
            index * 0.2,
            0.6 + index * 0.2,
            curve: Curves.easeInOut,
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dotColor = isDark
        ? AppColors.darkMutedText
        : AppColors.lightMutedText;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (index) {
        return AnimatedBuilder(
          animation: _animations[index],
          builder: (context, child) {
            return Container(
              margin: EdgeInsets.only(right: index == 2 ? 0 : 4),
              child: Transform.translate(
                offset: Offset(0, -2.5 * _animations[index].value),
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: dotColor.withValues(
                      alpha: 0.35 + 0.65 * _animations[index].value,
                    ),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          },
        );
      }),
    );
  }
}

class _ForkAwareAssistantContent extends ConsumerStatefulWidget {
  const _ForkAwareAssistantContent({
    required this.message,
    required this.isDark,
  });

  final Message message;
  final bool isDark;

  @override
  ConsumerState<_ForkAwareAssistantContent> createState() =>
      _ForkAwareAssistantContentState();
}

class _ForkAwareAssistantContentState
    extends ConsumerState<_ForkAwareAssistantContent> {
  final LayerLink _forkLayerLink = LayerLink();

  /// Latest selection inside this bubble's SelectionArea, fed by the
  /// SelectionArea contract needed at menu-press time.
  SelectedContent? _lastSelection;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final overlay = Overlay.maybeOf(context);
    if (overlay != null) {
      ref.read(forkPanelOverlayProvider.notifier).attach(overlay);
    }
  }

  Widget _buildForkMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) {
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: selectableRegionState.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(
          label: AppLocalizations.of(context)!.forkFromSelection,
          onPressed: () {
            ContextMenuController.removeAny();
            unawaited(_createAndOpenFork(_lastSelection?.plainText ?? ''));
          },
        ),
        ...selectableRegionState.contextMenuButtonItems,
      ],
    );
  }

  Future<void> _createAndOpenFork(String selectedText) async {
    if (selectedText.trim().isEmpty) {
      return;
    }
    final anchor = await ref.read(forkServiceProvider).createFork(
      mainConversationId: widget.message.conversationId,
      anchorMessageId: widget.message.id,
      selectedText: selectedText,
    );
    if (!mounted) {
      return;
    }
    ref.invalidate(
      forkAnchorsForConversationProvider(widget.message.conversationId),
    );
    _openFork(anchor);
  }

  void _openFork(ForkAnchor anchor) {
    ref.read(forkPanelOverlayProvider.notifier).open(anchor, _forkLayerLink);
  }

  @override
  Widget build(BuildContext context) {
    final anchors = (ref.watch(
              forkAnchorsForConversationProvider(widget.message.conversationId),
            ).value ??
            const <ForkAnchor>[])
        .where((a) => a.anchorMessageId == widget.message.id)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final chips = <ForkAnchor>[];
    final segments =
        _ForkBandLayout.compute(widget.message.content, anchors, chips);

    return CompositedTransformTarget(
      link: _forkLayerLink,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (chips.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [for (final anchor in chips) _buildChip(anchor)],
              ),
            ),
          SelectionArea(
            contextMenuBuilder: _buildForkMenu,
            onSelectionChanged: (content) => _lastSelection = content,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final segment in segments) _buildSegment(segment),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegment(_ForkSegment segment) {
    final anchor = segment.anchor;
    if (anchor == null) {
      return MarkdownBodyContent(
        content: segment.text,
        isDark: widget.isDark,
        selectable: false,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => _openFork(anchor),
      child: Container(
        key: ValueKey<String>('fork_band_${anchor.id}'),
        color: kForkHighlightColor,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: MarkdownBodyContent(
          content: segment.text,
          isDark: widget.isDark,
          selectable: false,
        ),
      ),
    );
  }

  Widget _buildChip(ForkAnchor anchor) {
    final text = anchor.selectedText;
    final clipped = text.length <= 32 ? text : text.substring(0, 32);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => _openFork(anchor),
      child: Container(
        key: ValueKey<String>('fork_chip_${anchor.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: kForkHighlightColor,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          AppLocalizations.of(context)!.forkChipLabel(clipped),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
      ),
    );
  }
}

class _ForkSegment {
  const _ForkSegment.plain(this.text) : anchor = null;
  const _ForkSegment.band(this.text, this.anchor);

  final String text;
  final ForkAnchor? anchor;
}

class _ForkBandLayout {
  static int _fenceCount(String input) => '```'.allMatches(input).length;

  static List<_ForkSegment> compute(
    String content,
    List<ForkAnchor> anchors,
    List<ForkAnchor> chipsOut,
  ) {
    final candidates = <(int, int, ForkAnchor)>[];
    for (final anchor in anchors) {
      final span = anchor.selectedText.trim();
      final start = content.indexOf(span);
      if (span.isEmpty || start < 0) {
        chipsOut.add(anchor);
        continue;
      }
      final lineStart =
          start == 0 ? 0 : content.lastIndexOf('\n', start - 1) + 1;
      final matchEnd = start + span.length;
      final int lineEnd;
      if (content.codeUnitAt(matchEnd - 1) == 0x0A) {
        lineEnd = matchEnd;
      } else {
        final newline = content.indexOf('\n', matchEnd);
        lineEnd = newline < 0 ? content.length : newline;
      }
      final beforeFences = _fenceCount(content.substring(0, lineStart));
      final bandFences = _fenceCount(content.substring(lineStart, lineEnd));
      final afterFences = _fenceCount(content.substring(lineEnd));
      if (beforeFences != afterFences ||
          beforeFences.isOdd ||
          bandFences.isOdd) {
        chipsOut.add(anchor);
        continue;
      }
      candidates.add((lineStart, lineEnd, anchor));
    }
    candidates.sort((a, b) => a.$1.compareTo(b.$1));
    final segments = <_ForkSegment>[];
    var cursor = 0;
    for (final (start, end, anchor) in candidates) {
      if (start < cursor) {
        chipsOut.add(anchor);
        continue;
      }
      final before = content.substring(cursor, start);
      if (before.trim().isNotEmpty) {
        segments.add(_ForkSegment.plain(before));
      }
      segments.add(_ForkSegment.band(content.substring(start, end), anchor));
      cursor = end;
      if (cursor < content.length && content[cursor] == '\n') {
        cursor++;
      }
    }
    final after = content.substring(cursor);
    if (after.trim().isNotEmpty) {
      segments.add(_ForkSegment.plain(after));
    }
    return segments;
  }
}
