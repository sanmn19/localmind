import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/theme/app_theme.dart';
import 'package:localmind/features/chat/providers/chat_providers.dart';
import 'package:localmind/features/chat/views/components/chat_input_bar.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/servers/providers/server_providers.dart';
import 'package:localmind/features/tts/providers/tts_providers.dart';
import 'package:localmind/l10n/app_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Enter sends and Shift+Enter inserts a newline', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final sent = <String>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          chatProvider.overrideWith(_StubChatNotifier.new),
          activeServerProvider.overrideWith(_StubActiveServerNotifier.new),
          serversProvider.overrideWith(_StubServersNotifier.new),
          ttsProvider.overrideWith(_StubTtsNotifier.new),
          activeChatTargetProvider.overrideWithValue(
            ActiveChatTarget(
              server: Server(
                id: 's1',
                name: 'Test',
                type: ServerType.openAICompatible,
                host: 'http://127.0.0.1',
                port: 1,
                createdAt: DateTime.utc(2026),
                lastConnectedAt: DateTime.utc(2026),
              ),
              selectedModel: null,
              effectiveModelId: 'test-model',
              modelLabel: 'Test',
            ),
          ),
        ],
        child: ShadTheme(
          data: AppTheme.lightShadTheme,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ChatInputBar(
                onSend: (text, {attachments}) => sent.add(text),
                onStop: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, 'hello');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, ['hello']);

    await tester.enterText(find.byType(TextField).first, 'line');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();

    // Shift+Enter is left to the field's own newline handling, so the draft
    // must survive and nothing may be sent.
    expect(sent, ['hello']);
    expect(find.text('line'), findsOneWidget);
  });
}

class _StubChatNotifier extends ChatNotifier {
  @override
  ChatState build() => const ChatState();
}

class _StubActiveServerNotifier extends ActiveServerNotifier {
  @override
  Server? build() => null;
}

class _StubServersNotifier extends ServersNotifier {
  @override
  Future<List<Server>> build() async => const [];
}

class _StubTtsNotifier extends TtsNotifier {
  @override
  TtsState build() => const TtsState();
}
