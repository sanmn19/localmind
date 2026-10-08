import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:localmind/core/theme/colors.dart';
import 'package:localmind/features/chat/data/tool_activity_grouping.dart';
import 'package:localmind/l10n/app_localizations.dart';
import '../../reasoning_widget.dart';

/// How many characters of an executed tool result are shown on a call line
/// before truncating.
const int toolCallResultPreviewMaxCharacters = 160;

/// First [toolCallResultPreviewMaxCharacters] characters of a tool result,
/// ending with an ellipsis when truncated.
String toolCallResultPreview(String result, [int? max]) {
  final limit = max ?? toolCallResultPreviewMaxCharacters;
  if (result.length <= limit) return result;
  return '${result.substring(0, limit)}…';
}

/// Compact single-line JSON of a call's arguments, empty when there are none.
String toolCallArgsCompact(Map<String, dynamic> arguments) {
  if (arguments.isEmpty) return '';
  try {
    return json.encode(arguments);
  } catch (_) {
    return '';
  }
}

/// One line of the expanded activity list:
/// `toolName(compact args) → result preview`.
String toolActivityLineText(ChainToolCall call) {
  final arguments = toolCallArgsCompact(call.arguments);
  final openParen = arguments.isEmpty ? '' : '(';
  final closeParen = arguments.isEmpty ? '' : ')';
  final result = call.result == null ? '' : toolCallResultPreview(call.result!);
  return '${call.toolName}$openParen$arguments$closeParen → $result';
}

/// One collapsible "Web activity" card summarizing a tool chain: collapsed
/// it shows how many search/fetch calls ran, expanded it lists each call
/// with its arguments and result preview and — when the answering round
/// produced one — a collapsible thinking section.
class ToolActivityBlock extends StatefulWidget {
  const ToolActivityBlock({super.key, required this.snapshot});

  final ToolActivitySnapshot snapshot;

  @override
  State<ToolActivityBlock> createState() => _ToolActivityBlockState();
}

class _ToolActivityBlockState extends State<ToolActivityBlock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  late final Animation<double> _expandAnimation = CurvedAnimation(
    parent: _controller,
    curve: Curves.fastOutSlowIn,
  );
  bool _isExpanded = false;

  void _toggle() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final muted = isDark ? AppColors.darkMutedText : AppColors.lightMutedText;
    final calls = widget.snapshot.calls;
    final hasThought = widget.snapshot.reasoning?.isNotEmpty == true;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurfaceInput : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.1 : 0.02),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    HugeIcon(
                      icon: HugeIcons.strokeRoundedSearch01,
                      size: 16,
                      color: muted,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l10n.tool_activity_title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        color: muted,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? AppColors.darkSurfaceCard
                            : AppColors.lightBorder,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        l10n.tool_activity_calls(calls.length),
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                      ),
                    ),
                    const Spacer(),
                    RotationTransition(
                      turns: Tween(
                        begin: 0.0,
                        end: 0.5,
                      ).animate(_expandAnimation),
                      child: HugeIcon(
                        icon: HugeIcons.strokeRoundedArrowDown01,
                        size: 18,
                        color: muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizeTransition(
              sizeFactor: _expandAnimation,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final call in calls)
                      _ToolActivityLine(text: toolActivityLineText(call)),
                    if (hasThought && widget.snapshot.reasoning!.isNotEmpty)
                      ReasoningWidget(
                        reasoningContent: widget.snapshot.reasoning,
                        isStreaming: false,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolActivityLine extends StatelessWidget {
  const _ToolActivityLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppColors.darkMutedText : AppColors.lightMutedText;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text(
        text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: muted,
          height: 1.35,
        ),
      ),
    );
  }
}
