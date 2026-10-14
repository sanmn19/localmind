import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';
import 'package:localmind/features/servers/data/models/server.dart';
import 'package:localmind/features/chat/providers/chat_reasoning_providers.dart';

/// Wire shape the card isolate translates between the `bootstrap` payload
/// envelope and its lite runtime (entering + leaving side).
///
/// The main engine resolves the snapshot at hand-off time (live settings,
/// the active chat target and the fork-parity toolset); the payload becomes
/// the card's SOURCE OF TRUTH (a stashed snapshot, as ruled) so the card
/// engine can run with no plugins and no app providers beyond the attached
/// store.
class AskLocalCardBootstrapPayload {
  const AskLocalCardBootstrapPayload({
    required this.requestId,
    required this.storeDir,
    required this.server,
    required this.modelId,
    required this.params,
    required this.toolDefs,
    required this.settingsJson,
    this.conversationId,
    this.attachmentsDirPath,
    this.appDirPath,
    this.schemaVersion = 0,
  });

  /// Dedupe id handed to the card with every delivery; identical across the
  /// re-delivery of the SAME ask (re-show) — tolerated as an idempotent
  /// no-op by the card.
  final String requestId;

  /// Application-store directory path resolved by the main engine — the
  /// card attaches the ObjectBox store there via attachAsSecondaryIsolate.
  final String storeDir;

  /// Conversation id the main engine believed current; INFORMATIONAL. The
  /// card always ensure()-s first-wins in its own attached store (never
  /// writes by stale ids: rows target the ensured row's id).
  final String? conversationId;

  final AskLocalCardServerWire server;
  final String modelId;
  final ChatParameters params;

  /// The fork-parity toolset (structurally minus bg./notifications.).
  final List<AskLocalCardToolDefWire> toolDefs;

  /// FULL AppSettings snapshot (json) that freezes the card's
  /// settingsProvider (the approval gate's toggles at hand-off time).
  final String settingsJson;

  /// Explicit attachments directory the MAIN engine resolved at hand-off
  /// (envelope v2); the card stages captures there. Null (v1 payloads) ⇒
  /// the historical storeDir-parent/attachments inference applies.
  final String? attachmentsDirPath;

  /// App documents directory path (envelope v2, informational for v1) —
  /// places the card in the same app sandbox the main engine resolved its
  /// paths from. Null on v1 payloads.
  final String? appDirPath;

  /// Envelope-schema version the sender shipped. 0 = legacy (v1) payload.
  /// Decode is version-tolerant: unknown/absent fields never break the
  /// card — later versions may add keys freely, this reader ignores them.
  final int schemaVersion;

  /// Highest schema version this build understands; senders stamp it.
  static const int currentSchemaVersion = 1;
}

class AskLocalCardServerWire {
  const AskLocalCardServerWire({
    required this.id,
    required this.name,
    required this.type,
    required this.host,
    required this.port,
    this.apiKey,
    this.pathPrefix,
  });

  final String id;
  final String name;
  final String type;
  final String host;
  final int port;
  final String? apiKey;
  final String? pathPrefix;

  Map<String, Object?> toWire() => <String, Object?>{
        'id': id,
        'name': name,
        'type': type,
        'host': host,
        'port': port,
        'apiKey': apiKey,
        'pathPrefix': pathPrefix,
      };

  static AskLocalCardServerWire? fromWire(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    final host = raw['host'];
    final port = raw['port'];
    if (type is! String || host is! String || port is! num) return null;
    final pathPrefix = raw['pathPrefix'];
    return AskLocalCardServerWire(
      id: raw['id'] is String ? raw['id']! as String : 'wire-server',
      name: raw['name'] is String ? raw['name']! as String : 'server',
      type: type,
      host: host,
      port: port.toInt(),
      apiKey: raw['apiKey'] is String ? raw['apiKey']! as String : null,
      pathPrefix: pathPrefix is String ? pathPrefix : null,
    );
  }

  /// Reconstructs the stream-facing [Server] from the wire snapshot. The
  /// timestamps/status fields are placeholders — only baseUrl/authHeaders
  /// (host/port/pathPrefix/apiKey/type) and identity drive the streaming.
  Server toServer() => Server(
        id: id,
        name: name,
        type: ServerType.values.firstWhere(
          (value) => value.name == type,
          orElse: () => ServerType.openAICompatible,
        ),
        host: host,
        port: port,
        apiKey: apiKey,
        createdAt: DateTime.now(),
        lastConnectedAt: DateTime.now(),
        pathPrefix: pathPrefix,
      );
}

