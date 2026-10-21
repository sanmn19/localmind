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
  MemoryKind? _kindFilter;
  final Set<String> _tagFilter = {};

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

  /// The most-used live tags, capped so the filter row stays scannable.
  List<String> get _tagOptions {
    final counts = <String, int>{};
    for (final memory in _all) {
      for (final tag in memory.tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final tags = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    final visible = tags.take(12).toList();
    // Keep an active tag reachable even when it fell out of the top twelve.
    for (final tag in _tagFilter) {
      if (!visible.contains(tag)) visible.add(tag);
    }
    return visible;
  }

  List<Memory> get _filtered {
    final query = _query.trim().toLowerCase();
    return _all.where((memory) {
      if (_kindFilter != null && memory.kind != _kindFilter) return false;
      if (_tagFilter.isNotEmpty && !memory.tags.any(_tagFilter.contains)) {
        return false;
      }
      if (query.isEmpty) return true;
      final haystack = [
        memory.title,
        memory.content,
        memory.shortSummary,
        ...memory.tags,
      ].join(' ').toLowerCase();
      return haystack.contains(query);
    }).toList();
  }

  void _selectKind(MemoryKind? kind) => setState(() => _kindFilter = kind);

  void _toggleTag(String tag) => setState(() {
    if (!_tagFilter.remove(tag)) _tagFilter.add(tag);
  });

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
          tags: draft.tags,
          shortSummary: draft.shortSummary,
          expiresAt: draft.expiresAt,
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
          _MemoryFilters(
            kindFilter: _kindFilter,
            tags: _tagOptions,
            tagFilter: _tagFilter,
            onKindSelected: _selectKind,
            onTagToggled: _toggleTag,
          ),
          Expanded(child: _body(theme, isDark)),
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
                      return _MemoryRow(
                        memory: memory,
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
    required this.tags,
    required this.shortSummary,
    this.expiresAt,
  });

  final String title;
  final String content;
  final MemoryKind kind;
  final int importance;
  final List<String> tags;
  final String shortSummary;
  final DateTime? expiresAt;
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
  final _tags = TextEditingController();
  final _summary = TextEditingController();
  MemoryKind _kind = MemoryKind.fact;
  double _importance = 50;
  DateTime? _expiresAt;

  /// The manual editor offers the four manual kinds only; inferred rows come from
  /// the screen extractor.
  static final _manualKinds = MemoryKind.values
      .where((kind) => kind != MemoryKind.inferred)
      .toList();

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _tags.dispose();
    _summary.dispose();
    super.dispose();
  }

  static List<String> _parseTags(String value) => value
      .split(',')
      .map((tag) => tag.trim())
      .where((tag) => tag.isNotEmpty)
      .toList();

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiresAt ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: DateTime(now.year + 10),
    );
    if (picked == null || !mounted) return;
    // The picker chooses a day; the memory stays live until that day ends.
    setState(
      () => _expiresAt = DateTime(
        picked.year,
        picked.month,
        picked.day,
        23,
        59,
        59,
      ),
    );
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
        tags: _parseTags(_tags.text),
        shortSummary: _summary.text.trim(),
        expiresAt: _expiresAt,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final expiresAt = _expiresAt;
    return AlertDialog(
      title: Text(l10n.memory_add),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const ValueKey('memory_title_field'),
                controller: _title,
                autofocus: true,
                decoration: InputDecoration(labelText: l10n.memory_title_label),
                validator: (value) => (value?.trim().isEmpty ?? true)
                    ? l10n.memory_required
                    : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const ValueKey('memory_content_field'),
                controller: _content,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: l10n.memory_content_label,
                ),
                validator: (value) => (value?.trim().isEmpty ?? true)
                    ? l10n.memory_required
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<MemoryKind>(
                initialValue: _kind,
                decoration: InputDecoration(labelText: l10n.memory_kind),
                items: [
                  for (final kind in _manualKinds)
                    DropdownMenuItem(
                      value: kind,
                      child: Text(_kindLabel(l10n, kind)),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => _kind = value ?? MemoryKind.fact),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const ValueKey('memory_tags_field'),
                controller: _tags,
                decoration: InputDecoration(labelText: l10n.memory_tags_hint),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const ValueKey('memory_summary_field'),
                controller: _summary,
                decoration: InputDecoration(labelText: l10n.memory_summary),
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
              InkWell(
                key: const ValueKey('memory_expiry_field'),
                onTap: _pickExpiry,
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: l10n.memory_expiry,
                    suffixIcon: expiresAt == null
                        ? const HugeIcon(
                            icon: HugeIcons.strokeRoundedCalendar03,
                          )
                        : IconButton(
                            key: const ValueKey('memory_expiry_clear'),
                            tooltip: l10n.memory_clear,
                            onPressed: () => setState(() => _expiresAt = null),
                            icon: const HugeIcon(
                              icon: HugeIcons.strokeRoundedCancel01,
                            ),
                          ),
                  ),
                  child: Text(
                    expiresAt == null
                        ? l10n.memory_no_expiry
                        : MaterialLocalizations.of(
                            context,
                          ).formatMediumDate(expiresAt),
                  ),
                ),
              ),
            ],
          ),
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

