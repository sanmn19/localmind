import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/ask_local/ask_local_notifier.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/views/components/heartbeat_dot.dart';
import 'package:localmind/features/chat/views/components/reasoning_widget.dart';
import 'package:localmind/features/chat/views/components/chat_bubble/markdown/themed_gpt_markdown.dart'
    show MarkdownBodyContent;
import 'package:localmind/l10n/app_localizations.dart';

/// The Ask Local card surface (Task 4): compact transcript (user rows with
/// the screen-framer + capture thumbnail, streamed assistant rows with
/// reasoning/tool-activity/heartbeat liveness rows, in-card approval
/// chips), the context strip (thumbnail + quoted selection), the typing
/// field + send arrow and the re-capture/close header actions — all inside
/// the overlay engine's own tiny MaterialApp (l10n + theme; fork-panel
/// visual language at card scale).
class AskLocalCardApp extends StatelessWidget {
  const AskLocalCardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const _AskLocalCardHome(),
    );
  }
}

class _AskLocalCardHome extends StatelessWidget {
  const _AskLocalCardHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: const AskLocalCard(),
    );
  }
}

class AskLocalCard extends ConsumerStatefulWidget {
  const AskLocalCard({super.key});

  @override
  ConsumerState<AskLocalCard> createState() => _AskLocalCardState();
}

