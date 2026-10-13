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

    // The skills segment estimates the INDEX the system-builder injects:
    // header + skills.read guidance + two `- name: description` rows,
    // no bodies — far below the old 138-char full serialization.
    final indexChars = buildSkillsSystemSection(skills).length;
    final skillsTokens = approxTokensFromChars(indexChars);
    expect(indexChars, lessThan(400));
    expect(skillsTokens, lessThan(100));
    // 600 message chars => 150 tokens.
    // Tool payload 'Search the web' (14) + '{"type":"object"}' (17) => 8 tokens.
    expect(
      segments,
      ChatContextSegments(
        skillsTokens: skillsTokens,
        historyTokens: 150,
        toolsTokens: 8,
        totalTokens: skillsTokens + 158,
      ),
    );
  });

  test(
    'a huge skill body stays out of the skills segment (index only)',
    () async {
      final skills = [
        SkillEntry(name: 'big_one', description: 'Big', body: 'b' * 20000),
      ];
      final container = ProviderContainer(
        overrides: [
          skillsProvider.overrideWith(
            () => _SeededSkillsNotifier(
              SkillsState(enabled: true, entries: skills),
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

      final indexChars = buildSkillsSystemSection(skills).length;
      expect(segments.skillsTokens, approxTokensFromChars(indexChars));
      // 20000 body chars used to estimate ~5050 tokens via full
      // serialization; the index-only meter stays tiny.
      expect(segments.skillsTokens, lessThan(50));
      expect(
        segments,
        ChatContextSegments(
          skillsTokens: segments.skillsTokens,
          historyTokens: 0,
          toolsTokens: 0,
          totalTokens: segments.skillsTokens,
        ),
      );
    },
  );

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
    // The skills segment estimates the INDEX only: header + guidance +
    // `- alpha: A` + `- beta: B` rows (no 200-char bodies) — compute the
    // expected widths from the same public builder the meter mirrors.
    // One 400-char message => 100 tokens.
    // Tool payload 'Search the web' (14) + '{"type":"object"}' (17) => 8 tokens.
    final skillsEntries = [
      SkillEntry(name: 'alpha', description: 'A', body: 'x' * 200),
      SkillEntry(name: 'beta', description: 'B', body: 'y' * 200),
    ];
    final indexChars = buildSkillsSystemSection(skillsEntries).length;
    final skillsTokens = approxTokensFromChars(indexChars);
    const historyTokens = 100;
    const toolsTokens = 8;
    final totalTokens = skillsTokens + historyTokens + toolsTokens;
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
              SkillsState(enabled: true, entries: skillsEntries),
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

    expect(find.text('ctx ~$totalTokens/4096'), findsOneWidget);

    final skillsWidth = tester
        .getSize(find.byKey(const ValueKey('context_segment_skills')))
        .width;
    final historyWidth = tester
        .getSize(find.byKey(const ValueKey('context_segment_history')))
        .width;
    final toolsWidth = tester
        .getSize(find.byKey(const ValueKey('context_segment_tools')))
        .width;

    expect(skillsWidth, closeTo(96 * skillsTokens / totalTokens, 0.5));
    expect(historyWidth, closeTo(96 * historyTokens / totalTokens, 0.5));
    expect(toolsWidth, closeTo(96 * toolsTokens / totalTokens, 0.5));
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
