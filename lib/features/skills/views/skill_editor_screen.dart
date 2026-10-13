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

/// Create or edit one skill. Validates the name live, shows the normalized
/// form as a hint, and reports duplicate-name clashes from the store as an
/// inline error. Saving always refreshes the in-memory mirror so the next
/// chat request picks the change up.
class SkillEditorScreen extends ConsumerStatefulWidget {
  const SkillEditorScreen({super.key, this.existing});

  final SkillEntry? existing;

  @override
  ConsumerState<SkillEditorScreen> createState() => _SkillEditorScreenState();
}

class _SkillEditorScreenState extends ConsumerState<SkillEditorScreen> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _body;

  /// Set when the normalized name fails [SkillsStore.isValidName] or the
  /// store rejects a save as a duplicate; cleared on every save/keystroke.
  String? _nameError;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _description = TextEditingController(text: existing?.description ?? '');
    _body = TextEditingController(text: existing?.body ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _body.dispose();
    super.dispose();
  }

  void _onNameChanged(String value) {
    // Clear the flag live, but do not re-surface it mid-typing.
    setState(() => _nameError = null);
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final normalized = SkillsStore.normalizeName(_name.text);
    if (!SkillsStore.isValidName(normalized)) {
      setState(() => _nameError = l10n.name_invalid_hint);
      return;
    }
    final store = SkillsStore(ref.read(skillsFileHostProvider));
    final entry = SkillEntry(
      name: normalized,
      description: _description.text.trim(),
      body: _body.text,
    );
    try {
      final existing = widget.existing;
      if (existing == null) {
        await store.add(entry);
      } else {
        await store.update(existing.name, entry);
      }
    } on ArgumentError {
      if (mounted) setState(() => _nameError = l10n.duplicate_name_hint);
      return;
    }
    await ref.read(skillsProvider.notifier).refresh();
    if (mounted) context.pop();
  }

  Future<void> _confirmDelete() async {
    final l10n = AppLocalizations.of(context)!;
    final entry = widget.existing!;

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
              if (mounted) context.pop();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final topPadding = MediaQuery.of(context).padding.top;
    final bottomInset = bottomSystemInset(context);

    final normalizedPreview = SkillsStore.normalizeName(_name.text);

    return Column(
      children: [
        Container(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: topPadding + 8,
            bottom: 16,
          ),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0A0A0A) : const Color(0xFFFAFAFA),
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
                icon: const HugeIcon(icon: HugeIcons.strokeRoundedArrowLeft01),
                onPressed: () => context.canPop()
                    ? context.pop()
                    : context.go(AppRoutes.skills),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _isEditing ? l10n.skills_edit_title : l10n.skills_new_title,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                ),
              ),
              ShadButton(
                key: const Key('skill_save'),
                onPressed: _save,
                child: Text(l10n.skills_save),
              ),
              if (_isEditing) ...[
                const SizedBox(width: 8),
                ShadButton.destructive(
                  key: const Key('skill_delete'),
                  onPressed: _confirmDelete,
                  child: Text(l10n.skills_delete),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final contentMaxWidth = constraints.maxWidth >= 720
                  ? 720.0
                  : constraints.maxWidth;
              final horizontalPadding = constraints.maxWidth >= 720
                  ? 20.0
                  : 12.0;

              return ListView(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  16,
                  horizontalPadding,
                  32 + bottomInset,
                ),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: contentMaxWidth),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            l10n.skill_name_label,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          ShadInput(
                            key: const Key('skill_name_field'),
                            controller: _name,
                            autocorrect: false,
                            enableSuggestions: false,
                            onChanged: _onNameChanged,
                            placeholder: Text(l10n.skill_name_label),
                          ),
                          if (_nameError != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              _nameError!,
                              key: const Key('skill_name_error'),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: const Color(0xFFDC2626)),
                            ),
                          ] else if (!_isEditing &&
                              normalizedPreview.isNotEmpty &&
                              normalizedPreview != _name.text.trim()) ...[
                            const SizedBox(height: 6),
                            Text(
                              '@$normalizedPreview',
                              key: const Key('skill_name_preview'),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                    fontFamily: 'monospace',
                                  ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          Text(
                            l10n.skill_description_label,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          ShadInput(
                            key: const Key('skill_description_field'),
                            controller: _description,
                          ),
                          const SizedBox(height: 20),
                          Text(
                            l10n.skill_body_label,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          ShadInput(
                            key: const Key('skill_body_field'),
                            controller: _body,
                            maxLines: 14,
                            minLines: 6,
                            autocorrect: false,
                            enableSuggestions: false,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
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
    );
  }
}
