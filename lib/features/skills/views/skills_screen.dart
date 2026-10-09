import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:localmind/l10n/app_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../../core/routes/app_routes.dart';
import '../../../core/utils/system_insets.dart';
import '../data/skills_provider.dart';
import '../data/skills_store.dart';

/// The skills management surface: master switch, one row per skill with
/// edit/delete, and an add FAB into the editor. Visuals follow the MCP
/// tools screen (header bar, rounded panels, hairline lists).
class SkillsScreen extends ConsumerWidget {
  const SkillsScreen({super.key});

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    SkillEntry entry,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    await showShadDialog<void>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: Text(l10n.skills_delete_confirm(entry.name)),
        description: Text(l10n.cannot_undo),
        actions: [
          ShadButton.outline(
            child: Text(l10n.cancel),
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
          ShadButton.destructive(
            child: Text(l10n.skills_delete),
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await SkillsStore(
                ref.read(skillsFileHostProvider),
              ).delete(entry.name);
              await ref.read(skillsProvider.notifier).refresh();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final skills = ref.watch(skillsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final topPadding = MediaQuery.of(context).padding.top;
    final bottomInset = bottomSystemInset(context);
    final entries = skills.entries;

    return Stack(
      children: [
        Column(
          children: [
            Container(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: topPadding + 8,
                bottom: 16,
              ),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF0A0A0A)
                    : const Color(0xFFFAFAFA),
                border: Border(
                  bottom: BorderSide(
                    color: isDark
                        ? const Color(0xFF2A2A2A)
                        : const Color(0xFFE5E5E5),
                  ),
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const HugeIcon(
                      icon: HugeIcons.strokeRoundedArrowLeft01,
                    ),
                    onPressed: () => context.canPop()
                        ? context.pop()
                        : context.go(AppRoutes.settings),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.skills_name,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final contentMaxWidth = constraints.maxWidth >= 1080
                      ? 720.0
                      : constraints.maxWidth;
                  final horizontalPadding = constraints.maxWidth >= 720
                      ? 20.0
                      : 12.0;

                  return ListView(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      12,
                      horizontalPadding,
                      96 + bottomInset,
                    ),
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: contentMaxWidth,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _SkillsToggleRow(enabled: skills.enabled),
                              const SizedBox(height: 16),
                              if (entries.isEmpty)
                                _SkillsEmptyState()
                              else
                                for (var i = 0; i < entries.length; i++) ...[
                                  if (i > 0) const SizedBox(height: 8),
                                  _SkillRow(
                                    key: Key('skill_row_${entries[i].name}'),
                                    entry: entries[i],
                                    onEdit: () => context.push(
                                      AppRoutes.skillEditor,
                                      extra: entries[i],
                                    ),
                                    onDelete: () async => _confirmDelete(
                                      context,
                                      ref,
                                      entries[i],
                                    ),
                                  ),
                                ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
        PositionedDirectional(
          bottom: 24,
          end: 24,
          child: FloatingActionButton(
            key: const Key('skills_add_fab'),
            tooltip: l10n.skills_add,
            onPressed: () => context.push(AppRoutes.skillEditor),
            child: const HugeIcon(icon: HugeIcons.strokeRoundedAdd01),
          ),
        ),
      ],
    );
  }
}

/// The master kill switch for skill injection, as the leading list row.
class _SkillsToggleRow extends ConsumerWidget {
  const _SkillsToggleRow({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return _SkillsPanel(
      child: Row(
        children: [
          HugeIcon(
            icon: HugeIcons.strokeRoundedSparkles,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n.skills_toggle,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          ShadSwitch(
            key: const Key('skills_toggle'),
            value: enabled,
            onChanged: (value) =>
                ref.read(skillsProvider.notifier).setEnabled(value),
          ),
        ],
      ),
    );
  }
}

class _SkillRow extends StatelessWidget {
  const _SkillRow({
    super.key,
    required this.entry,
    required this.onEdit,
    required this.onDelete,
  });

  final SkillEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _SkillsPanel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.name,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (entry.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    entry.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ShadIconButton.ghost(
            key: Key('skill_edit_${entry.name}'),
            icon: const HugeIcon(
              icon: HugeIcons.strokeRoundedPencilEdit01,
              size: 18,
            ),
            onPressed: onEdit,
          ),
          const SizedBox(width: 4),
          ShadIconButton.ghost(
            key: Key('skill_delete_${entry.name}'),
            icon: const HugeIcon(
              icon: HugeIcons.strokeRoundedDelete02,
              size: 18,
              color: Colors.red,
            ),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _SkillsEmptyState extends StatelessWidget {
  const _SkillsEmptyState();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return _SkillsPanel(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            HugeIcon(
              icon: HugeIcons.strokeRoundedSparkles,
              size: 28,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.skills_empty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

Color _surfaceColor(BuildContext context) =>
    ShadTheme.of(context).colorScheme.card;

Color _outlineColor(BuildContext context, {double alpha = 0.6}) =>
    ShadTheme.of(context).colorScheme.border.withValues(alpha: alpha);

class _SkillsPanel extends StatelessWidget {
  const _SkillsPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _surfaceColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _outlineColor(context)),
      ),
      child: child,
    );
  }
}
