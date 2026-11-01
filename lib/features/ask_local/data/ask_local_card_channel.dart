import 'dart:async';

import 'package:flutter/services.dart';

import 'ask_local_card_bootstrap.dart';
import 'ask_local_payload.dart';

/// ONE delivery of a PROCESS_TEXT ask into the card isolate: the base
/// staging payload ({selectedText, capturePath}) plus the optional
/// [AskLocalCardBootstrapPayload] envelope the main engine resolved at
/// hand-off (absent = degraded card: UI up, sends fail typed).
class AskLocalCardDelivery {
  const AskLocalCardDelivery({
    required this.payload,
    required this.deliveryId,
    this.bootstrap,
  });

  final AskLocalRequestPayload payload;
  final AskLocalCardBootstrapPayload? bootstrap;

  /// Dedupe id: the main engine's requestId when present, else the
  /// composite of the staging fields (T2 envelope carries no id).
  final String deliveryId;

  static AskLocalCardDelivery? fromMap(Object? raw) {
    final payload = AskLocalRequestPayload.fromMap(raw);
    if (payload == null) return null;
    final bootstrap =
        raw is Map ? bootstrapFromMap(raw['bootstrap']) : null;
    String deliveryId;
    final requestId = raw is Map ? raw['requestId'] : null;
    final nestedId = bootstrap?.requestId;
    if (requestId is String && requestId.isNotEmpty) {
      deliveryId = requestId;
    } else if (nestedId != null && nestedId.isNotEmpty) {
      deliveryId = nestedId;
    } else {
      deliveryId =
          '${payload.selectedText}\x00${payload.capturePath ?? ''}';
    }
    return AskLocalCardDelivery(
      payload: payload,
      bootstrap: bootstrap,
      deliveryId: deliveryId,
    );
  }
}

/// Card-isolate side of the `localmind/ask_local_card` channel
/// (AskLocalOverlayWindow.CARD_CHANNEL — MainActivity never touches it).
///
/// Stripe layout:
/// - Dart → Kotlin calls: `getInitialPayload` (bounded retries: the window
///   host registers its control handler in the same turn the engine boots
///   on, but an early pull can still race registration),
///   `resizeFloatingCard`, `closeCard`, `captureNow`, `askLocalExecuteTool`.
/// - Kotlin → Dart pushes: `askLocalPayloadUpdate` (fresh ask while shown),
///   `askLocalCardClosed` (window torn down without a card-side close —
///   the card isolate lives on; the entrypoint subscribes EARLY at boot, no
///   replay: state re-anchors from the payload/store on the next open).
class AskLocalCardChannel {
  AskLocalCardChannel();

  static const MethodChannel _channel = MethodChannel(
    'localmind/ask_local_card',
  );

  bool _handlerInstalled = false;

  /// Pulls the window host's LATEST held payload. Bounded retries (the
  /// success contract is the delivery map; null when the host never
  /// delivered — other engines under host tests).
  Future<AskLocalCardDelivery?> requestInitialPayload({
    List<Duration> retryDelays = const [
      Duration(milliseconds: 50),
      Duration(milliseconds: 150),
      Duration(milliseconds: 350),
      Duration(milliseconds: 750),
    ],
  }) async {
    var delivery = await _tryInitialPayload();
    if (delivery != null) return delivery;
    for (final delay in retryDelays) {
      await Future<void>.delayed(delay);
      delivery = await _tryInitialPayload();
      if (delivery != null) return delivery;
    }
    return null;
  }

  Future<AskLocalCardDelivery?> _tryInitialPayload() async {
    try {
      final raw = await _channel
          .invokeMethod<Object?>('getInitialPayload')
          .timeout(_shortTimeout);
      return AskLocalCardDelivery.fromMap(raw);
    } on Exception {
      return null;
    }
  }

