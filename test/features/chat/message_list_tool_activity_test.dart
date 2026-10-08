import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/providers/chat_notifier.dart';
import 'package:localmind/features/chat/views/components/chat_bubble.dart';
import 'package:localmind/features/chat/views/components/chat_bubble/tool_bubble/tool_bubble.dart';
import 'package:localmind/features/chat/views/components/message_list/components/tool_activity_block.dart';
import 'package:localmind/features/chat/views/components/message_list/message_list.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/l10n/app_localizations.dart';

Message _message(
  String id,
  MessageRole role, {
  String? group,
  int index = 0,
  bool active = true,
  int threadOrder = 0,
  String content = '',
  List<ToolCallData>? toolCalls,
  String? toolCallId,
  String? parent,
}) {
  return Message(
    id: id,
    conversationId: 'c',
    role: role,
    content: content,
    createdAt: DateTime.utc(2026, 10, 5, 0, 0, threadOrder),
    toolCalls: toolCalls,
    toolCallId: toolCallId,
    variantGroupId: group,
    variantIndex: index,
    threadOrder: threadOrder,
    isActiveVariant: active,
    parentMessageId: parent,
  );
}

const _chainTailContent = 'The final answer of the chain.';

Widget _listHarness({
  required List<Message> messages,
  required List<Message> allMessages,
}) {
  return ProviderScope(
    overrides: [
      chatProvider.overrideWith(_NoopChatNotifier.new),
      settingsProvider.overrideWith(_NoopSettingsNotifier.new),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: MessageList(
          scrollController: ScrollController(),
          messages: messages,
          allMessages: allMessages,
          isStreaming: false,
          onRetry: (_) {},
          onDelete: (_) {},
          onEdit: (_, _) {},
          onEditAssistant: (_, _) {},
          onBranch: (_) {},
          onContinue: (_) {},
          onCycleVariant: (_, _) {},
          onModelPicker: () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('tool rows resolved into a chain block are not rendered', (
    tester,
  ) async {
    final user = _message(
      'user',
      MessageRole.user,
      group: 'U',
      content: 'question',
    );
    final round = _message(
      'round',
      MessageRole.assistant,
      group: 'A',
      threadOrder: 1,
      toolCalls: [
        ToolCallData(
          id: 'call_1',
          toolName: 'web.search',
          arguments: {'query': 'flutter'},
        ),
      ],
    );
    final boundToolRow = _message(
      'tool-1',
      MessageRole.tool,
      toolCallId: 'call_1',
      parent: 'round',
      group: 'A',
    );
    final tail = _message(
      'tail',
      MessageRole.assistant,
      group: 'A',
      threadOrder: 2,
      content: _chainTailContent,
    );

    final allMessages = [user, round, boundToolRow, tail];
    // A timeline that still carries the chain's tool row (legacy shape):
    // the renderer must consume it into the block above the tail.
    final messages = [user, boundToolRow, tail];

    await tester.pumpWidget(
      _listHarness(messages: messages, allMessages: allMessages),
    );
    await tester.pumpAndSettle();

    // The consolidated card renders above the final answer...
    expect(find.text('Web activity'), findsOneWidget);
    expect(find.text(_chainTailContent), findsOneWidget);
    // ...and the per-round tool-result bubble is gone.
    expect(find.byType(ToolBubble), findsNothing);
    expect(find.text('tool result text'), findsNothing);

    // The block sits above the answer bubble (earlier in the list order).
    final order = tester
        .widgetList(
          find.byWidgetPredicate(
            (w) =>
                w is ToolActivityBlock ||
                (w is ChatBubble && w.message.role == MessageRole.assistant),
          ),
        )
        .toList();
    expect(order, hasLength(2));
    expect(order.first, isA<ToolActivityBlock>());
    expect(order.last, isA<ChatBubble>());
  });

  testWidgets('orphan tool rows keep their own bubble', (tester) async {
    final user = _message(
      'user',
      MessageRole.user,
      group: 'U',
      content: 'question',
    );
    final orphan = _message(
      'orphan',
      MessageRole.tool,
      parent: 'ghost',
      content: 'orphan result text',
    );
    final plainTail = _message(
      'tail',
      MessageRole.assistant,
      threadOrder: 2,
      content: 'a plain answer',
    );

    await tester.pumpWidget(
      _listHarness(
        messages: [user, orphan, plainTail],
        allMessages: [user, orphan, plainTail],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Web activity'), findsNothing);
    expect(find.byType(ToolBubble), findsOneWidget);
    expect(find.text('orphan result text'), findsOneWidget);
    expect(find.text('a plain answer'), findsOneWidget);
  });
}

class _NoopChatNotifier extends ChatNotifier {
  @override
  ChatState build() => const ChatState();
}

class _NoopSettingsNotifier extends SettingsNotifier {
  @override
  AppSettings build() => AppSettings();
}
