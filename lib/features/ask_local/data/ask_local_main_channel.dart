import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/core/logger/app_logger.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/screen_memory_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/core/utils/uuid.dart';
import 'package:localmind/features/chat/providers/chat_params_providers.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/providers/model_selection_providers.dart'
    show activeChatTargetProvider;
import 'package:localmind/features/chat/providers/tooling_providers.dart'
    show forkChatToolsetProvider, toolRegistryProvider;
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:path/path.dart' as p;

import 'ask_local_card_bootstrap.dart';
import 'ask_local_conversation_service.dart';
import 'ask_local_overlay_access.dart';
import 'ask_local_payload.dart';

/// The MAIN engine's half of the ask-local channels — created in Task 5.
///
/// `loadmind/ask_local` carries three Dart-facing methods:
/// - `askLocalExecuteTool` — the card engine's APPROVED tool calls bridged
///   through Kotlin ([NativeAskLocalSink.mainDartBridge] → this handler →
///   the live registry). The reply map is bridged back VERBATIM to the
///   card, so its shape must match the card channel's decoder:
///   `{success, output, error?}` (task-4 channel contract; the card's
///   `executeTool` parses exactly those keys).
/// - `askLocalRequestArrived` — Kotlin pushes a PROCESS_TEXT staging
///   payload; this engine resolves the full bootstrap envelope and hands
///   it to the overlay host via `openOverlayNow`. The reply CLEARS
///   Kotlin's stash only on success (truthy ack) — a failed open replies
///   null so the ask stays stashed for the next `consumePendingAskLocal`
///   pull, exactly like the task-2 no-handler path.
/// - `consumePendingAskLocal` — the same pull, for requests that landed
///   before this handler was attached (process restarts, slow boots).
///
/// OUT OF REACH: the card engine has NO plugins and never touches this
/// file (its own wire lives in ask_local_card_channel.dart). This module
/// imports NO approval machinery — the CARD already gates every call with
/// its auto-approve/chip flow before the forward; executing plainly here
/// is the documented, deliberate parity with the fork panel's approved
/// calls.
typedef AskLocalToolExecutor = Future<({bool success, String output, String? error})>
    Function(String toolName, Map<String, dynamic> arguments);

/// App-level bridge for the card's execute forward: reads the LIVE
/// [toolRegistryProvider] at call time (never cached — registry providers
/// change when settings or servers change), runs plain `execute()` and
/// maps BOTH a failure [ToolExecutionResult] and a thrown exception into
/// the wire shape Kotlin bridges verbatim. Registration parity note: the
/// web/terminal/skills local servers stay in step via the always-mounted
/// `WebServerRegistrationHost`, so this closure sees the same registry the
/// main chat sees.
final askLocalToolExecutorProvider = Provider<AskLocalToolExecutor>((ref) {
  return (toolName, arguments) async {
    try {
      final registry = ref.watch(toolRegistryProvider);
      final result = await registry.execute(toolName, arguments);
      if (result.success) {
        return (success: true, output: result.output, error: null);
      }
      return (success: false, output: '', error: result.error ?? 'tool failed');
    } catch (error) {
      Log.error('Ask Local execute $toolName failed: $error');
      return (success: false, output: '', error: error.toString());
    }
  };
});

