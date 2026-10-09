import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/providers/chat_mcp_providers.dart';
import 'package:localmind/features/chat/providers/chat_providers.dart';
import 'package:localmind/features/chat/providers/context_segments_provider.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/chat/views/components/token_usage_indicator.dart';
import 'package:localmind/features/skills/data/skills_provider.dart';
import 'package:localmind/features/skills/data/skills_store.dart';
import 'package:localmind/l10n/app_localizations.dart';

class _SeededSkillsNotifier extends SkillsNotifier {
  _SeededSkillsNotifier(this._seed);
  final SkillsState _seed;

  @override
  SkillsState build() => _seed;
}

class _SeededChatNotifier extends ChatNotifier {
  _SeededChatNotifier(this._seed);
  final ChatState _seed;

  @override
  ChatState build() => _seed;
}

class _SeededMcpConfigNotifier extends ChatMcpConfigNotifier {
  _SeededMcpConfigNotifier(this._seed);
  final ChatMcpConfig _seed;

  @override
  ChatMcpConfig build() => _seed;
}

Message _message(String id, MessageRole role, String content) {
  return Message(
    id: id,
    conversationId: 'c1',
    role: role,
    content: content,
    createdAt: DateTime.utc(2026, 10, 8),
  );
}

const _tools = [
  ToolDefinition(
    name: 'web.search',
    description: 'Search the web',
    inputSchema: {'type': 'object'},
    providerType: ToolProviderType.builtIn,
  ),
];

