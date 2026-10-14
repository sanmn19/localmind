import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:localmind/core/logger/app_logger.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/ask_local/data/ask_local_card_bootstrap.dart';
import 'package:localmind/features/ask_local/data/ask_local_card_channel.dart';
import 'package:localmind/features/ask_local/data/ask_local_conversation_service.dart';
import 'package:localmind/features/ask_local/data/ask_local_main_channel.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/chat/providers/chat_params_providers.dart';
import 'package:localmind/features/chat/providers/model_selection_providers.dart';
import 'package:localmind/features/models/data/models/model_info.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/conversations/data/models/conversation.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart'
    show webMcpServerUrl;
import 'package:localmind/features/mail/mail_mcp_server.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/servers/providers/server_providers.dart'
    as server_providers;
import 'package:logger/logger.dart';

// Main-engine ask-local tests (task 5): the execute-tool bridge (the ONLY
// channel path the card's approved calls take — shape pinned verbatim to
// the card decoder {success, output, error?}), the FULL envelope resolved
// MAIN-side at overlay-open (parity toolset, pre-computed conversationId,
// typed v2 paths) and the open-path ack contract (truthy = stash cleared).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUp(() {
    Log.attachOutput(_DiscardingLogOutput());
  });

  group('askLocalExecuteTool handler', () {
    test('ok path: registry result lands as {success, output}', () async {
      final calls = <String>[];
      final container = ProviderContainer(
        overrides: [
          askLocalToolExecutorProvider.overrideWithValue(
            (toolName, arguments) async {
              calls.add('$toolName:${arguments.length}');
              return (success: true, output: 'docs found', error: null);
            },
          ),
        ],
      );
      addTearDown(container.dispose);

      final reply = await _executeToolCall(container, 'web.search', {
        'query': 'rive',
      });
      expect(calls, ['web.search:1']);
      expect(reply, {'success': true, 'output': 'docs found', 'error': null});
    });

    test('failure path: a failed ToolExecutionResult replies ok:false with '
        'the error message (error key present, output empty)', () async {
      final container = ProviderContainer(
        overrides: [
          askLocalToolExecutorProvider.overrideWithValue(
            (_, _) async =>
                (success: false, output: '', error: 'Tool not found'),
          ),
        ],
      );
      addTearDown(container.dispose);

      final reply = await _executeToolCall(
        container,
        'unknown.tool',
        const <String, dynamic>{},
      );
      expect(reply['success'], isFalse);
      expect(reply['output'], '');
      expect(reply['error'], 'Tool not found');
    });

    test('exception path: a thrown execution degrades to ok:false with the '
        'throw message — never escapes the handler', () async {
      final container = ProviderContainer(
        overrides: [
          askLocalToolExecutorProvider.overrideWithValue(
            (_, _) async => throw StateError('registry exploded'),
          ),
        ],
      );
      addTearDown(container.dispose);

      final reply = await _executeToolCall(
        container,
        'terminal.run',
        {'cmd': 'ls'},
      );
      expect(reply['success'], isFalse);
      expect(reply['output'], '');
      expect(reply['error'], contains('registry exploded'));
    });

    test('disposed-container exception degrades typed as well', () async {
      final container = ProviderContainer(
        overrides: [
          askLocalToolExecutorProvider.overrideWithValue(
            (_, _) async =>
                (success: true, output: 'never', error: null as String?),
          ),
        ],
      );
      container.dispose();

      final reply = await _executeToolCall(
        container,
        'web.search',
        const <String, dynamic>{},
      );
      expect(reply['success'], isFalse);
      expect(reply['error'], isNotNull);
      expect(reply['output'], '');
    });

    test('malformed call: missing/empty toolName replies the typed failure '
        'without touching the registry', () async {
      var watched = 0;
      final container = ProviderContainer(
        overrides: [
          askLocalToolExecutorProvider.overrideWithValue(
            (_, _) async {
              watched++;
              return (
                success: true,
                output: 'should not run',
                error: null as String?,
              );
            },
          ),
        ],
      );
      addTearDown(container.dispose);

      final noName = await _executeToolCall(
        container,
        '',
        const <String, dynamic>{},
      );
      expect(watched, 0);
      expect(noName['success'], isFalse);
      expect(noName['output'], '');
      expect(noName['error'], 'malformed askLocalExecuteTool call');
    });

    test('the production executor maps registry outcomes ONLY through '
        'plain execute() (verbatim-bridge provider shape)', () async {
      // Direct pin of the bridge contract: {success, output, error?} keys
      // travel verbatim to the card decoder; no approval machinery value.
      final container = ProviderContainer(
        overrides: [
          askLocalToolExecutorProvider.overrideWithValue(
            (_, _) async => (success: true, output: 'ok out', error: null),
          ),
        ],
      );
      addTearDown(container.dispose);
      final executor = container.read(askLocalToolExecutorProvider);
      final outcome = await executor('mail.send', {'to': 'x@y.z'});
      expect(outcome.success, isTrue);
      expect(outcome.output, 'ok out');
    });
  });

  group('open-envelope handoff (askLocalRequestArrived)', () {
    test('resolves the FULL envelope MAIN-side and hands EVERYTHING to '
        'openOverlayNow', () async {
      final opens = <Map<String, Object?>>[];
      final channel = AskLocalMainChannel(
        openOverlay: ({capturePath, required selectedText, bootstrap = const {}}) {
          opens.add(<String, Object?>{
            'capturePath': capturePath,
            'selectedText': selectedText,
            'bootstrap': bootstrap,
          });
          return Future.value(true);
        },
      );
      final container = await _resolverContainer();
      addTearDown(container.dispose);

      final reply = await channel.handle(
        const MethodCall('askLocalRequestArrived', {
          'selectedText': 'pick me',
          'capturePath': '/staged/a.png',
        }),
        container,
      );
      expect(reply, isTrue);
      expect(opens, hasLength(1));
      final handed = opens.single;
      expect(handed['selectedText'], 'pick me');
      expect(handed['capturePath'], '/staged/a.png');

      // The card-side decode of the shipped envelope consumes everything:
      final bootstrap = bootstrapFromMap(handed['bootstrap'])!;
      expect(bootstrap.requestId, isNotEmpty);
      expect(bootstrap.storeDir, '/docs/localmind_objectbox');
      expect(bootstrap.conversationId, 'ask-local-conv');
      expect(bootstrap.modelId, 'model-x');
      expect(bootstrap.server.id, 'srv-1');
      expect(bootstrap.settingsJson, isNotEmpty);
      expect(
        bootstrap.attachmentsDirPath,
        '/docs/attachments',
      );
      expect(bootstrap.appDirPath, '/docs');
      expect(
        bootstrap.schemaVersion,
        AskLocalCardBootstrapPayload.currentSchemaVersion,
      );
      expect(
        [for (final def in bootstrap.toolDefs) def.name],
        containsAll(['web.search', 'mail.send']),
      );
      expect(bootstrap.params.systemPrompt, 'persona framing');
      // The delivery id the card dedupes on IS the main requestId.
      final delivery = AskLocalCardDelivery.fromMap(<String, Object?>{
        ...handed,
        'bootstrap': handed['bootstrap'],
      })!;
      expect(delivery.deliveryId, bootstrap.requestId);
    });

    test('two resolved envelopes NEVER share a requestId (distinct id = '
        'fresh ask; the card dedupe keys on it)', () async {
      final ids = <String>[];
      final channel = AskLocalMainChannel(
        openOverlay: ({capturePath, required selectedText, bootstrap = const {}}) {
          final parsed = bootstrapFromMap(bootstrap);
          ids.add(parsed!.requestId);
          return Future.value(true);
        },
      );
      final container = await _resolverContainer();
      addTearDown(container.dispose);

      await channel.handle(_arrivedCall(), container);
      await channel.handle(_arrivedCall(), container);
      expect(ids, hasLength(2));
      expect(ids[0], isNot(ids[1]));
    });

    test('the round-trip wire decode preserves every v2 field verbatim',
        () async {
      final container = await _resolverContainer();
      addTearDown(container.dispose);
      final payload = (await resolveAskLocalCardBootstrap(container))!;
      final wire = bootstrapToWire(payload);
      final decoded = bootstrapFromMap(wire)!;

      expect(decoded.requestId, payload.requestId);
      expect(decoded.storeDir, payload.storeDir);
      expect(decoded.conversationId, payload.conversationId);
      expect(decoded.modelId, payload.modelId);
      expect(decoded.server.id, payload.server.id);
      expect(decoded.server.host, payload.server.host);
      expect(decoded.params.systemPrompt, payload.params.systemPrompt);
      expect(decoded.toolDefs, hasLength(payload.toolDefs.length));
      expect(decoded.settingsJson, payload.settingsJson);
      expect(decoded.attachmentsDirPath, payload.attachmentsDirPath);
      expect(decoded.appDirPath, payload.appDirPath);
      expect(decoded.schemaVersion, payload.schemaVersion);
    });

    test('a v1 envelope (no v2 keys) decodes tolerant: schemaVersion 0, '
        'null optional paths, degraded defaults stay usable', () {
      final legacy = bootstrapFromMap(<String, Object?>{
        'requestId': 'req-old',
        'storeDir': '/docs/localmind_objectbox',
        'modelId': 'model-x',
        'server': <String, Object?>{
          'id': 'srv-1',
          'name': 'remote',
          'type': 'openAICompatible',
          'host': '10.0.0.2',
          'port': 8000,
        },
        'params': <String, Object?>{},
        'toolDefs': <Object?>[],
        'settings': '{}',
      })!;
      expect(legacy.schemaVersion, 0);
      expect(legacy.attachmentsDirPath, isNull);
      expect(legacy.appDirPath, isNull);
    });

    test('an unresolvable target resolves no envelope — the card still '
        'opens, degraded', () async {
      Object? openedBootstrap;
      final channel = AskLocalMainChannel(
        openOverlay: ({capturePath, required selectedText, bootstrap = const {}}) {
          openedBootstrap = bootstrap;
          return Future.value(true);
        },
      );
      final container = await _resolverContainer(withTarget: false);
      addTearDown(container.dispose);

      final reply = await channel.handle(_arrivedCall(), container);
      expect(reply, isTrue);
      expect(openedBootstrap, isEmpty);
    });
  });

  group('consumePendingAskLocal pull', () {
    test('a pending staging payload rides the same full-resolution path',
        () async {
      final opens = <String>[];
      final channel = AskLocalMainChannel(
        openOverlay: ({capturePath, required selectedText, bootstrap = const {}}) {
          opens.add('open');
          return Future.value(true);
        },
      );
      final container = await _resolverContainer();
      addTearDown(container.dispose);
      // The MethodChannel has no Kotlin host under flutter_test — the
      // bounded pull degrades log-only instead of hanging the install.
      await channel.consumePendingFromKotlin(container);
      expect(opens, isEmpty);
    });
  });

  test('install wires the live handler; uninstall detaches idempotently',
      () async {
    final container = await _resolverContainer();
    addTearDown(container.dispose);
    AskLocalMainChannel.install(container);
    expect(AskLocalMainChannel.isInstalled, isTrue);
    AskLocalMainChannel.uninstall();
    AskLocalMainChannel.uninstall();
    expect(AskLocalMainChannel.isInstalled, isFalse);
  });
}