class AskLocalCardToolDefWire {
  const AskLocalCardToolDefWire({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.providerType,
    this.providerRef,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final String providerType;
  final String? providerRef;

  Map<String, Object?> toWire() => <String, Object?>{
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
        'providerType': providerType,
        'providerRef': providerRef,
      };

  static AskLocalCardToolDefWire? fromWire(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String) return null;
    final providerType = raw['providerType'];
    final providerRef = raw['providerRef'];
    final inputSchema = raw['inputSchema'];
    return AskLocalCardToolDefWire(
      name: name,
      description:
          raw['description'] is String ? raw['description']! as String : '',
      inputSchema: inputSchema is Map
          ? Map<String, dynamic>.from(inputSchema)
          : const <String, dynamic>{},
      providerType: providerType is String ? providerType : 'mcp',
      providerRef: providerRef is String ? providerRef : null,
    );
  }

  ToolDefinition toDefinition() => ToolDefinition(
        name: name,
        description: description,
        inputSchema: Map.of(inputSchema),
        providerType: ToolProviderType.values.firstWhere(
          (value) => value.name == providerType,
          orElse: () => ToolProviderType.mcp,
        ),
        providerRef: providerRef,
      );
}

/// Keys of the bootstrap envelope (single source of truth for both engines'
/// field/method names).
class AskLocalCardBootstrapKeys {
  static const String bootstrap = 'bootstrap';
  static const String requestId = 'requestId';
  static const String storeDir = 'storeDir';
  static const String conversationId = 'conversationId';
  static const String server = 'server';
  static const String modelId = 'modelId';
  static const String params = 'params';
  static const String toolDefs = 'toolDefs';
  static const String settings = 'settings';
  static const String schemaVersion = 'schemaVersion';
  static const String attachmentsDirPath = 'attachmentsDirPath';
  static const String appDirPath = 'appDirPath';

  /// Kotlin re-pushes the payload into the live card under this card-channel
  /// method when a new ask lands while the window is already up.
  static const String payloadUpdateCardMethod = 'askLocalPayloadUpdate';

  /// Approval chips execute through here (card channel): the main engine's
  /// registry runs the tool — plain execute(), no approval machinery.
  static const String executeToolCardMethod = 'askLocalExecuteTool';

