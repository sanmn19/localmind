import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/utils/message_variants.dart';

/// One consolidated tool call of a tool chain: name, arguments and — when
/// known — the executed result.
class ChainToolCall {
  final String toolName;
  final Map<String, dynamic> arguments;
  final String? result;

  const ChainToolCall({
    required this.toolName,
    required this.arguments,
    this.result,
  });
}

/// The consolidated payload behind a tool-chain turn: every executed call in
/// order plus the reasoning ("thinking") text that produced the answer.
class ToolActivitySnapshot {
  final List<ChainToolCall> calls;
  final String? reasoning;

  const ToolActivitySnapshot({required this.calls, this.reasoning});
}

const int maxReasoningCharacters = 1500;

/// Builds the consolidated 'Web activity' payload for a tool chain.
///
/// Walks the timeline rows belonging to [finalAssistant]'s turn — assistant
/// rounds carrying `toolCalls` plus their `MessageRole.tool` result rows,
/// matched through `parentMessageId` + `toolCallId` — up to and including
/// the final round. Returns null when [finalAssistant] carries tool data
/// itself (it is a chain round, not the answering tail) or when the turn
/// contains no tool calls at all.
///
/// [timeline] is the candidate pool to walk, usually the conversation's
/// `allMessages` list. In the consolidated shape the tail is linked to the
/// turn's user row, so every round of the chain sits in the same variant
/// group keyed by `variantGroupId` (see `MessageVariants.groupId`).
ToolActivitySnapshot? toolActivityForChain(
  List<Message> timeline,
  Message finalAssistant,
) {
  if (finalAssistant.toolCalls?.isNotEmpty == true) return null;

  final rounds = _chainRoundsFor(timeline, finalAssistant);
  if (rounds.isEmpty) return null;

  final calls = <ChainToolCall>[];
  for (final round in rounds) {
    for (final toolCall in round.toolCalls!) {
      calls.add(
        ChainToolCall(
          toolName: toolCall.toolName,
          arguments: toolCall.arguments,
          result: _resultFor(timeline, round, toolCall) ?? toolCall.result,
        ),
      );
    }
  }

  // The tail's own thinking is the answer context the user reads; earlier
  // rounds rarely repeat it. When the tail has none, the rounds' reasoning
  // stands in, capped so a pathological stream cannot flood the card.
  String? reasoning;
  final tailReasoning = finalAssistant.reasoningContent;
  if (tailReasoning != null && tailReasoning.trim().isNotEmpty) {
    reasoning = _cap(tailReasoning, keepTail: true);
  } else {
    final roundReasoning = rounds
        .map((round) => round.reasoningContent)
        .whereType<String>()
        .map((text) => text.trim())
        .where((text) => text.isNotEmpty)
        .join('\n\n');
    if (roundReasoning.isNotEmpty) {
      reasoning = _cap(roundReasoning, keepTail: true);
    }
  }

  return ToolActivitySnapshot(calls: calls, reasoning: reasoning);
}

/// The `MessageRole.tool` result rows a chain consumed, so the message list
/// can stop rendering them once the tail's activity block is attached.
List<Message> chainToolMessages(
  List<Message> timeline,
  Message finalAssistant,
) {
  if (finalAssistant.toolCalls?.isNotEmpty == true) return const [];
  final messages = <Message>[
    for (final round in _chainRoundsFor(timeline, finalAssistant))
      ...timeline.where(
        (m) => m.role == MessageRole.tool && m.parentMessageId == round.id,
      ),
  ];
  messages.sort((a, b) {
    final orderCompare = a.threadOrder.compareTo(b.threadOrder);
    if (orderCompare != 0) return orderCompare;
    return a.createdAt.compareTo(b.createdAt);
  });
  return messages;
}

/// Assistant rounds of [finalAssistant]'s turn that carried tool calls, in
/// chronological order.
List<Message> _chainRoundsFor(List<Message> timeline, Message tail) {
  final groupId = tail.variantGroupId;
  if (groupId == null || groupId.isEmpty) return const [];
  return timeline
      .where(
        (m) =>
            m.id != tail.id &&
            m.role == MessageRole.assistant &&
            m.toolCalls?.isNotEmpty == true &&
            MessageVariants.groupId(m) == groupId,
      )
      .toList()
    ..sort((a, b) {
      final orderCompare = a.threadOrder.compareTo(b.threadOrder);
      if (orderCompare != 0) return orderCompare;
      return a.createdAt.compareTo(b.createdAt);
    });
}

String? _resultFor(List<Message> timeline, Message round, ToolCallData call) {
  for (final message in timeline) {
    if (message.role == MessageRole.tool &&
        message.parentMessageId == round.id &&
        message.toolCallId == call.id) {
      return message.content;
    }
  }
  return null;
}

String _cap(String text, {required bool keepTail}) {
  if (text.length <= maxReasoningCharacters) return text;
  if (keepTail) {
    return text.substring(text.length - maxReasoningCharacters);
  }
  return text.substring(0, maxReasoningCharacters);
}