Future<Map<String, dynamic>> _executeToolCall(
  ProviderContainer container,
  String toolName,
  Map<String, dynamic> arguments,
) async {
  final channel = AskLocalMainChannel(
    openOverlay: ({
      capturePath,
      required selectedText,
      bootstrap = const <String, Object?>{},
    }) =>
        Future.value(true),
  );
  final reply = await channel.executeTool(
    MethodCall('askLocalExecuteTool', {
      'toolName': toolName,
      'arguments': arguments,
    }),
    container,
  );
  return (reply ?? <String, dynamic>{}) as Map<String, dynamic>;
}

MethodCall _arrivedCall() => const MethodCall('askLocalRequestArrived', {
      'selectedText': 'pick me',
      'capturePath': '/staged/a.png',
    });

Future<ProviderContainer> _resolverContainer({bool withTarget = true}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final server = Server(
    id: 'srv-1',
    name: 'remote',
    type: ServerType.openAICompatible,
    host: '10.0.0.2',
    port: 8000,
    isDefault: false,
    createdAt: DateTime.now(),
    lastConnectedAt: DateTime.now(),
    status: ConnectionStatus.connected,
    iconName: 'strokeRoundedGlobe',
  );
  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      server_providers.activeServerProvider.overrideWith(() => _StubActiveServer()),
      selectedModelProvider.overrideWith(() => _StubSelectedModel()),
      server_providers.connectionStatusProvider.overrideWith(
        () => _StubConnectionStatus(),
      ),
      activeChatTargetProvider.overrideWithValue(
        ActiveChatTarget(
          server: withTarget ? server : null,
          selectedModel: null,
          effectiveModelId: withTarget ? 'model-x' : null,
          modelLabel: withTarget ? 'model-x' : 'No model',
        ),
      ),
      storageDirectoryProvider.overrideWith((ref) async => Directory('/docs')),
      askLocalConversationServiceProvider.overrideWith(
        (ref) => _FakeConversationService(),
      ),
      chatParamsProvider.overrideWithValue(
        ChatParameters.defaults().copyWith(systemPrompt: 'persona framing'),
      ),
      forkChatToolsetProvider.overrideWith(
        (ref) async => [
          ToolDefinition(
            name: 'web.search',
            description: 'search',
            inputSchema: const <String, dynamic>{},
            providerType: ToolProviderType.mcp,
            providerRef: webMcpServerUrl,
          ),
          ToolDefinition(
            name: 'mail.send',
            description: 'send mail',
            inputSchema: const <String, dynamic>{},
            providerType: ToolProviderType.mcp,
            providerRef: mailMcpServerUrl,
          ),
        ],
      ),
    ],
  );
}

class _StubActiveServer extends server_providers.ActiveServerNotifier {
  @override
  Server? build() => null;
}

class _StubSelectedModel extends SelectedModelNotifier {
  @override
  ModelInfo? build() => null;
}

class _StubConnectionStatus extends server_providers.ConnectionStatusNotifier {
  @override
  ConnectionStatus build() => ConnectionStatus.disconnected;
}

class _FakeConversationService implements AskLocalConversationService {
  static final Conversation conversation = Conversation(
    id: 'ask-local-conv',
    title: askLocalConversationTitle,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    specialKind: askLocalConversationKind,
  );

  @override
  Future<Conversation> ensure() => Future.value(conversation);
}

class _DiscardingLogOutput extends LogOutput {
  @override
  void output(OutputEvent event) {}
}
