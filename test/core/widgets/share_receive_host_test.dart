import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/services/share_receive_service.dart';
import 'package:localmind/core/widgets/share_receive_host.dart';
import 'package:localmind/features/chat/providers/chat_providers.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart'
    as conv;
import 'package:localmind/features/models/data/models/model_info.dart';
import 'package:localmind/features/os_widget/providers/os_widget_providers.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/servers/providers/server_providers.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _TestSettingsNotifier extends SettingsNotifier {
  _TestSettingsNotifier({this.customSettings});
  final AppSettings? customSettings;

  @override
  AppSettings build() =>
      customSettings ?? AppSettings(shareTargetEnabled: true);
}

class _StubServersNotifier extends ServersNotifier {
  _StubServersNotifier([this.servers = const []]);
  final List<Server> servers;

  @override
  Future<List<Server>> build() async => servers;
}

class _StubChatNotifier extends ChatNotifier {
  final List<String> messages = [];
  final List<List<File>> sentAttachments = [];
  int newConversations = 0;

  @override
  ChatState build() => const ChatState();

  @override
  Future<void> startNewConversation() async => newConversations++;

  @override
  Future<void> sendMessage(String content, {List<File>? attachments}) async {
    messages.add(content);
    sentAttachments.add(attachments ?? const []);
  }
}

Server _ollamaServer() => Server(
  id: 'ollama-1',
  name: 'Local Ollama',
  host: 'http://localhost',
  port: 11434,
  type: ServerType.ollama,
  createdAt: DateTime.now(),
  lastConnectedAt: DateTime.now(),
);

ModelInfo _model(Server server) => ModelInfo(
  id: 'llama3:8b',
  name: 'Llama 3 8B',
  serverId: server.id,
  serverType: ServerType.ollama,
);

