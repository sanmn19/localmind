import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/core/theme/colors.dart';
import 'package:localmind/features/chat/providers/chat_providers.dart';
import 'package:localmind/features/chat/providers/context_segments_provider.dart';
import 'package:localmind/l10n/app_localizations.dart';

/// Context usage at which the indicator starts showing.
const _visibleFromRatio = 0.5;

/// Segment colors of the context split: skills (violet), history (the
/// component's accent) and tools/MCP (teal).
const _skillsSegmentColor = Color(0xFF8B5CF6);
const _toolsSegmentColor = Color(0xFF14B8A6);

class TokenUsageIndicator extends ConsumerWidget {
  const TokenUsageIndicator({super.key, required this.totalTokenCount});

  final int totalTokenCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // LM Studio's native chat API accepts context_length per request. Use the
    // configured per-chat value here so the indicator reflects the request the
    // app will actually send instead of a stale load-time model value.
    final contextLength = ref.watch(
      chatParamsProvider.select((params) => params.contextLength),
    );

    // totalTokenCount only updates once a response finishes (it's the real
    // server-reported count), so while one is streaming in, grow the ring
    // with a rough chars-per-token estimate of the in-progress reply —
    // corrected back to the exact figure the moment the stream ends.
    final isStreaming = ref.watch(chatProvider.select((s) => s.isStreaming));
    final streamingLength = ref.watch(
      chatProvider.select((s) => s.streamingMessage?.content.length ?? 0),
    );
    final estimatedTokenCount = isStreaming
        ? totalTokenCount + (streamingLength / 4).round()
        : totalTokenCount;

    final ratio = contextLength > 0
        ? (estimatedTokenCount / contextLength).clamp(0.0, 1.0)
        : 0.0;
    // Only worth the space in the composer once the context is filling up.
    if (ratio < _visibleFromRatio) return const SizedBox.shrink();
    final ringColor = ratio >= 0.9 ? Colors.red : theme.colorScheme.primary;

    final segments = ref.watch(chatContextSegmentsProvider);

    return GestureDetector(
      onTap: () => _showTokenUsageSheet(context, contextLength, ratio),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(4)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    value: ratio,
                    strokeWidth: 2,
                    backgroundColor: (isDark ? Colors.white : Colors.black)
                        .withValues(alpha: 0.12),
                    valueColor: AlwaysStoppedAnimation<Color>(ringColor),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  'ctx ~${segments.totalTokens}/$contextLength',
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            _ContextSegmentBar(
              segments: segments,
              historyColor: ringColor,
              trackColor: (isDark ? Colors.white : Colors.black).withValues(
                alpha: 0.12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showTokenUsageSheet(
    BuildContext context,
    int contextLength,
    double ratio,
  ) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        final sheetTheme = Theme.of(ctx);
        final isDark = sheetTheme.brightness == Brightness.dark;
        final muted = isDark
            ? AppColors.darkMutedText
            : AppColors.lightMutedText;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.token_usage_title,
                  style: sheetTheme.textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                _usageRow(l10n.total_tokens_label, '$totalTokenCount', muted),
                _usageRow(l10n.context_length, '$contextLength', muted),
                _usageRow(
                  l10n.usage_percent_label,
                  '${(ratio * 100).toStringAsFixed(1)}%',
                  muted,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _usageRow(String label, String value, Color muted) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: muted)),
          Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// The 3-segment horizontal split under the usage row: skills / history /
/// tools, each segment's width proportional to its chunk of the approximate
/// total. All-empty data renders 0-width segments over the quiet track.
class _ContextSegmentBar extends StatelessWidget {
  const _ContextSegmentBar({
    required this.segments,
    required this.historyColor,
    required this.trackColor,
  });

  final ChatContextSegments segments;
  final Color historyColor;
  final Color trackColor;

  static const _barWidth = 96.0;
  static const _barHeight = 3.0;

  @override
  Widget build(BuildContext context) {
    final total = max(segments.totalTokens, 1);
    return SizedBox(
      key: const ValueKey('context_segments_bar'),
      width: _barWidth,
      height: _barHeight,
      child: ColoredBox(
        color: trackColor,
        child: Row(
          children: [
            _segment(
              'context_segment_skills',
              segments.skillsTokens,
              total,
              _skillsSegmentColor,
            ),
            _segment(
              'context_segment_history',
              segments.historyTokens,
              total,
              historyColor,
            ),
            _segment(
              'context_segment_tools',
              segments.toolsTokens,
              total,
              _toolsSegmentColor,
            ),
          ],
        ),
      ),
    );
  }

  Widget _segment(String key, int tokens, int total, Color color) {
    return Container(
      key: ValueKey(key),
      width: tokens / total * _barWidth,
      color: color,
    );
  }
}
