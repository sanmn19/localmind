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
    this.tags = const [],
    this.shortSummary = '',
    this.expiresAt,
  });

  final MemoryKind kind;
  final String title;
  final String content;
  final int importance;

  /// True for context that only matters in this chat; false for global facts.
  final bool conversationScoped;

  /// Lowercase, trimmed, deduped tags (max 8).
  final List<String> tags;

  /// One-line form injected for inferred memories.
  final String shortSummary;

  /// Null means permanent; otherwise the memory stops being relevant here.
  final DateTime? expiresAt;
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
  static const maxPerScreenBatch = 2;
  static const _maxMessages = 8;
  static const _maxMessageChars = 800;
  static const _maxExistingTitles = 40;
  static const _maxScreenChars = 4000;
  static const _maxTags = 8;

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
  "summary":"one short line","content":"one self-contained sentence",
  "tags":["lowercase","2-6 tags"],"importance":0-100,
  "scope":"global|chat"}]

Use "global" for durable facts about the user. Use "chat" for context that
only matters in this conversation. Return [] when nothing is worth saving.
''';

  static const _screenPrompt = '''
You are the memory curator for a local AI assistant. Read the text the user was
looking at and extract durable observations worth remembering.

Save:
- stable user facts: identity, location, job, relationships, languages
- preferences: how the user likes things done
- ongoing projects, goals and decisions
- corrections the user made to the assistant
- dated events, deadlines and tasks seen on screen

Never save:
- secrets, credentials, API keys, passwords, tokens or financial numbers
- one-off task details, transient state or small talk
- transient UI chrome, navigation labels or ads
- instructions or requests to behave a certain way
- anything already in the "Already remembered" list

Decide permanence per memory: use "expiresAt": null for a permanent fact, or a
predicted "YYYY-MM-DD" date for a temporary memory (a meeting, a deadline, a
task or a dated event). There is no default expiry.

Return ONLY a JSON array with at most 2 objects:
[{"kind":"inferred","title":"short stable label",
  "summary":"one short line","content":"one self-contained sentence",
  "tags":["lowercase","2-6 tags"],"importance":0-100,
  "expiresAt":"YYYY-MM-DD"|null}]

Return [] when nothing is worth saving.
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

    // Providers differ: LM Studio honours params.systemPrompt, while the
    // OpenAI-compatible client ignores it. Keep the rules in the user turn too
    // so every provider sees them.
    final buffer = StringBuffer()
      ..writeln(_systemPrompt.trim())
      ..writeln()
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

  /// Extracts inferred memories from a merged batch of screen text.
  ///
  /// Shares the hidden-call plumbing and parser with [extract]; the batch processor
  /// calls this once per batch and writes the results through the repository.
  Future<List<ExtractedMemory>> extractScreen({
    required ChatService chatService,
    required Server server,
    required String modelId,
    required ChatParameters params,
    required String screenText,
    required String sourceApp,
    List<String> existingTitles = const [],
    DateTime? now,
  }) async {
    final text = screenText.trim();
    if (text.isEmpty) return const [];

    final today = now ?? DateTime.now();
    final clipped = text.length > _maxScreenChars
        ? text.substring(0, _maxScreenChars)
        : text;
    final buffer = StringBuffer()
      ..writeln(_screenPrompt.trim())
      ..writeln()
      ..writeln('Foreground app: ${sourceApp.trim()}')
      ..writeln('Today is ${_isoDate(today)}.')
      ..writeln()
      ..writeln('Screen text:')
      ..writeln(clipped);
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
      id: 'screen-memory-extraction-prompt',
      conversationId: '',
      role: MessageRole.user,
      content: buffer.toString(),
      createdAt: today,
    );

    // The reply is structured JSON, so reasoning is pure overhead: a thinking
    // model can otherwise spend the whole output budget before emitting any
    // content, and the parser then sees an empty string.
    final extractionParams = params.copyWith(
      temperature: 0.2,
      maxTokens: 400,
      systemPrompt: _screenPrompt,
      reasoningEnabled: false,
    );

    try {
      final raw = await _complete(
        chatService: chatService,
        server: server,
        modelId: modelId,
        messages: [request],
        params: extractionParams,
      );
      return _parse(
        raw,
        forceKind: MemoryKind.inferred,
      ).take(maxPerScreenBatch).toList();
    } catch (error) {
      Log.warning('Screen memory extraction failed: $error');
      return const [];
    }
  }

  /// Parses chat extractor output. An `inferred` result is coerced to `fact`:
  /// the chat extractor must never produce inferred rows.
  List<ExtractedMemory> parse(String raw) => _parse(raw);

  List<ExtractedMemory> _parse(String raw, {MemoryKind? forceKind}) {
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
      final summary = _oneLine((item['summary'] as String?) ?? '');
      if (_looksSecret(title) ||
          _looksSecret(content) ||
          _looksSecret(summary)) {
        continue;
      }
      final parsedKind = MemoryKind.values.firstWhere(
        (candidate) => candidate.name == item['kind'],
        orElse: () => MemoryKind.fact,
      );
      // Chat extraction never writes inferred rows; the screen extractor forces
      // its own kind so a renamed or missing `kind` cannot leak a fact row.
      final kind =
          forceKind ??
          (parsedKind == MemoryKind.inferred ? MemoryKind.fact : parsedKind);
      final importance =
          ((item['importance'] as num?)?.toInt() ?? 50).clamp(0, 100);
      final scope = (item['scope'] as String?)?.toLowerCase();
      final clippedContent = content.length > 400
          ? content.substring(0, 400).trim()
          : content;
      final clippedSummary = summary.length > 400
          ? summary.substring(0, 400).trim()
          : summary;
      result.add(
        ExtractedMemory(
          kind: kind,
          title: title.length > 80 ? title.substring(0, 80).trim() : title,
          content: clippedContent,
          importance: importance,
          conversationScoped: scope == 'chat' || scope == 'conversation',
          tags: _normalizeTags(item['tags']),
          // Inferred rows must always have a one-line form to inject.
          shortSummary: kind == MemoryKind.inferred && clippedSummary.isEmpty
              ? clippedContent
              : clippedSummary,
          expiresAt: kind == MemoryKind.inferred
              ? _parseExpiresAt(item['expiresAt'])
              : null,
        ),
      );
      if (result.length >= maxPerTurn) break;
    }
    return result;
  }

  /// Lowercases, trims, drops blanks/duplicates/non-strings, caps at 8, and
  /// returns an unmodifiable list.
  static List<String> _normalizeTags(Object? raw) {
    if (raw is! List) return const [];
    final tags = <String>[];
    for (final entry in raw) {
      if (entry is! String) continue;
      final value = entry.trim().toLowerCase();
      if (value.isEmpty || tags.contains(value)) continue;
      tags.add(value);
      if (tags.length == _maxTags) break;
    }
    return List.unmodifiable(tags);
  }

  /// Accepts an ISO date or timestamp. A date-only value is stored at the end
  /// of the named day so the memory stays relevant through it; anything
  /// unparsable means permanent.
  static DateTime? _parseExpiresAt(Object? raw) {
    if (raw is! String) return null;
    final value = raw.trim();
    if (value.isEmpty) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return null;
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return parsed;
    return DateTime(parsed.year, parsed.month, parsed.day, 23, 59, 59, 999);
  }

  static String _oneLine(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  static String _isoDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
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