  /// Installs the Kotlin→Dart push handler exactly once (idempotent; last
  /// registration wins semantics are irrelevant since only the entrypoint
  /// registers).
  void manage(
    void Function(AskLocalCardDelivery delivery, bool forceReanchor)
    onPayloadUpdate,
    void Function() onCardClosed, {
    void Function(String text)? onExternalInput,
  }) {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case AskLocalCardBootstrapKeys.payloadUpdateCardMethod:
          final force = call.arguments is Map &&
              call.arguments['forceReanchor'] == true;
          // ignore: avoid_print
          print('DBG card channel: payloadUpdate force=$force');
          final delivery = AskLocalCardDelivery.fromMap(call.arguments);
          if (delivery != null) onPayloadUpdate(delivery, force);
          return null;
        case 'askLocalCardClosed':
          onCardClosed();
          return null;
        case 'askLocalCardInput':
          final text = call.arguments is Map
              ? (call.arguments['text'] as String? ?? '')
              : (call.arguments as String? ?? '');
          onExternalInput?.call(text);
          return null;
        default:
          return null;
      }
    });
  }

  /// Drag-to-move deltas from the header's pan gesture: the host applies
  /// them to the window position (dp units; the host converts using the
  /// display density) and clamps the card on-screen.
  Future<bool> dragFloatingCard(double dx, double dy) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'moveFloatingCard',
        {'dx': dx, 'dy': dy},
      );
      return ok ?? false;
    } on Exception {
      return false;
    }
  }

  /// Opens the host's transparent input activity — a real activity window
  /// hosts the IME (an overlay window cannot hold the keyboard without
  /// stealing OS-wide focus). Typed text returns via the `askLocalCardInput`
  /// push handled in [manage].
  Future<bool> openCardInput() async {
    try {
      final ok = await _channel.invokeMethod<bool>('openCardInput');
      return ok ?? false;
    } on Exception {
      return false;
    }
  }

  /// Single-frame re-capture (spec UX #3): resolves null when the capture
  /// service is off or the shot failed — the round keeps its old capture.
  Future<String?> captureNow() async {
    try {
      final path = await _channel
          .invokeMethod<String>('captureNow')
          .timeout(_shortTimeout);
      return path;
    } on Exception {
      return null;
    }
  }

  /// Content-height window resize (the card self-sizes; the host clamps to
  /// the 38%-of-display ceiling).
  Future<bool> resizeFloatingCard(double heightDp) async {
    try {
      final resized = await _channel.invokeMethod<bool>(
        'resizeFloatingCard',
        {'height': heightDp},
      );
      return resized ?? false;
    } on Exception {
      return false;
    }
  }

  /// Closes the card via its own X (does NOT echo the closed event —
  /// the host knows it was requested).
  Future<bool> closeCard() async {
    try {
      final closed = await _channel.invokeMethod<bool>('closeCard');
      return closed ?? false;
    } on Exception {
      return false;
    }
  }

  /// Flips the overlay window between input-gated and keyboard modes.
  /// True when the card's text field gains focus (the IME may attach to
  /// the overlay), false when it loses focus — restoring the foreground
  /// app's keyboard. Best-effort: failure degrades to the input-gated
  /// default (no keyboard, no OS-wide focus theft).
  Future<bool> setWindowFocusable(bool focusable) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'setWindowFocusable',
        {'focusable': focusable},
      );
      return ok ?? false;
    } on Exception {
      return false;
    }
  }

  /// Executes a tool through the main engine's registry
  /// (`askLocalExecuteTool` card-channel forward; the main's execute() runs
  /// plain — no approval machinery involvement, the card already approved).
  ///
  /// Long-running by nature (web fetches, terminal runs): bounded by
  /// [_toolExecuteTimeout] instead of the house 3s channel timeout. Every
  /// failure mode (main Dart unimplemented, timeout, error) degrades to a
  /// failure [ToolExecutionResult]-shaped map, never an escape.
  Future<({bool success, String output, String? error})> executeTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        AskLocalCardBootstrapKeys.executeToolCardMethod,
        {'toolName': toolName, 'arguments': Map<String, dynamic>.of(arguments)},
      ).timeout(_toolExecuteTimeout);
      if (raw is Map) {
        final success = raw['success'];
        final output = raw['output'];
        return (
          success: success is bool ? success : false,
          output: output is String ? output : '',
          error: raw['error'] is String ? raw['error']! as String : null,
        );
      }
      return (success: false, output: '', error: 'malformed tool reply');
    } on TimeoutException {
      return (
        success: false,
        output: '',
        error: 'tool execution timed out on the main engine channel',
      );
    } on Exception catch (error) {
      return (
        success: false,
        output: '',
        error: 'tool unavailable from the card: $error',
      );
    }
  }

  static const _shortTimeout = Duration(seconds: 3);
  static const _toolExecuteTimeout = Duration(seconds: 120);
}
