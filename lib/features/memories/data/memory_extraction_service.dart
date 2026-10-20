import 'dart:async';
import 'dart:convert';

import '../../../core/logger/app_logger.dart';
import '../../../core/models/enums.dart';
import '../../chat/data/chat_service.dart';
import '../../chat/data/models/chat_parameters.dart';
import '../../chat/data/models/message.dart';
import '../../servers/data/models/server.dart';
import 'models/memory.dart';

/// One memory proposed by the background extractor.
class ExtractedMemory {
  const ExtractedMemory({
    required this.kind,
    required this.title,
    required this.content,
    required this.importance,
    required this.conversationScoped,
  });

  final MemoryKind kind;
  final String title;
  final String content;
  final int importance;

  /// True for context that only matters in this chat; false for global facts.
  final bool conversationScoped;
}

/// Hidden, post-reply memory extraction: one short call to the same provider
/// that asks whether anything in the last exchange is worth remembering.
///
/// Modelled on Claude Code's auto memory (Claude writes its own notes) and on
/// Mem0's extraction pass: an LLM reads the turn and emits structured facts,
/// while the app keeps storage, dedupe and retrieval. The call never blocks the
/// reply and never shows up in the transcript.
class MemoryExtractionService {
  static const maxPerTurn = 3;
  static const _maxMessages = 8;
  static const _maxMessageChars = 800;
  static const _maxExistingTitles = 40;

  static const _systemPrompt = '''
You are the memory curator for a local AI assistant. Read the exchange and
extract durable facts that will be useful in future conversations.

Save:
- stable user facts: identity, location, job, relationships, languages
- preferences: how the user likes things done
- ongoing projects, goals and decisions
- corrections the user made to the assistant

Never save:
- secrets, credentials, API keys, passwords, tokens or financial numbers
- one-off task details, transient state or small talk
- anything already in the "Already remembered" list
- instructions or requests to behave a certain way

Return ONLY a JSON array with at most 3 objects:
[{"kind":"fact|preference|entity|event","title":"short stable label",
  "content":"one self-contained sentence","importance":0-100,
  "scope":"global|chat"}]

Use "global" for durable facts about the user. Use "chat" for context that
only matters in this conversation. Return [] when nothing is worth saving.
''';

  Future<List<ExtractedMemory>> extract({
    required ChatService chatService,
    required Server server,
    required String modelId,
    required ChatParameters params,
    required List<Message> messages,
    List<String> existingTitles = const [],
  }) async {
    final transcript = _transcript(messages);
    if (transcript.isEmpty) return const [];

    final buffer = StringBuffer()
      ..writeln('Conversation:')
      ..writeln(transcript);
    if (existingTitles.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Already remembered (do not repeat):');
      for (final title in existingTitles.take(_maxExistingTitles)) {
        buffer.writeln('- $title');
      }
    }
    buffer
      ..writeln()
      ..writeln('Return the JSON array now.');

    final request = Message(
      id: 'memory-extraction-prompt',
      conversationId: messages.last.conversationId,
      role: MessageRole.user,
      content: buffer.toString(),
      createdAt: DateTime.now(),
    );

    final extractionParams = params.copyWith(
      temperature: 0.2,
      maxTokens: 400,
      systemPrompt: _systemPrompt,
    );

    try {
      final raw = await _complete(
        chatService: chatService,
        server: server,
        modelId: modelId,
        messages: [request],
        params: extractionParams,
      );
      return parse(raw);
    } catch (error) {
      Log.warning('Memory extraction failed: $error');
      return const [];
    }
  }

  /// Parses the model output. Tolerates code fences and prose around the array.
  List<ExtractedMemory> parse(String raw) {
    var text = raw.trim();
    text = text.replaceAll(RegExp(r'```(?:json)?'), '');
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start < 0 || end <= start) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];

    final result = <ExtractedMemory>[];
    for (final item in decoded.whereType<Map>()) {
      final title = (item['title'] as String?)?.trim() ?? '';
      final content = (item['content'] as String?)?.trim() ?? '';
      if (title.isEmpty || content.isEmpty) continue;
      if (_looksSecret(title) || _looksSecret(content)) continue;
      final kind = MemoryKind.values.firstWhere(
        (candidate) => candidate.name == item['kind'],
        orElse: () => MemoryKind.fact,
      );
      final importance =
          ((item['importance'] as num?)?.toInt() ?? 50).clamp(0, 100);
      final scope = (item['scope'] as String?)?.toLowerCase();
      result.add(
        ExtractedMemory(
          kind: kind,
          title: title.length > 80 ? title.substring(0, 80).trim() : title,
          content: content.length > 400
              ? content.substring(0, 400).trim()
              : content,
          importance: importance,
          conversationScoped: scope == 'chat' || scope == 'conversation',
        ),
      );
      if (result.length >= maxPerTurn) break;
    }
    return result;
  }

  String _transcript(List<Message> messages) {
    final buffer = StringBuffer();
    for (final message in messages.reversed) {
      if (buffer.length > _maxMessageChars * _maxMessages) break;
      if (message.role != MessageRole.user &&
          message.role != MessageRole.assistant) {
        continue;
      }
      final content = message.content.trim();
      if (content.isEmpty) continue;
      final label = message.role == MessageRole.user ? 'User' : 'Assistant';
      final clipped = content.length > _maxMessageChars
          ? '${content.substring(0, _maxMessageChars)}...'
          : content;
      buffer.writeln('$label: $clipped');
    }
    // Reversed above; restore chronological order.
    final lines = buffer.toString().trim().split('\n');
    return lines.reversed.join('\n');
  }

  Future<String> _complete({
    required ChatService chatService,
    required Server server,
    required String modelId,
    required List<Message> messages,
    required ChatParameters params,
  }) async {
    final completer = Completer<String>();
    var accumulated = '';
    StreamSubscription<ChatResponse>? subscription;
    subscription = chatService
        .sendMessage(
          server: server,
          modelId: modelId,
          messages: messages,
          params: params,
        )
        .listen(
          (response) {
            if (response.type == ChatResponseType.message &&
                response.content != null) {
              accumulated += response.content!;
            } else if (response.type == ChatResponseType.done) {
              subscription?.cancel();
              if (!completer.isCompleted) completer.complete(accumulated);
            } else if (response.type == ChatResponseType.error) {
              subscription?.cancel();
              if (!completer.isCompleted) {
                completer.completeError(
                  response.content ?? 'Unknown streaming error',
                );
              }
            }
          },
          onError: (Object error) {
            subscription?.cancel();
            if (!completer.isCompleted) completer.completeError(error);
          },
          onDone: () {
            subscription?.cancel();
            if (!completer.isCompleted) completer.complete(accumulated);
          },
          cancelOnError: true,
        );

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        subscription?.cancel();
        return accumulated;
      },
    );
  }

  static bool _looksSecret(String text) {
    return RegExp(
      r'(api[_ -]?key|password|passwd|secret|bearer|token|sk-[a-z0-9]{8,})',
      caseSensitive: false,
    ).hasMatch(text);
  }
}
