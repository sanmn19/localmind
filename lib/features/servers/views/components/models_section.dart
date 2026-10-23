import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/models/data/models/manual_model.dart';
import 'package:localmind/features/models/data/models/model_info.dart';
import 'package:localmind/features/models/providers/manual_model_providers.dart';
import 'package:localmind/features/servers/providers/server_providers.dart';
import 'package:localmind/l10n/app_localizations.dart';

/// Manual models of a provider plus the detected-model count.
///
/// In add-provider mode rows are staged locally ([pendingRows] /
/// [onPendingChanged]) and committed by the screen after Save; in edit mode they
/// commit immediately.
class ModelsSection extends ConsumerStatefulWidget {
  const ModelsSection({
    super.key,
    required this.serverId,
    required this.serverType,
    required this.isEditing,
    this.pendingRows = const [],
    this.onPendingChanged,
  });

  final String serverId;
  final ServerType serverType;
  final bool isEditing;
  final List<ManualModel> pendingRows;
  final ValueChanged<List<ManualModel>>? onPendingChanged;

  @override
  ConsumerState<ModelsSection> createState() => _ModelsSectionState();
}

class _ModelsSectionState extends ConsumerState<ModelsSection> {
  late List<ManualModel> _pending;

  @override
  void initState() {
    super.initState();
    _pending = List<ManualModel>.from(widget.pendingRows);
  }

  List<ManualModel> get _rows => widget.isEditing
      ? ref.watch(manualModelsProvider(widget.serverId)).value ?? const []
      : _pending;

  Future<void> _add() async {
    final existing = _rows.map((row) => row.modelId).toSet();
    final draft = await showDialog<ManualModel>(
      context: context,
      builder: (_) => _AddManualModelDialog(existing: existing),
    );
    if (draft == null) return;
    final row = ManualModel(
      serverId: widget.serverId,
      modelId: draft.modelId,
      displayName: draft.displayName,
      createdAt: DateTime.now(),
    );
    if (widget.isEditing) {
      await ref.read(manualModelsNotifierProvider.notifier).add(row);
    } else {
      setState(() => _pending = [..._pending, row]);
      widget.onPendingChanged?.call(_pending);
    }
  }

  Future<void> _remove(ManualModel row) async {
    if (widget.isEditing) {
      await ref
          .read(manualModelsNotifierProvider.notifier)
          .remove(row.serverId, row.modelId);
    } else {
      setState(
        () =>
            _pending = _pending.where((m) => m.modelId != row.modelId).toList(),
      );
      widget.onPendingChanged?.call(_pending);
    }
  }

  void _refreshDetection() {
    invalidateAvailableModelsCache(widget.serverId);
    ref.invalidate(availableModelsProvider(widget.serverId));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final detected =
        ref.watch(availableModelsProvider(widget.serverId)).value ??
        const <ModelInfo>[];
    final rows = _rows;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.models_detected_count(detected.length),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('models_section_refresh'),
              tooltip: l10n.models_refresh,
              visualDensity: VisualDensity.compact,
              icon: const HugeIcon(icon: HugeIcons.strokeRoundedRefresh),
              onPressed: _refreshDetection,
            ),
            TextButton.icon(
              key: const ValueKey('models_section_add'),
              onPressed: _add,
              icon: const HugeIcon(icon: HugeIcons.strokeRoundedPlusSign),
              label: Text(l10n.model_manual_add),
            ),
          ],
        ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              l10n.model_manual_empty,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          )
        else
          for (final row in rows)
            ListTile(
              key: ValueKey('manual_model_${row.modelId}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                row.displayName ?? row.modelId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: row.displayName == null
                  ? null
                  : Text(
                      row.modelId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
              trailing: IconButton(
                key: ValueKey('remove_manual_model_${row.modelId}'),
                tooltip: l10n.model_manual_remove,
                visualDensity: VisualDensity.compact,
                icon: const HugeIcon(icon: HugeIcons.strokeRoundedDelete02),
                onPressed: () => _remove(row),
              ),
            ),
      ],
    );
  }
}

class _AddManualModelDialog extends StatefulWidget {
  const _AddManualModelDialog({required this.existing});

  final Set<String> existing;

  @override
  State<_AddManualModelDialog> createState() => _AddManualModelDialogState();
}

class _AddManualModelDialogState extends State<_AddManualModelDialog> {
  final _formKey = GlobalKey<FormState>();
  final _idController = TextEditingController();
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _idController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    final id = _idController.text.trim();
    final name = _nameController.text.trim();
    Navigator.pop(
      context,
      ManualModel(
        serverId: '',
        modelId: id,
        displayName: name.isEmpty ? null : name,
        createdAt: DateTime.now(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.model_manual_add),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const ValueKey('manual_model_id_field'),
              controller: _idController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.model_manual_id_label,
              ),
              validator: (value) {
                final id = value?.trim() ?? '';
                if (id.isEmpty) return l10n.model_manual_blank;
                if (widget.existing.contains(id)) {
                  return l10n.model_manual_duplicate;
                }
                return null;
              },
            ),
            const SizedBox(height: 8),
            TextFormField(
              key: const ValueKey('manual_model_name_field'),
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.model_manual_name_label,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey('manual_model_save'),
          onPressed: _submit,
          child: Text(l10n.model_manual_save),
        ),
      ],
    );
  }
}