/// Snapshot resolution for the open path: the live state the main engine
/// freezes into the card's bootstrap envelope at hand-off time. Best-effort
/// by contract — a failure in any single section degrades THAT section
/// (empty toolset, no conversationId); a target that cannot resolve at all
/// (no server / no model) yields null so the card still OPENS but in its
/// degraded typed-failure mode.
Future<AskLocalCardBootstrapPayload?>
resolveAskLocalCardBootstrap(ProviderContainer container) async {
  final target = container.read(activeChatTargetProvider);
  final server = target.server;
  final modelId = target.effectiveModelId;
  if (server == null || modelId == null || modelId.isEmpty) return null;

  final Directory docsDir;
  try {
    docsDir = await container.read(storageDirectoryProvider.future);
  } catch (error) {
    Log.error('Ask Local bootstrap resolve failed: $error');
    return null;
  }
  final storeDirPath =
      p.join(docsDir.path, objectBoxStoreDirectoryName);

  String settingsJson = '';
  try {
    settingsJson = container.read(settingsProvider).toJson();
  } catch (error) {
    Log.error('Ask Local settings snapshot failed: $error');
  }

  ChatParameters params;
  try {
    params = container.read(chatParamsProvider);
  } catch (error) {
    Log.error('Ask Local params snapshot failed: $error');
    params = ChatParameters.defaults();
  }

  List<AskLocalCardToolDefWire> toolDefs = const <AskLocalCardToolDefWire>[];
  try {
    final defs = await container.read(forkChatToolsetProvider.future);
    toolDefs = [
      for (final def in defs)
        AskLocalCardToolDefWire(
          name: def.name,
          description: def.description,
          inputSchema: def.inputSchema,
          providerType: def.providerType.name,
          providerRef: def.providerRef,
        ),
    ];
  } catch (error) {
    Log.error('Ask Local toolset snapshot failed: $error');
  }

  String? conversationId;
  try {
    // "New chat per popup": every handoff creates its OWN conversation;
    // history keeps the previous asks as separate threads. The envelope
    // pins the fresh id so the card never re-ensures a stale shared row.
    final conversation = await container
        .read(askLocalConversationServiceProvider)
        .create();
    conversationId = conversation.id;
    // The conversation was written straight to ObjectBox, bypassing the
    // conversations notifier, so the history list's cached state would not see it
    // until a later reload. Invalidate so the new Ask Local thread appears now.
    container.invalidate(conversationsProvider);
  } catch (error) {
    Log.error('Ask Local conversation create failed: $error');
  }

  return AskLocalCardBootstrapPayload(
    requestId: generateUuidV4(),
    storeDir: storeDirPath,
    conversationId: conversationId,
    server: _wireFromServer(server),
    modelId: modelId,
    params: params,
    toolDefs: toolDefs,
    settingsJson: settingsJson,
    attachmentsDirPath: p.join(docsDir.path, 'attachments'),
    appDirPath: docsDir.path,
    schemaVersion: AskLocalCardBootstrapPayload.currentSchemaVersion,
  );
}

AskLocalCardServerWire _wireFromServer(Server server) =>
    AskLocalCardServerWire(
      id: server.id,
      name: server.name,
      type: server.type.name,
      host: server.host,
      port: server.port,
      apiKey: server.apiKey,
      pathPrefix: server.pathPrefix,
    );

/// The open-path coordinator: pending staging payload (selection +
/// capture) in, envelope resolved, overlay host shown out.
class AskLocalMainChannel {
  AskLocalMainChannel({required this.openOverlay});

  /// Kotlin-facing show hook, injectable for tests — production always
  /// uses [AskLocalOverlayAccess.openOverlayNow] (the broadcast channel
  /// MainActivity interprets into `NativeAskLocalSink.onOpenOverlay`).
  final Future<bool> Function({
    String? capturePath,
    required String selectedText,
    Map<String, Object?> bootstrap,
  }) openOverlay;

  static const MethodChannel _channel = MethodChannel(
    AskLocalRequestPayload.askLocalChannel,
  );

  /// Live main-engine listener; [install] replaces it wholesale.
  static AskLocalMainChannel? _installed;

  /// Wires the handler for the CURRENT app container and immediately pulls
  /// whatever a previous engine run stashed. Closing over [container]:
  /// re-install after a bootstrap retry replaces the closures wholesale,
  /// and a disposed container only ever surfaces as a typed failure reply.
  static void install(ProviderContainer container) {
    final channel = AskLocalMainChannel(
      openOverlay: ({capturePath, required selectedText, bootstrap = const {}}) =>
          const AskLocalOverlayAccess().openOverlayNow(
        capturePath: capturePath,
        selectedText: selectedText,
        bootstrap: bootstrap,
      ),
    );
    _installed = channel;
    _channel.setMethodCallHandler(
      (call) => channel.handle(call, container),
    );
    unawaited(channel.consumePendingFromKotlin(container));
  }

  /// Whether a handler is attached (test visibility only).
  static bool get isInstalled => _installed != null;

  /// Removes the handler (bootstrap-host dispose / test teardown); a no-op
  /// when nothing is attached.
  static void uninstall() {
    if (_installed == null) return;
    _channel.setMethodCallHandler(null);
    _installed = null;
  }

