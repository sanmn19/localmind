import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../skills/data/skills_provider.dart';
import '../../skills/data/skills_store.dart';
import '../data/tools/tool_definition.dart';
import 'chat_mcp_providers.dart';
import 'chat_notifier.dart' show ChatState, chatProvider;
import 'tooling_providers.dart' show availableToolsProvider;

/// One rounded chars-per-token step: the approximation convention used by
/// the chat token pipeline (per-message content length / 4).
int approxTokensFromChars(int chars) => (chars / 4).round();

/// Total approximate tokens across the three context segments, each
/// estimated at its own chars/4 so the segments and the total stay additive.
int approxTokensFor({
  required int skillsChars,
  required int historyChars,
  required int toolsChars,
}) {
  final segments = ChatContextSegments.fromCharCounts(
    skillsChars: skillsChars,
    historyChars: historyChars,
    toolsChars: toolsChars,
  );
  return segments.totalTokens;
}

/// The context-window composition behind the chat's token indicator:
/// skills-section / chat-history / tools-list token approximations.
class ChatContextSegments {
  const ChatContextSegments({
    required this.skillsTokens,
    required this.historyTokens,
    required this.toolsTokens,
    required this.totalTokens,
  });

  final int skillsTokens;
  final int historyTokens;
  final int toolsTokens;
  final int totalTokens;

  factory ChatContextSegments.fromCharCounts({
    required int skillsChars,
    required int historyChars,
    required int toolsChars,
  }) {
    final skillsTokens = approxTokensFromChars(skillsChars);
    final historyTokens = approxTokensFromChars(historyChars);
    final toolsTokens = approxTokensFromChars(toolsChars);
    return ChatContextSegments(
      skillsTokens: skillsTokens,
      historyTokens: historyTokens,
      toolsTokens: toolsTokens,
      totalTokens: skillsTokens + historyTokens + toolsTokens,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatContextSegments &&
          other.skillsTokens == skillsTokens &&
          other.historyTokens == historyTokens &&
          other.toolsTokens == toolsTokens &&
          other.totalTokens == totalTokens;

  @override
  int get hashCode =>
      Object.hash(skillsTokens, historyTokens, toolsTokens, totalTokens);
}

/// Skills bytes exactly as the system-builder would inject them: the
/// serialized skill (the same frontmatter format) per mirror entry,
/// collapsed to zero whenever the injection kill switch is off.
int _skillsChars(SkillsState state) {
  if (!state.enabled) return 0;
  var chars = 0;
  for (final entry in state.entries) {
    chars += SkillsStore.serialize(entry).length;
  }
  return chars;
}

/// History bytes: the active timeline's message contents plus the
/// in-progress streaming reply's growing content. During streaming the
/// timeline still carries the empty streaming row, so there is no
/// double-counting; on finalize the row is replaced and the field cleared.
int _historyChars(ChatState state) {
  var chars = 0;
  for (final message in state.messages) {
    chars += message.content.length;
  }
  chars += state.streamingMessage?.content.length ?? 0;
  return chars;
}

/// Tools payload bytes: the wire def per tool — description length plus the
/// schema-JSON encoding.
int _toolsChars(List<ToolDefinition> tools) {
  var chars = 0;
  for (final tool in tools) {
    chars += tool.description.length;
    chars += jsonEncode(tool.inputSchema).length;
  }
  return chars;
}

/// Derived approximation of what the next chat request's context window
/// contains: the skills section bytes (system-builder's serialization), the
/// conversation's message content and the MCP tools-list payloads. Watched
/// with select on integer sums so cheap recomputes never rebuild the UI.
/// When the chat's MCP toggle is off the wire carries no tools, exactly as
/// the send path assembles them.
final chatContextSegmentsProvider = Provider<ChatContextSegments>((ref) {
  final skillsCharCount = ref.watch(skillsProvider.select(_skillsChars));
  final historyCharCount = ref.watch(chatProvider.select(_historyChars));
  final mcpEnabled = ref.watch(
    chatMcpConfigProvider.select((config) => config.enabled),
  );
  final toolsCharCount = mcpEnabled
      ? ref.watch(
          availableToolsProvider.select(
            (snapshot) => _toolsChars(snapshot.value ?? const []),
          ),
        )
      : 0;
  return ChatContextSegments.fromCharCounts(
    skillsChars: skillsCharCount,
    historyChars: historyCharCount,
    toolsChars: toolsCharCount,
  );
});