  /// The MAIN-engine execute method on `localmind/ask_local` (Kotlin's
  /// [NativeAskLocalSink.mainDartBridge] forward target). Same literal as
  /// the card-channel method; distinct channels, never the same call.
  static const String executeToolMainMethod = 'askLocalExecuteTool';
}

/// Decodes the `bootstrap` map. Tolerant: anything malformed yields null so
/// the card runs in its degraded mode (UI up, typed no-target failure on
/// send) instead of crashing on a malformed hand-off.
AskLocalCardBootstrapPayload? bootstrapFromMap(Object? raw) {
  if (raw is! Map) return null;
  final server = AskLocalCardServerWire.fromWire(raw['server']);
  final modelId = raw['modelId'];
  final storeDir = raw['storeDir'];
  final requestId = raw['requestId'];
  if (server == null || modelId is! String || storeDir is! String) return null;
  if (requestId is! String || requestId.isEmpty) return null;
  final toolDefs = raw['toolDefs'] is List
      ? (raw['toolDefs']! as List)
          .map(AskLocalCardToolDefWire.fromWire)
          .whereType<AskLocalCardToolDefWire>()
          .toList()
      : const <AskLocalCardToolDefWire>[];
  final settings = raw['settings'];
  final conversationId = raw['conversationId'];
  return AskLocalCardBootstrapPayload(
    requestId: requestId,
    storeDir: storeDir,
    conversationId: conversationId is String ? conversationId : null,
    server: server,
    modelId: modelId,
    params: chatParametersFromWire(raw['params']),
    toolDefs: toolDefs,
    settingsJson: settings is String ? settings : '',
    attachmentsDirPath:
        raw[AskLocalCardBootstrapKeys.attachmentsDirPath] is String
            ? raw[AskLocalCardBootstrapKeys.attachmentsDirPath]! as String
            : null,
    appDirPath: raw[AskLocalCardBootstrapKeys.appDirPath] is String
        ? raw[AskLocalCardBootstrapKeys.appDirPath]! as String
        : null,
    schemaVersion: raw[AskLocalCardBootstrapKeys.schemaVersion] is num
        ? (raw[AskLocalCardBootstrapKeys.schemaVersion]! as num).toInt()
        : 0,
  );
}

/// Builds the envelope the main engine ships to the card at overlay-open.
/// Version-stamped with [AskLocalCardBootstrapPayload.currentSchemaVersion];
/// the decoder tolerates later versions (+ unknown keys) and earlier ones
/// (the v2-only fields decode to null and fall back to the v1 inferences).
Map<String, Object?> bootstrapToWire(AskLocalCardBootstrapPayload payload) =>
    <String, Object?>{
      'requestId': payload.requestId,
      'storeDir': payload.storeDir,
      'conversationId': payload.conversationId,
      'server': payload.server.toWire(),
      'modelId': payload.modelId,
      'params': chatParametersToWire(payload.params),
      'toolDefs': [
        for (final def in payload.toolDefs) def.toWire(),
      ],
      'settings': payload.settingsJson,
      'schemaVersion': AskLocalCardBootstrapPayload.currentSchemaVersion,
      'attachmentsDirPath': payload.attachmentsDirPath,
      'appDirPath': payload.appDirPath,
    };

/// FULL ChatParameters wire so the card streams with the exact frozen
/// gen parameters the main resolve produced (no silent reduction).
Map<String, Object?> chatParametersToWire(ChatParameters params) =>
    <String, Object?>{
      'temperature': params.temperature,
      'topP': params.topP,
      'maxTokens': params.maxTokens,
      'contextLength': params.contextLength,
      'systemPrompt': params.systemPrompt,
      'topK': params.topK,
      'minP': params.minP,
      'repeatPenalty': params.repeatPenalty,
      'sendTemperature': params.sendTemperature,
      'sendTopP': params.sendTopP,
      'reasoningEnabled': params.reasoningEnabled,
      'reasoningEffort': params.reasoningEffort.name,
      'reasoningAllowedOptions': params.reasoningAllowedOptions,
      'reasoningDefaultOption': params.reasoningDefaultOption,
    };

ChatParameters chatParametersFromWire(Object? raw) {
  if (raw is! Map) return ChatParameters.defaults();
  num? numField(String key) => raw[key] is num ? raw[key]! as num : null;
  bool boolOr(String key, bool fallback) =>
      raw[key] is bool ? raw[key]! as bool : fallback;
  List<String>? stringList(String key) {
    final value = raw[key];
    if (value is! List) return null;
    return [
      for (final entry in value)
        if (entry is String) entry,
    ];
  }

  return ChatParameters(
    temperature: numField('temperature')?.toDouble() ??
        ChatParameters.defaults().temperature,
    topP:
        numField('topP')?.toDouble() ?? ChatParameters.defaults().topP,
    maxTokens: numField('maxTokens')?.toInt() ??
        ChatParameters.defaults().maxTokens,
    contextLength: numField('contextLength')?.toInt() ??
        ChatParameters.defaults().contextLength,
    systemPrompt: raw['systemPrompt'] is String
        ? raw['systemPrompt']! as String
        : null,
    topK: numField('topK')?.toInt(),
    minP: numField('minP')?.toDouble(),
    repeatPenalty: numField('repeatPenalty')?.toDouble(),
    sendTemperature: boolOr('sendTemperature', true),
    sendTopP: boolOr('sendTopP', true),
    reasoningEnabled: raw['reasoningEnabled'] is bool
        ? raw['reasoningEnabled']! as bool
        : null,
    reasoningEffort: ReasoningEffort.values.firstWhere(
      (value) => value.name == raw['reasoningEffort'],
      orElse: () => ReasoningEffort.low,
    ),
    reasoningAllowedOptions: stringList('reasoningAllowedOptions'),
    reasoningDefaultOption: raw['reasoningDefaultOption'] is String
        ? raw['reasoningDefaultOption']! as String
        : null,
  );
}
