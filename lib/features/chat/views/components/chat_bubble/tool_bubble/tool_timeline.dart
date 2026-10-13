import 'package:hugeicons/hugeicons.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:localmind/core/theme/colors.dart';
import 'package:localmind/features/chat/data/tools/tool_event.dart';
import 'package:localmind/features/chat/data/models/grouped_tool_call.dart';
import '../../background_task_pill.dart';
import 'tool_row.dart';

class ToolTimeline extends StatelessWidget {
  const ToolTimeline({
    super.key,
    required this.events,
    this.ownerConversationId,
  });
  final List<ToolEvent> events;

  /// The conversation this timeline renders into — the Task 4 pill seam
  /// needs it so a bg.spawn pill only appears for Task rows owned by THIS
  /// chat (forked copies of the history stay pill-free).
  final String? ownerConversationId;

  List<GroupedToolCall> _groupEvents(List<ToolEvent> events) {
    final Map<String, GroupedToolCall> groups = {};
    final List<String> orderedBaseIds = [];

    for (final event in events) {
      final dotIndex = event.eventId.lastIndexOf('.');
      final baseId = dotIndex != -1
          ? event.eventId.substring(0, dotIndex)
          : event.eventId;

      if (!orderedBaseIds.contains(baseId)) {
        orderedBaseIds.add(baseId);
      }

      final existing = groups[baseId];
      if (existing == null) {
        groups[baseId] = GroupedToolCall(
          baseId: baseId,
          toolName: event.toolName,
          providerType: event.providerType,
          providerRef: event.providerRef,
          arguments: event.arguments,
          status: event.status,
          result: event.result,
          error: event.error,
          durationMs: event.durationMs,
          timestamp: event.timestamp,
        );
      } else {
        groups[baseId] = GroupedToolCall(
          baseId: baseId,
          toolName: event.toolName,
          providerType: event.providerType,
          providerRef: event.providerRef,
          arguments: event.arguments ?? existing.arguments,
          status: event.status,
          result: event.result ?? existing.result,
          error: event.error ?? existing.error,
          durationMs: event.durationMs ?? existing.durationMs,
          timestamp: event.timestamp,
        );
      }
    }

    return orderedBaseIds.map((id) => groups[id]!).toList();
  }

  /// Only `bg.spawn` results mint a pill: the spawn output contract is
  /// `task_id ... (cadence, max runs)` (bgSpawnRender). bg.status rows also
  /// cite task ids — the toolName filter keeps those pill-free.
  String? _spawnTaskId(GroupedToolCall call) {
    if (call.toolName != 'bg.spawn') return null;
    final result = call.result;
    if (result == null || result.isEmpty) return null;
    return RegExp(r'task_id:\s*([A-Za-z0-9_-]+)')
        .firstMatch(result)
        ?.group(1);
  }

  String _formatArgs(Map<String, dynamic> args) {
    if (args.isEmpty) return '';
    try {
      final encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(args);
    } catch (_) {
      return args.entries.map((e) => '  ${e.key}: ${e.value}').join('\n');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final groupedCalls = _groupEvents(events);

    if (groupedCalls.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                ),
              ),
            ),
            child: Row(
              children: [
                HugeIcon(
                  icon: HugeIcons.strokeRoundedComputerTerminal01,
                  size: 16,
                  color: isDark
                      ? AppColors.darkMutedText
                      : AppColors.lightMutedText,
                ),
                const SizedBox(width: 8),
                Text(
                  'SYSTEM ACTIONS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                    color: isDark
                        ? AppColors.darkMutedText
                        : AppColors.lightMutedText,
                  ),
                ),
                const Spacer(),
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
                    '${groupedCalls.length} ${groupedCalls.length == 1 ? "action" : "actions"}',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: groupedCalls.length,
              separatorBuilder: (context, index) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Divider(
                  height: 1,
                  thickness: 1,
                  color: isDark
                      ? const Color(0xFF313244).withValues(alpha: 0.3)
                      : const Color(0xFFE0E5F5).withValues(alpha: 0.5),
                ),
              ),
              itemBuilder: (context, index) {
                final call = groupedCalls[index];
                final spawnTaskId = _spawnTaskId(call);
                return Column(
                  children: [
                    // Task 4 inline pill: rendered ABOVE the spawning
                    // bg.tool row; itself silent unless a task row with
                    // this id (owned by this conversation) is still live.
                    if (spawnTaskId != null)
                      BackgroundTaskPill(
                        taskId: spawnTaskId,
                        owner: ownerConversationId ?? '',
                      ),
                    ToolRowWidget(
                      call: call,
                      isDark: isDark,
                      formatArgs: _formatArgs,
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
