import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:localmind/core/routes/app_routes.dart';
import 'package:localmind/core/theme/colors.dart';
import 'package:localmind/features/memories/data/models/memory.dart';
import 'package:localmind/features/memories/providers/memory_providers.dart';
import 'package:localmind/l10n/app_localizations.dart';

import 'components/memory_graph_view.dart';

class MemoriesScreen extends ConsumerStatefulWidget {
  const MemoriesScreen({super.key});

  @override
  ConsumerState<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends ConsumerState<MemoriesScreen> {
  final _search = TextEditingController();
  bool _graph = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    // Repair rows duplicated by the old import path before the first list read.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        ref.read(memoryStoreProvider).dedupeById();
      } catch (_) {}
      ref.invalidate(memoriesProvider);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Memory> get _all => ref.watch(memoriesProvider).value ?? const [];

  List<Memory> get _filtered {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _all;
    return _all
        .where(
          (memory) => '${memory.title} ${memory.content}'
              .toLowerCase()
              .contains(query),
        )
        .toList();
  }

  Future<void> _add() async {
    final draft = await showDialog<_MemoryDraft>(
      context: context,
      builder: (_) => const _MemoryEditorDialog(),
    );
    if (draft == null) return;
    await ref.read(memoriesNotifierProvider.notifier).remember(
          title: draft.title,
          content: draft.content,
          kind: draft.kind,
          importance: draft.importance,
        );
  }

  Future<void> _open(Memory memory) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => _MemorySheet(memory: memory),
    );
    if (!mounted || action == null) return;
    final notifier = ref.read(memoriesNotifierProvider.notifier);
    switch (action) {
      case 'delete':
        await notifier.forget(memory.id);
      case 'archive':
        await notifier.archive(memory.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => context.canPop()
              ? context.pop()
              : context.go(AppRoutes.settings),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(l10n.memories_title),
        actions: [
          IconButton(
            key: const ValueKey('memories_view_toggle'),
            tooltip: _graph ? l10n.memory_list_view : l10n.memory_graph_view,
            onPressed: () => setState(() => _graph = !_graph),
            icon: HugeIcon(
              icon: _graph
                  ? HugeIcons.strokeRoundedListView
                  : HugeIcons.strokeRoundedShare08,
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('memory_add'),
        onPressed: _add,
        icon: const HugeIcon(icon: HugeIcons.strokeRoundedPlusSign),
        label: Text(l10n.memory_add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                prefixIcon: const HugeIcon(
                  icon: HugeIcons.strokeRoundedSearch01,
                ),
                hintText: l10n.memory_search_hint,
              ),
            ),
          ),
          Expanded(
            child: _body(theme, isDark),
          ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme, bool isDark) {
    final async = ref.watch(memoriesProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Could not load memories: $error',
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      ),
      data: (_) {
        final rows = _filtered;
        if (rows.isEmpty) {
          return Center(
            child: Text(
              'No memories yet.',
              style: TextStyle(
                color: isDark
                    ? AppColors.darkMutedText
                    : AppColors.lightMutedText,
              ),
            ),
          );
        }
        return _graph
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: MemoryGraphView(
                      memories: rows,
                      relations:
                          ref.watch(memoryRelationsProvider).value ??
                              const [],
                      isDark: isDark,
                      onTap: _open,
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final memory = rows[index];
                      return ListTile(
                        key: ValueKey('memory_row_${memory.id}'),
                        title: Text(memory.title),
                        subtitle: Text(
                          '[${memory.kind.name}] ${memory.content}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          '${memory.importance}',
                          style: theme.textTheme.bodySmall,
                        ),
                        onTap: () => _open(memory),
                      );
                    },
                  );
      },
    );
  }
}

class _MemoryDraft {
  const _MemoryDraft({
    required this.title,
    required this.content,
    required this.kind,
    required this.importance,
  });

  final String title;
  final String content;
  final MemoryKind kind;
  final int importance;
}

class _MemoryEditorDialog extends StatefulWidget {
  const _MemoryEditorDialog();

  @override
  State<_MemoryEditorDialog> createState() => _MemoryEditorDialogState();
}

class _MemoryEditorDialogState extends State<_MemoryEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _content = TextEditingController();
  MemoryKind _kind = MemoryKind.fact;
  double _importance = 50;

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  void _save() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.pop(
      context,
      _MemoryDraft(
        title: _title.text.trim(),
        content: _content.text.trim(),
        kind: _kind,
        importance: _importance.round(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.memory_add),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const ValueKey('memory_title_field'),
              controller: _title,
              autofocus: true,
              decoration: InputDecoration(labelText: l10n.memory_title_label),
              validator: (value) =>
                  (value?.trim().isEmpty ?? true) ? l10n.memory_required : null,
            ),
            const SizedBox(height: 8),
            TextFormField(
              key: const ValueKey('memory_content_field'),
              controller: _content,
              maxLines: 3,
              decoration: InputDecoration(labelText: l10n.memory_content_label),
              validator: (value) =>
                  (value?.trim().isEmpty ?? true) ? l10n.memory_required : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<MemoryKind>(
              initialValue: _kind,
              decoration: InputDecoration(labelText: l10n.memory_kind),
              items: [
                for (final kind in MemoryKind.values)
                  DropdownMenuItem(
                    value: kind,
                    child: Text(_kindLabel(l10n, kind)),
                  ),
              ],
              onChanged: (value) => setState(
                () => _kind = value ?? MemoryKind.fact,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(l10n.memory_importance),
                Expanded(
                  child: Slider(
                    value: _importance,
                    min: 0,
                    max: 100,
                    divisions: 10,
                    label: '${_importance.round()}',
                    onChanged: (value) => setState(() => _importance = value),
                  ),
                ),
              ],
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
          key: const ValueKey('memory_save'),
          onPressed: _save,
          child: Text(l10n.memory_save),
        ),
      ],
    );
  }
}

String _kindLabel(AppLocalizations l10n, MemoryKind kind) => switch (kind) {
  MemoryKind.fact => l10n.memory_kind_fact,
  MemoryKind.preference => l10n.memory_kind_preference,
  MemoryKind.entity => l10n.memory_kind_entity,
  MemoryKind.event => l10n.memory_kind_event,
  MemoryKind.inferred => l10n.memory_kind_inferred,
};

class _MemorySheet extends StatelessWidget {
  const _MemorySheet({required this.memory});

  final Memory memory;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(memory.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('[${memory.kind.name}] ${memory.content}'),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('memory_archive'),
                  onPressed: () => Navigator.pop(context, 'archive'),
                  child: Text(l10n.memory_archive),
                ),
                TextButton(
                  key: const ValueKey('memory_delete'),
                  onPressed: () => Navigator.pop(context, 'delete'),
                  child: Text(
                    l10n.memory_delete,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