/// "Expired", or "Expires in N days" rounded up so a memory with a few hours
/// left still reads as one day.
String _expiryLabel(AppLocalizations l10n, DateTime expiresAt) {
  final remaining = expiresAt.difference(DateTime.now());
  if (remaining.isNegative || remaining == Duration.zero) {
    return l10n.memory_expired;
  }
  final days = (remaining.inSeconds / Duration.secondsPerDay).ceil();
  return l10n.memory_expires_in_days(days < 1 ? 1 : days);
}

/// Kind and tag filters. The tag row lists the most-used live tags only.
class _MemoryFilters extends StatelessWidget {
  const _MemoryFilters({
    required this.kindFilter,
    required this.tags,
    required this.tagFilter,
    required this.onKindSelected,
    required this.onTagToggled,
  });

  final MemoryKind? kindFilter;
  final List<String> tags;
  final Set<String> tagFilter;
  final ValueChanged<MemoryKind?> onKindSelected;
  final ValueChanged<String> onTagToggled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _chip(
                key: const ValueKey('memory_kind_filter_all'),
                label: l10n.memory_filter_all,
                selected: kindFilter == null,
                onSelected: () => onKindSelected(null),
              ),
              for (final kind in MemoryKind.values)
                _chip(
                  key: ValueKey('memory_kind_filter_${kind.name}'),
                  label: _kindLabel(l10n, kind),
                  selected: kindFilter == kind,
                  onSelected: () => onKindSelected(kind),
                ),
            ],
          ),
        ),
        if (tags.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                for (final tag in tags)
                  _chip(
                    key: ValueKey('memory_tag_filter_$tag'),
                    label: '#$tag',
                    selected: tagFilter.contains(tag),
                    onSelected: () => onTagToggled(tag),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _chip({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        key: key,
        label: Text(label),
        selected: selected,
        onSelected: (_) => onSelected(),
      ),
    );
  }
}

class _MemoryRow extends StatelessWidget {
  const _MemoryRow({required this.memory, required this.onTap});

  final Memory memory;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // Inferred rows are long extracts; their one-line summary is what the user
    // needs to recognise them.
    final body =
        memory.kind == MemoryKind.inferred && memory.shortSummary.isNotEmpty
        ? memory.shortSummary
        : memory.content;
    final expiresAt = memory.expiresAt;
    return ListTile(
      key: ValueKey('memory_row_${memory.id}'),
      title: Row(
        children: [
          Expanded(child: Text(memory.title)),
          _KindBadge(label: _kindLabel(l10n, memory.kind)),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(body, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (memory.tags.isNotEmpty)
            Text(memory.tags.map((tag) => '#$tag').join(' '), style: muted),
          if (expiresAt != null)
            Text(
              _expiryLabel(l10n, expiresAt),
              key: ValueKey('memory_expiry_${memory.id}'),
              style: muted,
            ),
        ],
      ),
      trailing: Text('${memory.importance}', style: theme.textTheme.bodySmall),
      onTap: onTap,
    );
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _MemorySheet extends StatelessWidget {
  const _MemorySheet({required this.memory});

  final Memory memory;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final body =
        memory.kind == MemoryKind.inferred && memory.shortSummary.isNotEmpty
        ? memory.shortSummary
        : memory.content;
    final expiresAt = memory.expiresAt;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(memory.title, style: theme.textTheme.titleMedium),
                ),
                _KindBadge(label: _kindLabel(l10n, memory.kind)),
              ],
            ),
            const SizedBox(height: 8),
            Text(body),
            if (memory.tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(memory.tags.map((tag) => '#$tag').join(' '), style: muted),
            ],
            if (expiresAt != null) ...[
              const SizedBox(height: 8),
              Text(
                _expiryLabel(l10n, expiresAt),
                key: ValueKey('memory_sheet_expiry_${memory.id}'),
                style: muted,
              ),
            ],
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