void main() {
  test(
    'approxTokensFor estimates each segment at chars/4 and sums the total',
    () {
      expect(
        approxTokensFor(skillsChars: 800, historyChars: 400, toolsChars: 80),
        320,
      );
      expect(
        approxTokensFor(skillsChars: 0, historyChars: 0, toolsChars: 0),
        0,
      );
      expect(
        approxTokensFor(skillsChars: 3, historyChars: 3, toolsChars: 3),
        3,
      );
    },
  );

  test('chatContextSegmentsProvider derives the three segment counts', () async {
    final skills = [
      SkillEntry(name: 'alpha', description: 'First', body: 'a' * 40),
      SkillEntry(name: 'beta', description: 'Second', body: 'b' * 20),
    ];
    final messages = [
      _message('m1', MessageRole.user, 'u' * 200),
      _message('m2', MessageRole.assistant, 'a' * 400),
    ];

    final container = ProviderContainer(
      overrides: [
        skillsProvider.overrideWith(
          () => _SeededSkillsNotifier(
            SkillsState(enabled: true, entries: skills),
          ),
        ),
        chatProvider.overrideWith(
          () => _SeededChatNotifier(ChatState(messages: messages)),
        ),
        chatMcpConfigProvider.overrideWith(
          () => _SeededMcpConfigNotifier(const ChatMcpConfig(enabled: true)),
        ),
        availableToolsProvider.overrideWith((ref) => Future.value(_tools)),
      ],
    );
    addTearDown(container.dispose);

    await container.read(availableToolsProvider.future);
    final segments = container.read(chatContextSegmentsProvider);

    // serialize('alpha', 'First', 40 chars) = 39 + 40 = 79 chars;
    // serialize('beta', 'Second', 20 chars) = 39 + 20 = 59 chars
    // => 138 chars => 35 tokens. 600 message chars => 150 tokens.
    // Tool payload 'Search the web' (14) + '{"type":"object"}' (17) => 8 tokens.
    expect(
      skills.fold<int>(0, (sum, e) => sum + SkillsStore.serialize(e).length),
      138,
    );

    expect(
      segments,
      const ChatContextSegments(
        skillsTokens: 35,
        historyTokens: 150,
        toolsTokens: 8,
        totalTokens: 193,
      ),
    );
  });

  test(
    'skills segment collapses when the injection kill switch is off',
    () async {
      final container = ProviderContainer(
        overrides: [
          skillsProvider.overrideWith(
            () => _SeededSkillsNotifier(
              SkillsState(
                enabled: false,
                entries: [
                  SkillEntry(
                    name: 'alpha',
                    description: 'First',
                    body: 'a' * 40,
                  ),
                ],
              ),
            ),
          ),
          chatProvider.overrideWith(
            () => _SeededChatNotifier(const ChatState()),
          ),
          chatMcpConfigProvider.overrideWith(
            () => _SeededMcpConfigNotifier(const ChatMcpConfig(enabled: false)),
          ),
        ],
      );
      addTearDown(container.dispose);

      final segments = container.read(chatContextSegmentsProvider);
      expect(
        segments,
        const ChatContextSegments(
          skillsTokens: 0,
          historyTokens: 0,
          toolsTokens: 0,
          totalTokens: 0,
        ),
      );
    },
  );

  test('tools segment collapses when the chat does not use MCP', () async {
    final container = ProviderContainer(
      overrides: [
        skillsProvider.overrideWith(
          () => _SeededSkillsNotifier(const SkillsState(enabled: true)),
        ),
        chatProvider.overrideWith(() => _SeededChatNotifier(const ChatState())),
        chatMcpConfigProvider.overrideWith(
          () => _SeededMcpConfigNotifier(const ChatMcpConfig(enabled: false)),
        ),
      ],
    );
    addTearDown(container.dispose);

    final segments = container.read(chatContextSegmentsProvider);
    expect(
      segments,
      const ChatContextSegments(
        skillsTokens: 0,
        historyTokens: 0,
        toolsTokens: 0,
        totalTokens: 0,
      ),
    );
  });

  testWidgets('renders three segments with fractional widths and the ctx label', (
    tester,
  ) async {
    // serialize('alpha', 'A', 200 chars) = 35 + 200 = 235 chars;
    // serialize('beta', 'B', 200 chars) = 34 + 200 = 234 chars
    // => 469 chars => 117 tokens. One 400-char message => 100 tokens.
    // Tool payload 'Search the web' (14) + '{"type":"object"}' (17) => 8 tokens.
    // Total 225 -> fractions 117/225, 100/225, 8/225 of the 96px bar.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatParamsProvider.overrideWithValue(
            const ChatParameters(
              temperature: 0.7,
              topP: 0.9,
              maxTokens: 2048,
              contextLength: 4096,
            ),
          ),
          skillsProvider.overrideWith(
            () => _SeededSkillsNotifier(
              SkillsState(
                enabled: true,
                entries: [
                  SkillEntry(name: 'alpha', description: 'A', body: 'x' * 200),
                  SkillEntry(name: 'beta', description: 'B', body: 'y' * 200),
                ],
              ),
            ),
          ),
          chatProvider.overrideWith(
            () => _SeededChatNotifier(
              ChatState(
                messages: [_message('m1', MessageRole.user, 'm' * 400)],
              ),
            ),
          ),
          chatMcpConfigProvider.overrideWith(
            () => _SeededMcpConfigNotifier(const ChatMcpConfig(enabled: true)),
          ),
          availableToolsProvider.overrideWith((ref) => Future.value(_tools)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: TokenUsageIndicator(totalTokenCount: 2400),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ctx ~225/4096'), findsOneWidget);

    final skillsWidth = tester
        .getSize(find.byKey(const ValueKey('context_segment_skills')))
        .width;
    final historyWidth = tester
        .getSize(find.byKey(const ValueKey('context_segment_history')))
        .width;
    final toolsWidth = tester
        .getSize(find.byKey(const ValueKey('context_segment_tools')))
        .width;

    expect(skillsWidth, closeTo(96 * 117 / 225, 0.5));
    expect(historyWidth, closeTo(96 * 100 / 225, 0.5));
    expect(toolsWidth, closeTo(96 * 8 / 225, 0.5));
  });

  testWidgets(
    'an empty chat renders a zero-width bar without the ring failing',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatParamsProvider.overrideWithValue(
              const ChatParameters(
                temperature: 0.7,
                topP: 0.9,
                maxTokens: 2048,
                contextLength: 4096,
              ),
            ),
            skillsProvider.overrideWith(
              () => _SeededSkillsNotifier(const SkillsState(enabled: true)),
            ),
            chatProvider.overrideWith(
              () => _SeededChatNotifier(const ChatState()),
            ),
            chatMcpConfigProvider.overrideWith(
              () =>
                  _SeededMcpConfigNotifier(const ChatMcpConfig(enabled: true)),
            ),
            availableToolsProvider.overrideWith((ref) => Future.value([])),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: TokenUsageIndicator(totalTokenCount: 2400),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('ctx ~0/4096'), findsOneWidget);

      final skillsWidth = tester
          .getSize(find.byKey(const ValueKey('context_segment_skills')))
          .width;
      expect(skillsWidth, 0.0);
    },
  );
}
