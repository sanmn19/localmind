/// The model switcher's current state (`GET /v1/status`).
class RigSwitchStatus {
  const RigSwitchStatus({
    required this.phase,
    required this.progress,
    this.target,
    this.stage,
    this.attempt = 0,
    this.maxAttempts = 0,
    this.logTail = const [],
    this.error,
    this.message,
  });

  final String phase;

  /// 0–100.
  final int progress;

  /// The roster `name` being switched to.
  final String? target;

  final String? stage;

  final int attempt;

  final int maxAttempts;

  final List<String> logTail;

  final String? error;

  final String? message;

  bool get isInFlight =>
      phase == 'stopping' || phase == 'starting' || phase == 'loading';

  bool get isHealthy => phase == 'healthy';

  bool get isFailed => phase == 'failed' || phase == 'cancelled';
}
