import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/core/theme/app_theme.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/providers/chat_notifier.dart';
import 'package:localmind/features/chat/providers/model_selection_providers.dart';
import 'package:localmind/features/chat/providers/smart_reply_providers.dart';
import 'package:localmind/features/chat/views/chat_screen.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/desktop/views/components/desktop_chat_window.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/servers/providers/server_providers.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/features/stt/providers/stt_providers.dart';
import 'package:localmind/features/tts/providers/tts_providers.dart';
import 'package:localmind/l10n/app_localizations.dart';
import 'package:localmind/objectbox.g.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Conversation conversation(String id) => Conversation(
    id: id,
    title: 'Chat $id',
    createdAt: DateTime.utc(2026, 10, 1),
    updatedAt: DateTime.utc(2026, 10, 1),
  );

  Message message(String id, String conversationId, String content) => Message(
    id: id,
    conversationId: conversationId,
    role: MessageRole.user,
    content: content,
    createdAt: DateTime.utc(2026, 10, 1),
    variantGroupId: id,
    threadOrder: 0,
    isActiveVariant: true,
  );

  ProviderContainer createContainer({
    required List<Conversation> conversations,
    Map<String, List<Message>> messages = const {},
    Future<List<Conversation>> Function()? conversationsFuture,
  }) {
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(_FakeDatabase(_FakeStore(messages))),
        conv.conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier(conversations, conversationsFuture),
        ),
        settingsProvider.overrideWith(_TestSettingsNotifier.new),
        activeServerProvider.overrideWith(_NoServerNotifier.new),
        activeChatTargetProvider.overrideWithValue(
          const ActiveChatTarget(
            server: null,
            selectedModel: null,
            effectiveModelId: null,
            modelLabel: 'No model',
          ),
        ),
        smartRepliesProvider.overrideWith((ref) async => const <String>[]),
        sttProvider.overrideWith(_StubSttNotifier.new),
        ttsProvider.overrideWith(_StubTtsNotifier.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pumpWindows(
    WidgetTester tester,
    ProviderContainer container,
    List<String> conversationIds,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadTheme(
          data: AppTheme.lightShadTheme,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Column(
                children: [
                  for (final id in conversationIds)
                    SizedBox(
                      height: 300,
                      child: DesktopChatWindow(conversationId: id),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('two chat windows keep independent conversations', (
    tester,
  ) async {
    // The app-wide resume would otherwise load c2 into every new chat notifier.
    SharedPreferences.setMockInitialValues({'lastActiveConversationId': 'c2'});
    prefs = await SharedPreferences.getInstance();

    final container = createContainer(
      conversations: [conversation('c1'), conversation('c2')],
      messages: {
        'c1': [message('m1', 'c1', 'one')],
        'c2': [message('m2', 'c2', 'two')],
      },
    );

    await pumpWindows(tester, container, ['c1', 'c2']);
    await tester.pumpAndSettle();

    expect(find.text('one', findRichText: true), findsOneWidget);
    expect(find.text('two', findRichText: true), findsOneWidget);

    final windowContainers = [
      for (final element in tester.elementList(find.byType(ChatScreen)))
        ProviderScope.containerOf(element, listen: false),
    ];
    expect(windowContainers, hasLength(2));
    expect(
      {
        for (final window in windowContainers)
          window.read(chatProvider).messages.single.content,
      },
      {'one', 'two'},
    );
    expect(container.read(conv.activeConversationIdProvider), isNull);
    expect(container.read(conv.activeConversationProvider), isNull);
  });

  testWidgets('a window whose conversation is gone shows an empty state', (
    tester,
  ) async {
    final container = createContainer(conversations: [conversation('c1')]);

    await pumpWindows(tester, container, ['missing']);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('desktop-chat-missing')), findsOneWidget);
    expect(find.byType(ChatScreen), findsNothing);
  });

  testWidgets('a window shows a spinner while conversations load', (
    tester,
  ) async {
    final pending = Completer<List<Conversation>>();
    final container = createContainer(
      conversations: const [],
      conversationsFuture: () => pending.future,
      messages: {
        'c1': [message('m1', 'c1', 'ready')],
      },
    );

    await pumpWindows(tester, container, ['c1']);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    pending.complete([conversation('c1')]);
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
  });
}

class _FakeConversationsNotifier extends conv.ConversationsNotifier {
  _FakeConversationsNotifier(this.conversations, this.conversationsFuture);

  final List<Conversation> conversations;
  final Future<List<Conversation>> Function()? conversationsFuture;

  @override
  Future<List<Conversation>> build() {
    final future = conversationsFuture;
    return future == null ? Future.value(conversations) : future();
  }
}

class _TestSettingsNotifier extends SettingsNotifier {
  @override
  AppSettings build() => AppSettings(hasAskedForNotifications: true);
}

class _NoServerNotifier extends ActiveServerNotifier {
  @override
  Server? build() => null;
}

class _StubSttNotifier extends SttNotifier {
  @override
  SttState build() => const SttState();
}

class _StubTtsNotifier extends TtsNotifier {
  @override
  TtsState build() => const TtsState();
}

class _FakeDatabase extends Fake implements ObjectBoxStore {
  _FakeDatabase(this.store);

  @override
  final Store store;
}

class _FakeStore extends Fake implements Store {
  _FakeStore(this.messagesByConversation);

  final Map<String, List<Message>> messagesByConversation;

  @override
  Future<R> runInTransactionAsync<R, T>(
    TxMode mode,
    R Function(Store, T) fn,
    T arg,
  ) async {
    if (arg is String) {
      return (messagesByConversation[arg] ?? const <Message>[]) as R;
    }
    return fn(this, arg);
  }
}