  /// The dispatcher tests drive directly; [container] is the app
  /// ProviderContainer the executor + resolver read through.
  Future<Object?> handle(
    MethodCall call,
    ProviderContainer container,
  ) async {
    switch (call.method) {
      case AskLocalRequestPayload.askLocalRequestArrivedMethod:
        // ignore: avoid_print
        print('DBG askLocalRequestArrived: args=${call.arguments}');
        final payload = AskLocalRequestPayload.fromMap(call.arguments);
        // ignore: avoid_print
        print('DBG askLocalRequestArrived: decoded=${payload != null}');
        if (payload == null) return true;
        final opened = await _openWithEnvelope(payload, container);
        // ignore: avoid_print
        print('DBG askLocalRequestArrived: opened=$opened');
        // Truthy ack clears Kotlin's stash; null keeps it for the pull.
        return opened ? true : null;
      case AskLocalCardBootstrapKeys.executeToolMainMethod:
        return executeTool(call, container);
      default:
        return null;
    }
  }

  /// Card tool executions run plain against the live registry. SAFE-BY-
  /// CHANNEL-CONTRACT: the ONLY sender is the card's approved path
  /// (auto-approved by the frozen settings, or settled via an in-card
  /// chip) — MainActivity forwards the card host verbatim and no other
  /// surface invokes this method. NEVER throws: a registry exception (or a
  /// disposed container surfacing through `container.read`) degrades to
  /// the ok:false failure shape Kotlin bridges verbatim — matching the
  /// card channel's decoder exactly, so the card renders a typed error row.
  Future<Object?> executeTool(
    MethodCall call,
    ProviderContainer container,
  ) async {
    const malformed = <String, Object?>{
      'success': false,
      'output': '',
      'error': 'malformed askLocalExecuteTool call',
    };
    try {
      final args = call.arguments;
      final toolName = args is Map ? args['toolName'] : null;
      final arguments = args is Map && args['arguments'] is Map
          ? Map<String, dynamic>.from(args['arguments']! as Map)
          : const <String, dynamic>{};
      if (toolName is! String || toolName.isEmpty) return malformed;
      final executor = container.read(askLocalToolExecutorProvider);
      final outcome = await executor(toolName, arguments);
      return <String, Object?>{
        'success': outcome.success,
        'output': outcome.output,
        'error': outcome.error,
      };
    } catch (error) {
      Log.error('Ask Local execute-handler crashed: $error');
      return <String, Object?>{
        'success': false,
        'output': '',
        'error': error.toString(),
      };
    }
  }

  /// `consumePendingAskLocal` pull to Kotlin: recovers a request that
  /// arrived before the handler attached; same resolution path as the
  /// push. Bounded by the house 3s timeout, failures are log-only.
  Future<void> consumePendingFromKotlin(ProviderContainer container) async {
    try {
      final reply = await _channel
          .invokeMethod<Object?>(AskLocalRequestPayload.consumePendingMethod)
          .timeout(const Duration(seconds: 3));
      if (reply is! Map) return;
      if (reply['pending'] != true) return;
      final payload = AskLocalRequestPayload.fromMap(reply['payload']);
      if (payload == null) return;
      await _openWithEnvelope(payload, container);
    } catch (error) {
      // Host tests / unsupported platforms have no Kotlin host — degrade.
      Log.error('Ask Local consume-pending pull failed: $error');
    }
  }

  /// Resolves the envelope (target absent ⇒ plain degraded open) and shows
  /// the card. Never throws: a resolution throw degrades to an envelope-less
  /// open so the user-visible card is never lost to a provider hiccup.
  Future<bool> _openWithEnvelope(
    AskLocalRequestPayload payload,
    ProviderContainer container,
  ) async {
    AskLocalCardBootstrapPayload? bootstrap;
    try {
      bootstrap = await resolveAskLocalCardBootstrap(container);
    } catch (error) {
      Log.error('Ask Local envelope resolve crashed: $error');
      bootstrap = null;
    }
    final opened = await openOverlay(
      capturePath: payload.capturePath,
      selectedText: payload.selectedText,
      bootstrap:
          bootstrap == null ? const <String, Object?>{} : bootstrapToWire(bootstrap),
    );
    if (opened) _batchScreenMemories(container);
    return opened;
  }

  /// The overlay being shown is a batch trigger: queued samples are drained so
  /// an inferred memory is ready for the next ask. Best-effort — a provider
  /// hiccup must never block the overlay itself.
  void _batchScreenMemories(ProviderContainer container) {
    try {
      if (!container.read(settingsProvider).screenMemoryEnabled) return;
      unawaited(
        container
            .read(screenMemorySchedulerProvider)
            .batchNow()
            .catchError((Object error, StackTrace stack) {
              Log.warning('Screen memory batch on overlay open failed: $error');
            }),
      );
    } catch (error) {
      Log.warning('Screen memory batch on overlay open failed: $error');
    }
  }
}
