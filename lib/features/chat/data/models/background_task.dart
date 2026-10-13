/// Lifecycle (docs/specs/2026-10-12-background-upgrades-fork-tools-design.md
/// §Feature 1): running→paused (pause), paused→running (resume),
/// running|paused→cancelled (stop); finished/failed stay terminal. `paused`
/// is APPENDED last so persisted enum-index drift logic and existing tests
/// keep their stable positions.
enum BackgroundTaskState { running, finished, cancelled, failed, paused }

class BackgroundTask {
  final String id;
  final String ownerConversationId;
  final String taskConversationId;
  final String prompt;
  final int loopMinutes;
  final int maxRuns;
  final int runCount;
  final BackgroundTaskState state;
  final DateTime? lastRunAt;
  final DateTime createdAt;
  final String? resultMessageId;
  final String? ownerMessageId;

  const BackgroundTask({
    required this.id,
    required this.ownerConversationId,
    required this.taskConversationId,
    required this.prompt,
    required this.loopMinutes,
    required this.maxRuns,
    this.runCount = 0,
    this.state = BackgroundTaskState.running,
    this.lastRunAt,
    required this.createdAt,
    this.resultMessageId,
    this.ownerMessageId,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'ownerConversationId': ownerConversationId,
      'taskConversationId': taskConversationId,
      'prompt': prompt,
      'loopMinutes': loopMinutes,
      'maxRuns': maxRuns,
      'runCount': runCount,
      'state': state.name,
      'lastRunAt': lastRunAt?.millisecondsSinceEpoch,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'resultMessageId': resultMessageId,
      'ownerMessageId': ownerMessageId,
    };
  }

  static BackgroundTask fromMap(Map<String, dynamic> m) {
    return BackgroundTask(
      id: m['id'] as String,
      ownerConversationId: m['ownerConversationId'] as String,
      taskConversationId: m['taskConversationId'] as String,
      prompt: m['prompt'] as String,
      loopMinutes: m['loopMinutes'] as int,
      maxRuns: m['maxRuns'] as int,
      runCount: m['runCount'] as int? ?? 0,
      state: BackgroundTaskState.values.firstWhere(
        (s) => s.name == m['state'],
        // T1 review ruling mirrors the entity mapping: unknown stored state
        // names degrade to failed, never to running (running would wrongly
        // re-arm the engine loop).
        orElse: () => BackgroundTaskState.failed,
      ),
      lastRunAt: m['lastRunAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(m['lastRunAt'] as int),
      createdAt: DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int),
      resultMessageId: m['resultMessageId'] as String?,
      ownerMessageId: m['ownerMessageId'] as String?,
    );
  }
}