class _AskLocalCardState extends ConsumerState<AskLocalCard> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _transcriptScroll = ScrollController();
  final GlobalKey _contentKey = GlobalKey();
  double _lastRequestedHeight = 0;

  @override
  void dispose() {
    _inputController.dispose();
    _transcriptScroll.dispose();
    super.dispose();
  }

  void _submit(AskLocalCardState state) {
    final question = _inputController.text.trim();
    if (question.isEmpty || state.isStreaming) return;
    _inputController.clear();
    unawaited(ref.read(askLocalCardNotifierProvider.notifier).send(question));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(askLocalCardNotifierProvider);
    final locale = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final displayRows = [
      ..._historyTail(state),
      ...state.transcript,
    ];

    final content = Column(
      key: _contentKey,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(theme, state, locale),
        if (state.hasTarget) _contextStrip(theme, state, locale),
        if (state.failure != null)
          _failureBanner(state.failure!, theme),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
          child: _transcript(theme, state, displayRows),
        ),
        if (state.pendingApproval != null)
          _approvalChipRow(state, theme, locale),
        _inputRow(theme, state, locale),
      ],
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _requestResize());

    return Material(
      type: MaterialType.transparency,
      child: Container(
        margin: const EdgeInsets.all(0),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.98),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SingleChildScrollView(
            reverse: true,
            child: content,
          ),
        ),
      ),
    );
  }

  List<Message> _historyTail(AskLocalCardState state) {
    const maxTailRows = 8;
    final history = state.history;
    if (history.length <= maxTailRows) return history;
    return history.sublist(history.length - maxTailRows);
  }

  Widget _transcript(
    ThemeData theme,
    AskLocalCardState state,
    List<Message> displayRows,
  ) {
    if (displayRows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: Text(
          AppLocalizations.of(context)!.ask_local_card_empty_prompt,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final message in displayRows)
          _CardRow(message: message, isStreamingRow: _isStreamingRow(state, message)),
      ],
    );
  }

  bool _isStreamingRow(AskLocalCardState state, Message message) {
    if (!state.isStreaming) return false;
    final transcript = state.transcript;
    return transcript.isNotEmpty &&
        transcript.last.id == message.id;
  }

  Widget _header(
    ThemeData theme,
    AskLocalCardState state,
    AppLocalizations locale,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 0),
      child: Row(
        key: const ValueKey('ask_local_card_header'),
        children: [
          Icon(Icons.assignment_outlined,
              size: 15, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              locale.ask_local_card_title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          Text(
            state.isStreaming
                ? locale.ask_local_card_streaming
                : (state.hasTarget
                    ? state.modelLabel
                    : locale.ask_local_card_no_model),
            style: TextStyle(
              fontSize: 10,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
          IconButton(
            key: const ValueKey('ask_local_card_recapture'),
            tooltip: locale.ask_local_card_recapture_tooltip,
            visualDensity: VisualDensity.compact,
            iconSize: 17,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            icon: state.isStreaming
                ? const HeartbeatDot(size: 7)
                : const Icon(Icons.crop_free_rounded),
            onPressed:
                state.isStreaming ? null : () => unawaited(_recapture()),
          ),
          IconButton(
            key: const ValueKey('ask_local_card_close'),
            tooltip: locale.ask_local_card_close_tooltip,
            visualDensity: VisualDensity.compact,
            iconSize: 17,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            icon: const Icon(Icons.close_rounded),
            onPressed: _closeCard,
          ),
        ],
      ),
    );
  }

  Future<void> _recapture() async {
    await ref.read(askLocalCardNotifierProvider.notifier).recapture();
  }

  void _closeCard() {
    final env = ref.read(askLocalCardEnvProvider);
    unawaited(env.closeCard?.call());
  }

  Widget _contextStrip(
    ThemeData theme,
    AskLocalCardState state,
    AppLocalizations locale,
  ) {
    final capturePath = state.capturePath;
    final selectedText = state.delivery?.payload.selectedText.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        key: const ValueKey('ask_local_context_strip'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (capturePath != null)
            _captureThumbnail(theme, capturePath)
          else
            Icon(
              Icons.image_not_supported_outlined,
              size: 34,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              selectedText == null || selectedText.isEmpty
                  ? locale.ask_local_card_selection_missing
                  : '"$selectedText"',
              key: const ValueKey('ask_local_selected_text'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _captureThumbnail(ThemeData theme, String path) {
    return ClipRRect(
      key: const ValueKey('ask_local_capture_thumbnail'),
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        File(path),
        width: 44,
        height: 34,
        fit: BoxFit.cover,
        cacheWidth: 132,
        errorBuilder: (_, _, _) => _thumbPlaceholder(theme),
      ),
    );
  }

  Widget _thumbPlaceholder(ThemeData theme) => Container(
        width: 44,
        height: 34,
        color: theme.colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.image_outlined,
          size: 16,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
        ),
      );

  Widget _failureBanner(String failure, ThemeData theme) {
    return Container(
      key: const ValueKey('ask_local_failure'),
      margin: const EdgeInsets.fromLTRB(10, 2, 10, 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded,
              size: 14, color: theme.colorScheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              failure,
              style: TextStyle(fontSize: 11, color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  Widget _approvalChipRow(
    AskLocalCardState state,
    ThemeData theme,
    AppLocalizations locale,
  ) {
    final approval = state.pendingApproval!;
    return Container(
      key: const ValueKey('ask_local_approval_chip'),
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_open_rounded,
              size: 13, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              locale.ask_local_card_run_tool_question(approval.toolName),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('ask_local_chip_approve'),
            tooltip: locale.ask_local_card_approve_tooltip,
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            color: theme.colorScheme.primary,
            icon: const Icon(Icons.check_rounded),
            onPressed: () => ref
                .read(askLocalCardNotifierProvider.notifier)
                .approvePending(),
          ),
          IconButton(
            key: const ValueKey('ask_local_chip_deny'),
            tooltip: locale.ask_local_card_deny_tooltip,
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            color: theme.colorScheme.error,
            icon: const Icon(Icons.close_rounded),
            onPressed: () =>
                ref.read(askLocalCardNotifierProvider.notifier).denyPending(),
          ),
        ],
      ),
    );
  }

  Widget _inputRow(
    ThemeData theme,
    AskLocalCardState state,
    AppLocalizations locale,
  ) {
    final canSend = !state.isStreaming &&
        _inputController.text.trim().isNotEmpty;
    return Padding(
      key: const ValueKey('ask_local_input_row'),
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('ask_local_card_input'),
              controller: _inputController,
              enabled: !state.isStreaming,
              maxLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(state),
              onChanged: (_) => setState(() {}),
              style: TextStyle(
                fontSize: 13,
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
                hintText: locale.ask_local_card_input_hint,
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            key: const ValueKey('ask_local_card_send'),
            color: theme.colorScheme.primary,
            icon: const Icon(Icons.send_rounded),
            onPressed: canSend ? () => _submit(state) : null,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  void _requestResize() {
    final renderObject = _contentKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final height = renderObject.size.height;
    if ((height - _lastRequestedHeight).abs() < 1) return;
    _lastRequestedHeight = height;
    final env = ref.read(askLocalCardEnvProvider);
    unawaited(env.resizeCard?.call(height));
  }
}

class _CardRow extends StatelessWidget {
  const _CardRow({required this.message, required this.isStreamingRow});

  final Message message;
  final bool isStreamingRow;  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = AppLocalizations.of(context)!;
    if (message.role == MessageRole.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          key: const ValueKey('ask_local_row_user'),
          margin: const EdgeInsets.only(bottom: 8, left: 24),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            message.content,
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
      );
    }

    if (message.role == MessageRole.tool) {
      final muted = theme.colorScheme.onSurface.withValues(alpha: 0.45);
      return Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 6),
        child: Row(
          key: ValueKey('ask_local_tool_feedback_${message.id}'),
          children: [
            Icon(Icons.subdirectory_arrow_right_rounded,
                size: 12, color: muted),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                locale.ask_local_card_tool_result(
                  message.content.isEmpty
                      ? locale.ask_local_card_tool_no_output
                      : _clipResult(message.content),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: muted),
              ),
            ),
          ],
        ),
      );
    }

    final content = message.content;
    final reasoning = message.reasoningContent ?? '';
    final hasReasoning = reasoning.trim().isNotEmpty;
    final toolCalls = message.toolCalls;
    final isError = message.status == MessageStatus.error;
    final showHeartbeat = isStreamingRow &&
        !isError &&
        content.trim().isEmpty &&
        !hasReasoning;

    return Container(
      key: const ValueKey('ask_local_row_assistant'),
      margin: const EdgeInsets.only(bottom: 8, right: 16),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasReasoning)
            ReasoningWidget(
              reasoningContent: reasoning,
              isStreaming: isStreamingRow,
              hasMainContent: content.trim().isNotEmpty,
            ),
          if (toolCalls != null && toolCalls.isNotEmpty)
            ..._toolActivityRows(toolCalls, theme, locale),
          if (isError)
            Text(
              message.errorMessage ?? message.content,
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            )
          else if (showHeartbeat)
            Row(
              key: const ValueKey('ask_local_heartbeat'),
              children: [
                const HeartbeatDot(size: 7),
                const SizedBox(width: 8),
                Text(
                  AppLocalizations.of(context)!.ask_local_card_thinking,
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            )
          else if (content.trim().isNotEmpty)
            MarkdownBodyContent(
              content: content,
              isDark: theme.brightness == Brightness.dark,
              selectable: false,
              // Overlay-engine contract: the card has NO url_launcher
              // (plugins auto-registration off) and must never launch app
              // surfaces from a floating window — links render styled but
              // taps are swallowed.
              onLinkTapOverride: (_, _) {},
            ),
        ],
      ),
    );
  }

  List<Widget> _toolActivityRows(
    List<ToolCallData> calls,
    ThemeData theme,
    AppLocalizations locale,
  ) {
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    return [
      for (final call in calls)
        Row(
          key: ValueKey('ask_local_tool_activity_${call.id}'),
          children: [
            Icon(
              _toolFailed(call.result)
                  ? Icons.close_rounded
                  : Icons.check_circle_outline_rounded,
              size: 13,
              color: _toolFailed(call.result)
                  ? const Color(0xFFEF4444)
                  : const Color(0xFF22C55E),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                locale.ask_local_card_tool_called(
                  call.toolName,
                  _verdictLabel(call.result, locale),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: muted,
                ),
              ),
            ),
          ],
        ),
    ];
  }

  static bool _toolFailed(String? result) {
    if (result == null || result.isEmpty) return false;
    return result.startsWith('ERROR:') || result.contains('denied by the user');
  }

  static String _verdictLabel(String? result, AppLocalizations locale) {
    if (result == null || result.isEmpty) return locale.ask_local_card_verdict_done;
    if (result.contains('denied by the user')) {
      return locale.ask_local_card_verdict_denied;
    }
    if (result.startsWith('ERROR:')) return locale.ask_local_card_verdict_failed;
    return locale.ask_local_card_verdict_done;
  }

  static String _clipResult(String? content) =>
      content == null || content.isEmpty
          ? ''
          : (content.length <= 80 ? content : '${content.substring(0, 80)}…');
}
