import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/features/chat/data/models/background_task.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/l10n/app_localizations.dart';

/// One compact inline row in the owner chat: "Background task ·" state chip
/// plus a short prompt excerpt and conditional pause/resume/stop buttons
/// routed through [backgroundTaskActionsProvider] (the same closures as the
/// page rows and the MCP card — Task 4 parity surface).
///
/// The pill stays keyed to the conversation that owns the task and renders
/// NOTHING while the task id is unknown or the row sits in a terminal state
/// (finished/cancelled/failed) — the timeline's result rows carry the
/// history from then on.
class BackgroundTaskPill extends ConsumerStatefulWidget {
  const BackgroundTaskPill({
    required this.taskId,
    required this.owner,
    super.key,
  });

  final String taskId;
  final String owner;

  @override
  ConsumerState<BackgroundTaskPill> createState() =>
      _BackgroundTaskPillState();
}

class _BackgroundTaskPillState extends ConsumerState<BackgroundTaskPill> {
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
    final tasks = ref.watch(backgroundPageTasksProvider).value;
    final task = _match(tasks);
    if (task == null || task.state == BackgroundTaskState.finished ||
        task.state == BackgroundTaskState.cancelled ||
        task.state == BackgroundTaskState.failed) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final actions = ref.read(backgroundTaskActionsProvider);

    return Container(
      key: Key('background_pill_${task.id}'),
      height: 40,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 14, color: theme.colorScheme.outline),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              l10n.background_pill_title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 6),
          _chip(context, task.state, l10n),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _excerpt(task.prompt),
              key: Key('background_pill_text_${task.id}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (task.state == BackgroundTaskState.running)
            _miniButton(
              Key('background_pill_pause_${task.id}'),
              Icons.pause_circle_outline,
              l10n.background_pause_task,
              _pending ? null : () => _run(actions.pause(task.id)),
            ),
          if (task.state == BackgroundTaskState.paused)
            _miniButton(
              Key('background_pill_resume_${task.id}'),
              Icons.play_circle_outline,
              l10n.background_resume_task,
              _pending ? null : () => _run(actions.resume(task.id)),
            ),
          _miniButton(
            Key('background_pill_stop_${task.id}'),
            Icons.stop_circle_outlined,
            l10n.backgroundCancelTooltip,
            _pending ? null : () => _run(actions.stop(task.id)),
          ),
        ],
      ),
    );
  }

  /// The task this pill stands for — matched by id AND the owning
  /// conversation the timeline was rendered for, so a forked copy of the
  /// original chat keeps the pill silent (the id lives in that fork's
  /// history, the live task belongs to the original conversation).
  BackgroundTask? _match(List<BackgroundTask>? tasks) {
    if (tasks == null) return null;
    for (final task in tasks) {
      if (task.id == widget.taskId) {
        return task.ownerConversationId == widget.owner ? task : null;
      }
    }
    return null;
  }

  /// ~(40 - padding) icon buttons: zero padding, compact density, tap-only.
  Widget _miniButton(Key key, IconData icon, String tooltip, VoidCallback? on) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      visualDensity: VisualDensity.compact,
      onPressed: on,
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
      key: Key('background_pill_chip_${widget.taskId}'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 10)),
    );
  }

  /// Flatten whitespace runs to single spaces, clip to 24 chars + '…'.
  static String _excerpt(String prompt) {
    final flattened = prompt.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (flattened.length <= 24) return flattened;
    return '${flattened.substring(0, 24)}…';
  }
}
