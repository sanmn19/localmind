import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/features/models/data/models/model_info.dart';
import 'package:localmind/features/models/data/models/rig_model_entry.dart';
import 'package:localmind/features/models/providers/rig_load_providers.dart';
import 'package:localmind/l10n/app_localizations.dart';

/// Target picker (when several roster entries share the served id) followed by
/// the load confirmation. Returns the chosen target, or null when dismissed.
Future<RigModelEntry?> confirmRigLoad(
  BuildContext context,
  AppLocalizations l10n,
  ModelInfo model,
  List<RigModelEntry> targets, {
  bool streaming = false,
}) async {
  RigModelEntry? target;
  if (targets.length > 1) {
    target = await showDialog<RigModelEntry>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.model_pick_target_title),
        children: [
          for (final entry in targets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, entry),
              child: Text(
                entry.label.isNotEmpty
                    ? '${entry.label} · ${entry.name}'
                    : entry.name,
              ),
            ),
        ],
      ),
    );
  } else {
    target = targets.firstOrNull;
  }
  if (target == null || !context.mounted) return null;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.model_load_confirm_title),
      content: Text(
        streaming
            ? '${l10n.model_load_confirm_body(model.displayName)} '
                '${l10n.model_load_confirm_streaming}'
            : l10n.model_load_confirm_body(model.displayName),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.model_load_action),
        ),
      ],
    ),
  );
  return confirmed == true ? target : null;
}

/// Shows the load progress sheet. Dismissing it never cancels the switch; only
/// its explicit Cancel action does.
void showRigLoadProgress(BuildContext context, WidgetRef ref) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const RigLoadProgressSheet(),
  );
}

class RigLoadProgressSheet extends ConsumerWidget {
  const RigLoadProgressSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    ref.listen(rigLoadProvider, (previous, next) {
      if (previous != null && next == null && context.mounted) {
        Navigator.pop(context);
      }
    });
    final state = ref.watch(rigLoadProvider);
    final theme = Theme.of(context);
    final status = state?.status;
    final logLine = status == null || status.logTail.isEmpty
        ? null
        : status.logTail.last;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.model_load_progress_title,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: (status?.progress ?? 0) / 100),
            const SizedBox(height: 8),
            Text(
              [
                if (status != null) status.phase,
                if (status?.stage != null && status!.stage!.isNotEmpty)
                  status.stage!,
                if (status != null && status.maxAttempts > 0)
                  '${status.attempt}/${status.maxAttempts}',
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
            if (logLine != null) ...[
              const SizedBox(height: 6),
              Text(
                logLine,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
            if (status?.isFailed ?? false) ...[
              const SizedBox(height: 6),
              Text(
                l10n.model_load_failed(status?.error ?? status?.message ?? ''),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.close),
                ),
                if (state != null && status?.isFailed == true) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () =>
                        ref.read(rigLoadProvider.notifier).retry(),
                    child: Text(l10n.model_load_retry),
                  ),
                ],
                if (state != null && status?.isFailed == false) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: Text(l10n.model_load_cancel_confirm),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, false),
                              child: Text(l10n.cancel),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, true),
                              child: Text(l10n.model_load_cancel),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        await ref.read(rigLoadProvider.notifier).cancel();
                      }
                    },
                    child: Text(l10n.model_load_cancel),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
