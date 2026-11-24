import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/tool_approval_notifier.dart';
import 'package:localmind/features/chat/data/tool_approval_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('always-chat and always-global are scoped and arg-specific', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final policy = ToolApprovalPolicy(prefs);

    expect(
      policy.isAlwaysApproved(
        conversationId: 'chat-1',
        toolName: 'web.fetch',
        args: const {'url': 'https://example.com'},
      ),
      isFalse,
    );

    await policy.remember(
      decision: ToolApprovalDecision.alwaysChat,
      conversationId: 'chat-1',
      toolName: 'web.fetch',
      args: const {'url': 'https://example.com'},
    );
    expect(
      policy.isAlwaysApproved(
        conversationId: 'chat-1',
        toolName: 'web.fetch',
        args: const {'url': 'https://example.com'},
      ),
      isTrue,
    );
    expect(
      policy.isAlwaysApproved(
        conversationId: 'chat-2',
        toolName: 'web.fetch',
        args: const {'url': 'https://example.com'},
      ),
      isFalse,
    );
    expect(
      policy.isAlwaysApproved(
        conversationId: 'chat-1',
        toolName: 'web.fetch',
        args: const {'url': 'https://other.example'},
      ),
      isFalse,
    );

    await policy.remember(
      decision: ToolApprovalDecision.alwaysGlobal,
      conversationId: 'chat-1',
      toolName: 'web.search',
      args: const {'query': 'x'},
    );
    expect(
      policy.isAlwaysApproved(
        conversationId: 'chat-2',
        toolName: 'web.search',
        args: const {'query': 'x'},
      ),
      isTrue,
    );
  });

  test('approval payload round-trips', () {
    final payload = ToolApprovalPayload.compose('a1', 'c1');
    final parsed = ToolApprovalPayload.tryParse(payload);
    expect(parsed?.approvalId, 'a1');
    expect(parsed?.conversationId, 'c1');
    expect(ToolApprovalPayload.tryParse('foreign'), isNull);
  });
}
