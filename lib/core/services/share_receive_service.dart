import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logger/app_logger.dart';

/// Kinds of content other apps can hand LocalMind through the share sheet.
abstract final class SharePayloadKind {
  /// Plain text shared via `EXTRA_TEXT` (`kind: text`).
  static const text = 'text';

  /// A single file shared via `EXTRA_STREAM` (`kind: file`).
  static const file = 'file';

  /// Multiple files shared via `EXTRA_STREAM` (`kind: files`).
  static const files = 'files';
}

/// Content stashed by the native side after another app shared it into
/// LocalMind. Text arrives verbatim; files are copies the native capture
/// made under the app cache directory — deleting [filePath]/[paths] after
/// the payload lands in a chat is safe (the chat pipeline saves its own
/// copies through AttachmentHelpers).
class SharedPayload {
  const SharedPayload({
    required this.kind,
    this.text,
    this.filePath,
    this.mimeType,
    this.paths = const [],
    this.mimeTypes = const [],
  });

  const SharedPayload.text({required String this.text})
    : filePath = null,
      mimeType = null,
      paths = const [],
      mimeTypes = const [],
      kind = SharePayloadKind.text;

  const SharedPayload.file({required String this.filePath, this.mimeType})
    : text = null,
      paths = const [],
      mimeTypes = const [],
      kind = SharePayloadKind.file;

  const SharedPayload.files({required this.paths, this.mimeTypes = const []})
    : text = null,
      filePath = null,
      mimeType = null,
      kind = SharePayloadKind.files;

  factory SharedPayload.fromMap(Object? arguments) {
    if (arguments is! Map) return const SharedPayload(kind: 'unknown');
    final kind = arguments['kind']?.toString() ?? '';
    switch (kind) {
      case SharePayloadKind.text:
        final text = arguments['text']?.toString() ?? '';
        if (text.isEmpty) return const SharedPayload(kind: 'unknown');
        return SharedPayload(kind: kind, text: text);
      case SharePayloadKind.file:
        final path = arguments['path']?.toString() ?? '';
        if (path.isEmpty) return const SharedPayload(kind: 'unknown');
        return SharedPayload(
          kind: kind,
          filePath: path,
          mimeType: arguments['mimeType']?.toString(),
        );
      case SharePayloadKind.files:
        final paths = _stringList(arguments['paths']);
        if (paths.isEmpty) return const SharedPayload(kind: 'unknown');
        return SharedPayload(
          kind: kind,
          paths: paths,
          mimeTypes: _stringList(arguments['mimeTypes']),
        );
      default:
        return const SharedPayload(kind: 'unknown');
    }
  }

  final String kind;
  final String? text;
  final String? filePath;
  final String? mimeType;
  final List<String> paths;
  final List<String> mimeTypes;

  bool get isKnown =>
      kind == SharePayloadKind.text ||
      kind == SharePayloadKind.file ||
      kind == SharePayloadKind.files;

  /// Temp files this payload references, for post-handoff cleanup.
  List<String> get stashedFilePaths => [
    if (kind == SharePayloadKind.file && filePath != null) filePath!,
    if (kind == SharePayloadKind.files) ...paths,
  ];

  static List<String> _stringList(dynamic raw) => [
    if (raw is List)
      for (final item in raw)
        if (item is String) item,
  ];
}

/// Mirror of [AndroidAssistantService] for the share-target flow: the
/// native MainActivity stashes share-sheet payloads (text or cached file
/// copies) and delivers them either as a cold-start pull at service init or
/// as a live `shareReceived` event once the Dart handler is attached. The
/// native stash survives until Dart acks — a null/no-listener reply keeps
/// the payload pending for the cold-start pull.
class ShareReceiveService {
  ShareReceiveService({MethodChannel? channel, bool? supportedPlatform})
    : _channel = channel ?? const MethodChannel(_channelName),
      _supportedPlatformOverride = supportedPlatform;

  static const _channelName = 'localmind/share_receive';

  final MethodChannel _channel;
  final bool? _supportedPlatformOverride;
  final StreamController<SharedPayload> _payloads =
      StreamController<SharedPayload>.broadcast();

  bool _initialized = false;
  bool _disposed = false;

  bool get isSupportedPlatform =>
      _supportedPlatformOverride ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  Stream<SharedPayload> get payloads => _payloads.stream;

  Future<void> initialize() async {
    if (!isSupportedPlatform || _initialized || _disposed) return;
    _initialized = true;

    _channel.setMethodCallHandler(_handleNativeCall);

    try {
      final data =
          await _channel.invokeMethod<Map<Object?, Object?>>(
            'consumePendingShare',
          ) ??
          const {};
      if (data['pending'] != true || _disposed) return;
      _addPayload(data['payload']);
    } on PlatformException catch (error) {
      Log.error('Share receive initialization failed: $error');
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'shareReceived':
        _addPayload(
          call.arguments is Map ? (call.arguments as Map)['payload'] : null,
        );
        return true;
      default:
        throw MissingPluginException(
          'Unknown share receive call: ${call.method}',
        );
    }
  }

  /// Single emit point for decoded payloads; also the injection seam tests
  /// use to drive the host without a real channel. Unlike the native-call
  /// path, an already-typed payload must not be re-decoded.
  void dispatchPayload(SharedPayload payload) {
    if (_disposed) return;
    _payloads.add(payload);
  }

  /// Returns false for payloads that failed to decode so callers (and the
  /// native ack path) can distinguish "handled" from "dropped".
  bool _addPayload(Object? arguments) {
    if (_disposed) return false;
    final payload = SharedPayload.fromMap(arguments);
    if (!payload.isKnown) {
      Log.warning('Ignoring malformed share payload: $arguments');
      return false;
    }
    _payloads.add(payload);
    return true;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    await _payloads.close();
  }
}

final shareReceiveServiceProvider = Provider<ShareReceiveService>((ref) {
  final service = ShareReceiveService();
  ref.onDispose(service.dispose);
  return service;
});
