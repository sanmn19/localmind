import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hugeicons/hugeicons.dart';

import '../../../../core/components/app_sizes.dart';
import '../../../../core/components/app_text_field.dart';
import '../../data/models/desktop_window.dart';
import '../../providers/desktop_window_providers.dart';
import '../../utils/desktop_routes.dart';

/// One entry the command palette can run.
class DesktopCommand {
  const DesktopCommand({
    required this.id,
    required this.label,
    required this.kind,
    this.route,
  });

  /// The id prefix of a command that focuses an open window.
  static const String windowPrefix = 'window:';

  /// The id prefix of a command that opens a route.
  static const String routePrefix = 'route:';

  /// The id prefix of a command that opens a conversation.
  static const String conversationPrefix = 'conversation:';

  final String id;
  final String label;
  final DesktopWindowKind kind;
  final String? route;
}

/// A searchable list of open windows, every route and recent conversations.
///
/// The palette only builds commands and reports the chosen one; the shell decides
/// whether that means focusing a window or opening a new one.
class DesktopCommandPalette extends ConsumerStatefulWidget {
  const DesktopCommandPalette({
    super.key,
    required this.onSelected,
    this.conversationCommands,
  });

  final ValueChanged<DesktopCommand> onSelected;

  /// Builds the recent-conversation commands.
  ///
  /// Conversation knowledge belongs to the app, so the desktop feature stays
  /// free of a sibling-feature import and only lists what it is given.
  final List<DesktopCommand> Function()? conversationCommands;

  @override
  ConsumerState<DesktopCommandPalette> createState() =>
      _DesktopCommandPaletteState();
}

class _DesktopCommandPaletteState extends ConsumerState<DesktopCommandPalette> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final commands = _filtered(_commands());
    final commandStyle = theme.textTheme.bodyMedium;

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 96),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 440),
          child: Material(
            key: const ValueKey('desktop-command-palette'),
            elevation: 24,
            color: theme.colorScheme.surface,
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.circular(AppSizes.radiusLg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppSizes.md),
                  child: AppTextField(
                    key: const ValueKey('desktop-command-field'),
                    controller: _controller,
                    autofocus: true,
                    hintText: 'Search windows, screens and chats',
                    prefixIcon: const HugeIcon(
                      icon: HugeIcons.strokeRoundedSearch01,
                      size: AppSizes.iconSm,
                    ),
                    onChanged: (value) => setState(() => _query = value),
                    onSubmitted: (_) {
                      if (commands.isNotEmpty) {
                        widget.onSelected(commands.first);
                      }
                    },
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: commands.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(AppSizes.lg),
                          child: Text(
                            'No matches',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: commands.length,
                          itemBuilder: (context, index) {
                            final command = commands[index];
                            return InkWell(
                              key: ValueKey('desktop-command-${command.id}'),
                              onTap: () => widget.onSelected(command),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSizes.lg,
                                  vertical: AppSizes.md,
                                ),
                                child: Text(
                                  command.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: commandStyle,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The commands of the three sources, open windows first.
  List<DesktopCommand> _commands() {
    final layout = ref.watch(desktopWindowControllerProvider);
    final conversationCommands =
        widget.conversationCommands?.call() ?? const <DesktopCommand>[];
    return [
      for (final window in layout.windows)
        DesktopCommand(
          id: '${DesktopCommand.windowPrefix}${window.id}',
          label: window.title,
          kind: window.kind,
          route: window.route,
        ),
      for (final route in desktopRoutes)
        DesktopCommand(
          id: '${DesktopCommand.routePrefix}$route',
          label: desktopTitleForRoute(route),
          kind: desktopWindowKindForRoute(route),
          route: route,
        ),
      ...conversationCommands,
    ];
  }

  List<DesktopCommand> _filtered(List<DesktopCommand> commands) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return commands;
    return [
      for (final command in commands)
        if (command.label.toLowerCase().contains(query)) command,
    ];
  }
}