Future<ProviderContainer> _pumpHost(
  WidgetTester tester, {
  required ShareReceiveService service,
  AppSettings? settings,
  List<Server> servers = const [],
  List extraOverrides = const [],
}) async {
  final container = ProviderContainer(
    overrides: [
      shareReceiveServiceProvider.overrideWithValue(service),
      settingsProvider.overrideWith(
        () => _TestSettingsNotifier(customSettings: settings),
      ),
      serversProvider.overrideWith(() => _StubServersNotifier(servers)),
      ...extraOverrides,
    ],
  );
  addTearDown(container.dispose);

  // Widget-test binding answers nothing for real platform channels; mock the
  // share channel so the host's cold-start pull resolves immediately.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('localmind/share_receive'),
        (call) async {
          return call.method == 'consumePendingShare'
              ? {'pending': false}
              : null;
        },
      );
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('localmind/share_receive'),
          null,
        ),
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const ShadApp(
        home: Scaffold(body: ShareReceiveHost(child: Text('Root Body'))),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

void main() {
  testWidgets('text share starts a new chat and sets the pending prompt', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final service = ShareReceiveService(supportedPlatform: true);

    final container = await _pumpHost(tester, service: service);
    container
        .read(conv.activeConversationIdProvider.notifier)
        .setActiveConversationId('conv-1');

    service.dispatchPayload(
      const SharedPayload.text(text: 'Shared note from another app'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      container.read(widgetPendingPromptProvider),
      'Shared note from another app',
    );
    expect(container.read(conv.activeConversationIdProvider), isNull);
  });

  testWidgets(
    'share-target toggle off ignores payloads and clears stashed files',
    (tester) async {
      final service = ShareReceiveService(supportedPlatform: true);
      final tempDir = Directory.systemTemp.createTempSync('share_target');
      addTearDown(() => tempDir.delete(recursive: true));
      final image = File('${tempDir.path}/ignored.png');
      image.writeAsBytesSync(<int>[1, 2, 3, 4]);

      final container = await _pumpHost(
        tester,
        service: service,
        settings: AppSettings(shareTargetEnabled: false),
      );
      container
          .read(conv.activeConversationIdProvider.notifier)
          .setActiveConversationId('conv-1');

      service.dispatchPayload(
        const SharedPayload.text(text: 'Should be dropped'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(container.read(widgetPendingPromptProvider), isNull);
      expect(container.read(conv.activeConversationIdProvider), 'conv-1');

      service.dispatchPayload(
        SharedPayload.file(filePath: image.path, mimeType: 'image/png'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(image.existsSync(), isFalse);
    },
  );

  testWidgets(
    'a single image share opens a new chat with the attachment and cleans up',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = ShareReceiveService(supportedPlatform: true);
      final server = _ollamaServer();
      final model = _model(server);
      final tempDir = Directory.systemTemp.createTempSync('share_target');
      addTearDown(() => tempDir.delete(recursive: true));
      final image = File('${tempDir.path}/snapshot.png');
      image.writeAsBytesSync(<int>[9, 8, 7, 6]);

      final chat = _StubChatNotifier();
      final container = await _pumpHost(
        tester,
        service: service,
        settings: AppSettings(
          shareTargetEnabled: true,
          defaultModelId: model.id,
          defaultModelServerId: server.id,
        ),
        servers: [server],
        extraOverrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          chatProvider.overrideWith(() => chat),
          availableModelsProvider(
            server.id,
          ).overrideWith((ref) => Future.value([model])),
        ],
      );
      container
          .read(conv.activeConversationIdProvider.notifier)
          .setActiveConversationId('conv-1');

      service.dispatchPayload(
        SharedPayload.file(filePath: image.path, mimeType: 'image/png'),
      );
      await tester.pumpAndSettle();

      expect(chat.newConversations, 1);
      expect(chat.messages, ['']);
      expect(chat.sentAttachments.single.single.path, image.path);
      expect(image.existsSync(), isFalse);
    },
  );

  testWidgets(
    'a multi-image share attaches every file and cleans up after the send',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = ShareReceiveService(supportedPlatform: true);
      final server = _ollamaServer();
      final model = _model(server);
      final tempDir = Directory.systemTemp.createTempSync('share_target');
      addTearDown(() => tempDir.delete(recursive: true));
      final first = File('${tempDir.path}/one.png');
      final second = File('${tempDir.path}/two.jpg');
      first.writeAsBytesSync(<int>[1, 1, 1, 1]);
      second.writeAsBytesSync(<int>[2, 2, 2, 2]);

      final chat = _StubChatNotifier();
      await _pumpHost(
        tester,
        service: service,
        settings: AppSettings(
          shareTargetEnabled: true,
          defaultModelId: model.id,
          defaultModelServerId: server.id,
        ),
        servers: [server],
        extraOverrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          chatProvider.overrideWith(() => chat),
          availableModelsProvider(
            server.id,
          ).overrideWith((ref) => Future.value([model])),
        ],
      );

      service.dispatchPayload(
        SharedPayload.files(
          paths: [first.path, second.path],
          mimeTypes: const ['image/png', 'image/jpeg'],
        ),
      );
      await tester.pumpAndSettle();

      expect(chat.newConversations, 1);
      expect(chat.messages, ['']);
      expect(chat.sentAttachments.single.map((f) => f.path), [
        first.path,
        second.path,
      ]);
      expect(first.existsSync(), isFalse);
      expect(second.existsSync(), isFalse);
    },
  );

  testWidgets(
    'file share without a default model keeps the stash and does not send',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = ShareReceiveService(supportedPlatform: true);
      final tempDir = Directory.systemTemp.createTempSync('share_target');
      addTearDown(() => tempDir.delete(recursive: true));
      final image = File('${tempDir.path}/kept.png');
      image.writeAsBytesSync(<int>[5, 5, 5, 5]);

      final chat = _StubChatNotifier();
      await _pumpHost(
        tester,
        service: service,
        settings: AppSettings(shareTargetEnabled: true),
        extraOverrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          chatProvider.overrideWith(() => chat),
        ],
      );

      service.dispatchPayload(
        SharedPayload.file(filePath: image.path, mimeType: 'image/png'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(chat.newConversations, 0);
      expect(chat.messages, isEmpty);
      // No default model means the share cannot land anywhere; the stashed
      // copy is preserved rather than silently destroyed.
      expect(image.existsSync(), isTrue);
    },
  );
}
