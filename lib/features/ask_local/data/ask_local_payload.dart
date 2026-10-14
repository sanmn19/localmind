/// Wire contract for the `localmind/ask_local` method channel: argument
/// names and types shared between MainActivity's Kotlin handlers and the
/// Dart side. The card/overlay consumers arrive via `askLocalRequestArrived`
/// pushes; `openOverlayNow` forwards back into the Kotlin overlay host
/// (installed by the overlay task).
class AskLocalRequestPayload {
  const AskLocalRequestPayload({required this.selectedText, this.capturePath});

  /// Channel name MainActivity registers the handlers under.
  static const String askLocalChannel = 'localmind/ask_local';

  /// Kotlin -> Dart push once a PROCESS_TEXT hand-off resolved its capture.
  static const String askLocalRequestArrivedMethod = 'askLocalRequestArrived';

  /// Dart -> Kotlin single-frame capture; resolves with a nullable path.
  static const String captureNowMethod = 'captureNow';

  /// Dart -> Kotlin capture-service availability check.
  static const String isCaptureAvailableMethod = 'isCaptureAvailable';

  /// Dart -> Kotlin overlay-host forward.
  static const String openOverlayNowMethod = 'openOverlayNow';

  /// Dart pull for a request that landed with no engine attached.
  static const String consumePendingMethod = 'consumePendingAskLocal';

  /// Selection handed over by the PROCESS_TEXT host; may be multi-line.
  final String selectedText;

  /// Absolute path of the pre-card screenshot; null when the capture
  /// service was off or failed (card opens without a thumbnail).
  final String? capturePath;

  /// Args map whose keys match the Kotlin hand-off exactly
  /// (`selectedText`, `capturePath`).
  Map<String, Object?> toChannelArgs() => <String, Object?>{
        'selectedText': selectedText,
        'capturePath': capturePath,
      };

  /// Decode of Kotlin's `askLocalRequestArrived` args. Non-map payloads or
  /// maps without a `selectedText` are not ours and decode to null.
  static AskLocalRequestPayload? fromMap(Object? args) {
    if (args is! Map) return null;
    final selectedText = args['selectedText'];
    if (selectedText is! String) return null;
    final capturePath = args['capturePath'];
    return AskLocalRequestPayload(
      selectedText: selectedText,
      capturePath: capturePath is String ? capturePath : null,
    );
  }
}

/// Fan-out for `askLocalRequestArrived` pushes with idempotent registration:
/// re-registering must never double-deliver; last registration wins,
/// mirroring the share/assistant channel callback patterns.
class AskLocalRequestArrivals {
  void Function(AskLocalRequestPayload payload)? _listener;

  /// Registers (or replaces) the single active listener.
  void register(void Function(AskLocalRequestPayload payload) listener) {
    _listener = listener;
  }

  /// Decodes [args] and hands the payload to the active listener exactly
  /// once; unparseable payloads are dropped.
  void deliver(Object? args) {
    final payload = AskLocalRequestPayload.fromMap(args);
    if (payload == null) return;
    _listener?.call(payload);
  }
}
