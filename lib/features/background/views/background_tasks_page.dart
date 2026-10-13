import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/features/background/views/background_task_row_tile.dart';
import 'package:localmind/features/chat/data/models/background_task.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart';
import 'package:localmind/l10n/app_localizations.dart';

/// `/background` — every chat-owned background task, grouped per owner chat
/// in owner-spawn order with pause/resume/stop per row. The optional
/// [focusOwnerId] (`/background?focus=…`) scrolls the owner's section to the
/// fold and pulses a highlight border; a missing owner is a no-op.
class BackgroundTasksPage extends ConsumerStatefulWidget {
  const BackgroundTasksPage({this.focusOwnerId, super.key});

  final String? focusOwnerId;

  @override
  ConsumerState<BackgroundTasksPage> createState() =>
      _BackgroundTasksPageState();
}

class _BackgroundTasksPageState extends ConsumerState<BackgroundTasksPage>
    with SingleTickerProviderStateMixin {
  late final ScrollController _scrollController;
  late final AnimationController _highlightController;
  late final Animation<double> _highlightOpacity;
  final Map<String, GlobalKey> _sectionKeys = {};

  bool _focusAttempted = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _highlightController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _highlightOpacity = _highlightController;
  }

  /// Data lands a frame after the first build, so the focus attempt retries
  /// per frame until its section EXISTS (latched once).
  void _maybeScheduleFocus() {
    if (_focusAttempted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _focusAttempted) return;
      final context = _sectionKeys[widget.focusOwnerId]?.currentContext;
      if (context == null) return;
      _focusAttempted = true;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        alignment: 0.0,
      );
      _highlightController.forward(from: 0.0);
    });
  }

  @override
  void dispose() {
    _highlightController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _maybeScheduleFocus();
    final l10n = AppLocalizations.of(context)!;
    final conversations = ref.watch(conversationsProvider).value ?? const [];
    final ownerIdList = {
      for (final conversation in conversations)
        conversation.id: conversation.title,
    };
    final tasks = ref.watch(backgroundPageTasksProvider);
    final groups = tasks.maybeWhen(
      data: (rows) => _group(rows),
      orElse: () => <String, List<BackgroundTask>>{},
    );

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: Text(l10n.background_tasks_title)),
      body: SafeArea(
        child: groups.isEmpty
            ? Center(
                child: Text(
                  key: const Key('background_empty_state'),
                  l10n.backgroundNoTasksLabel,
                ),
              )
            : SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.only(top: 8, bottom: 600),
                child: Column(
                  children: [
                    for (final entry in groups.entries)
                      AnimatedBuilder(
                        animation: _highlightController,
                        builder: (context, child) {
                          final focused = entry.key == widget.focusOwnerId;
                          final content = child!;
                          if (!focused) {
                            return Container(
                              key: ValueKey(
                                'background_section_${entry.key}',
                              ),
                              margin: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Theme.of(context)
                                      .dividerColor
                                      .withValues(alpha: 0.4),
                                ),
                              ),
                              child: content,
                            );
                          }
                          return Container(
                            key: ValueKey('background_section_${entry.key}'),
                            margin: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            child: Container(
                              key: const Key('background_focus_highlight'),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withValues(
                                        alpha:
                                            0.85 * (1 - _highlightController.value),
                                      ),
                                  width: 2,
                                ),
                              ),
                              child: content,
                            ),
                          );
                        },
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              key: _sectionKeys.putIfAbsent(
                                entry.key,
                                GlobalKey.new,
                              ),
                              ownerIdList[entry.key] ??
                                  l10n.background_deleted_chat,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            ...entry.value.map(
                              (task) => BackgroundTaskRowTile(task: task),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }

  /// Sections after owner-first-appearance (tasks arrive oldest-first).
  static Map<String, List<BackgroundTask>> _group(
    List<BackgroundTask> tasks,
  ) {
    final groups = <String, List<BackgroundTask>>{};
    for (final task in tasks) {
      groups.putIfAbsent(task.ownerConversationId, () => []).add(task);
    }
    return groups;
  }
}
