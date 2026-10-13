import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/features/chat/data/models/background_task.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/l10n/app_localizations.dart';

/// One background-task row: prompt excerpt, run/las-run metadata, state chip,
/// and pause/resume/stop routed through backgroundTaskActionsProvider.
/// Every button disables while the row's own action is pending.
class BackgroundTaskRowTile extends ConsumerStatefulWidget {
  const BackgroundTaskRowTile({required this.task, super.key});

  final BackgroundTask task;

  @override
  ConsumerState<BackgroundTaskRowTile> createState() =>
      _BackgroundTaskRowTileState();
}

class _BackgroundTaskRowTileState extends ConsumerState<BackgroundTaskRowTile> {
  bool _pending = false;

  Future<void> _run(Future<bool> action) async {
    if (_pending) return;
    setState(() => _pending = true);
    try {
      await action;
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final l10n = AppLocalizations.of(context)!;
    final actions = ref.watch(backgroundTaskActionsProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _excerpt(task.prompt),
                  key: Key('background_row_text_${task.id}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      _runsLabel(task, l10n),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const Text(' · '),
                    Text(
                      _lastRunLabel(task.lastRunAt, l10n),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _chip(context, task.state, l10n),
          if (task.state == BackgroundTaskState.running)
            IconButton(
              key: Key('background_pause_${task.id}'),
              tooltip: l10n.background_pause_task,
              icon: const Icon(Icons.pause_circle_outline),
              onPressed: _pending ? null : () => _run(actions.pause(task.id)),
            ),
          if (task.state == BackgroundTaskState.paused)
            IconButton(
              key: Key('background_resume_${task.id}'),
              tooltip: l10n.background_resume_task,
              icon: const Icon(Icons.play_circle_outline),
              onPressed: _pending
                  ? null
                  : () => _run(actions.resume(task.id)),
            ),
          if (task.state == BackgroundTaskState.running ||
              task.state == BackgroundTaskState.paused)
            IconButton(
              key: Key('background_stop_${task.id}'),
              tooltip: l10n.backgroundCancelTooltip,
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed:
                  _pending ? null : () => _run(actions.stop(task.id)),
            ),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    BackgroundTaskState state,
    AppLocalizations l10n,
  ) {
    final label = switch (state) {
      BackgroundTaskState.running => l10n.backgroundStateRunning,
      BackgroundTaskState.paused => l10n.backgroundStatePaused,
      BackgroundTaskState.finished => l10n.backgroundStateFinished,
      BackgroundTaskState.cancelled => l10n.backgroundStateCancelled,
      BackgroundTaskState.failed => l10n.backgroundStateFailed,
    };
    final color = switch (state) {
      BackgroundTaskState.running => Theme.of(context).colorScheme.primary,
      BackgroundTaskState.paused => Colors.orange,
      BackgroundTaskState.finished => Colors.green,
      BackgroundTaskState.cancelled => Theme.of(context).disabledColor,
      BackgroundTaskState.failed => Theme.of(context).colorScheme.error,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 12)),
    );
  }

  String _runsLabel(BackgroundTask task, AppLocalizations l10n) =>
      task.loopMinutes == 0
          ? l10n.background_single_run
          : '${task.runCount}/${task.maxRuns}';

  String _lastRunLabel(DateTime? lastRunAt, AppLocalizations l10n) {
    if (lastRunAt == null) return l10n.background_never_ran;
    final delta = DateTime.now().difference(lastRunAt);
    if (delta < const Duration(minutes: 1)) return l10n.background_last_run_now;
    if (delta < const Duration(hours: 1)) {
      return l10n.background_last_run_minutes(delta.inMinutes);
    }
    if (delta < const Duration(hours: 24)) {
      return l10n.background_last_run_hours(delta.inHours);
    }
    return '${lastRunAt.month}/${lastRunAt.day}';
  }

  /// Flatten whitespace runs to single spaces, clip to 64 chars + '…'.
  static String _excerpt(String prompt) {
    final flattened = prompt.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (flattened.length <= 64) return flattened;
    return '${flattened.substring(0, 64)}…';
  }
}
