import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:collection/collection.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:localmind/l10n/app_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../chat/data/mcp_server_manager.dart';
import '../../chat/data/tools/calendar_service.dart';
import '../../chat/data/tools/location_service.dart';
import '../../chat/data/tools/tool_definition.dart';
import '../../chat/providers/chat_mcp_providers.dart';
import '../../chat/providers/tooling_providers.dart';
import '../../mail/data/google_auth_client.dart';
import '../../mail/data/imap_connection_test.dart';
import '../../mail/data/mail_common.dart';
import '../../mail/data/mail_connector_config.dart';
import '../../mail/data/mail_token_store.dart';
import '../../mail/data/outlook_auth_client.dart';
import '../../settings/data/models/app_settings.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/theme/colors.dart';
import '../../../core/utils/system_insets.dart';

class McpToolsScreen extends ConsumerWidget {
  const McpToolsScreen({super.key});

  void _toggleExampleServer(WidgetRef ref) {
    final manager = ref.read(mcpServerManagerProvider);
    if (manager.hasExampleServer()) {
      manager.removeServer(exampleMcpServerLabel);
    } else {
      manager.addExampleServer();
    }
    ref.invalidate(availableToolsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(settingsProvider);
    final manager = ref.watch(mcpServerManagerProvider);
    final hasExampleServer = manager.hasExampleServer();
    final toolsAsync = ref.watch(availableToolsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final topPadding = MediaQuery.of(context).padding.top;
    final bottomInset = bottomSystemInset(context);

    ref.watch(webServerRegistrationProvider);

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
              Builder(
                builder: (context) => IconButton(
                  icon: const HugeIcon(icon: HugeIcons.strokeRoundedMenu01),
                  onPressed: () => Scaffold.maybeOf(context)?.openDrawer(),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                l10n.mcp_tools_title,
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
              final useTwoColumns = constraints.maxWidth >= 1080;
              final contentMaxWidth = useTwoColumns ? 1120.0 : 720.0;
              final horizontalPadding = constraints.maxWidth >= 720
                  ? 20.0
                  : 12.0;

              final mcpCard = _McpSectionCard(
                title: l10n.mcp_tools_title,
                children: [
                  _McpToggleSetting(
                    label: l10n.enable_mcp,
                    value: settings.mcpEnabled,
                    badges: [_FeatureBadge(label: l10n.experimental_label)],
                    onChanged: (value) {
                      ref.read(settingsProvider.notifier).setMcpEnabled(value);
                    },
                  ),
                  if (settings.mcpEnabled) ...[
                    _McpToggleSetting(
                      label: l10n.new_chat_mcp_default,
                      value: settings.newChatMcpEnabled,
                      onChanged: (value) => ref
                          .read(settingsProvider.notifier)
                          .setNewChatMcpEnabled(value),
                    ),
                    _McpToggleSetting(
                      label: l10n.calendar_access,
                      description: l10n.calendar_access_desc,
                      value: settings.calendarToolsEnabled,
                      onChanged: (value) async {
                        if (value) {
                          final cal = CalendarService.instance;
                          final granted = await cal.requestAccess();
                          if (granted) {
                            ref
                                .read(settingsProvider.notifier)
                                .setCalendarToolsEnabled(true);
                          } else {
                            if (context.mounted) {
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.calendar_permission_denied,
                                  ),
                                ),
                              );
                            }
                          }
                        } else {
                          ref
                              .read(settingsProvider.notifier)
                              .setCalendarToolsEnabled(false);
                        }
                      },
                    ),
                    _McpToggleSetting(
                      label: l10n.location_access,
                      description: l10n.location_access_desc,
                      value: settings.locationToolsEnabled,
                      onChanged: (value) async {
                        if (value) {
                          final location = LocationService.instance;
                          final granted = await location.requestAccess();
                          if (granted) {
                            ref
                                .read(settingsProvider.notifier)
                                .setLocationToolsEnabled(true);
                          } else {
                            if (context.mounted) {
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.location_permission_denied,
                                  ),
                                ),
                              );
                            }
                          }
                        } else {
                          ref
                              .read(settingsProvider.notifier)
                              .setLocationToolsEnabled(false);
                        }
                      },
                    ),
                    _McpToggleSetting(
                      label: l10n.enable_example_server,
                      description: l10n.example_mcp_server_desc,
                      value: hasExampleServer,
                      onChanged: (_) => _toggleExampleServer(ref),
                    ),
                  ],
                ],
              );

              final toolsCard = _McpSectionCard(
                title: l10n.available_tools,
                accent: const Color(0xFF22C55E),
                icon: HugeIcons.strokeRoundedPuzzle,
                children: [
                  _buildToolsContent(l10n, settings.mcpEnabled, toolsAsync),
                ],
              );

              return ListView(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  12,
                  horizontalPadding,
                  24 + bottomInset,
                ),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: contentMaxWidth),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          mcpCard,
                          const SizedBox(height: 16),
                          const _WebBrowserCard(),
                          const SizedBox(height: 16),
                          const _TerminalCard(),
                          const SizedBox(height: 16),
                          const _DeviceCard(),
                          const SizedBox(height: 16),
                          const _MailConnectorsCard(),
                          if (settings.mcpEnabled) ...[
                            const SizedBox(height: 16),
                            _ConfiguredMcpServersCard(
                              onServersChanged: () =>
                                  ref.invalidate(availableToolsProvider),
                            ),
                          ],
                          const SizedBox(height: 16),
                          toolsCard,
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

  Widget _buildToolsContent(
    AppLocalizations l10n,
    bool mcpEnabled,
    AsyncValue<List<ToolDefinition>> toolsAsync,
  ) {
    if (!mcpEnabled) {
      return _StatusPanel(
        icon: HugeIcons.strokeRoundedAlertCircle,
        title: l10n.mcp_disabled_warning,
        body: l10n.no_tools_registered_desc,
      );
    }

    return toolsAsync.when(
      loading: () => _McpPanel(
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
      error: (error, _) => _StatusPanel(
        icon: HugeIcons.strokeRoundedInformationCircle,
        title: l10n.unable_load_tools,
        body: error.toString(),
      ),
      data: (tools) {
        if (tools.isEmpty) {
          return _StatusPanel(
            icon: HugeIcons.strokeRoundedPuzzle,
            title: l10n.no_tools_registered,
            body: l10n.no_tools_registered_desc,
          );
        }

        return Column(
          children: tools
              .map((tool) => _ToolRow(tool: tool))
              .toList(growable: false),
        );
      },
    );
  }
}

class _McpSectionCard extends StatelessWidget {
  const _McpSectionCard({
    required this.title,
    required this.children,
    this.icon = HugeIcons.strokeRoundedMcpServer,
    this.accent = const Color(0xFF8B5CF6),
    this.trailing,
  });

  final String title;
  final List<List<dynamic>> icon;
  final Color accent;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _surfaceColor(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _outlineColor(context, alpha: 0.9)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: HugeIcon(icon: icon, color: accent, size: 16),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ],
            ),
            const SizedBox(height: 12),
            ..._withVerticalSpacing(children, gap: 10),
          ],
        ),
      ),
    );
  }
}

class _McpPanel extends StatelessWidget {
  const _McpPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _panelColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _outlineColor(context)),
      ),
      child: child,
    );
  }
}

class _McpToggleSetting extends StatelessWidget {
  const _McpToggleSetting({
    required this.label,
    required this.value,
    required this.onChanged,
    this.description,
    this.badges = const [],
  });

  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool> onChanged;
  final List<Widget> badges;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _McpPanel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    ...badges,
                  ],
                ),
                if (description != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    description!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.tool});

  final ToolDefinition tool;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final isMcp = tool.providerType == ToolProviderType.mcp;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _McpPanel(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HugeIcon(
              icon: isMcp
                  ? HugeIcons.strokeRoundedShare01
                  : (tool.name.startsWith('calendar.')
                        ? HugeIcons.strokeRoundedCalendar01
                        : (tool.name.startsWith('location.')
                              ? HugeIcons.strokeRoundedLocation01
                              : (tool.name.startsWith('sms.')
                                    ? HugeIcons.strokeRoundedMessage01
                                    : HugeIcons.strokeRoundedCalculate))),
              size: 18,
              color: isMcp
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tool.name,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (tool.description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      tool.description,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _ToolBadge(
                        label: isMcp ? 'MCP' : l10n.built_in_label,
                        color: isMcp
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                      ),
                      if (tool.providerRef != null)
                        _ToolBadge(
                          label: tool.providerRef!,
                          color: theme.colorScheme.secondary,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolBadge extends StatelessWidget {
  const _ToolBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.icon,
    required this.title,
    required this.body,
  });

  final List<List<dynamic>> icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _McpPanel(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            HugeIcon(icon: icon, size: 28, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              body,
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

class _FeatureBadge extends StatelessWidget {
  const _FeatureBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.22)),
      ),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: const Color(0xFFB45309),
          fontWeight: FontWeight.w800,
          letterSpacing: 0.45,
        ),
      ),
    );
  }
}

// Visual helpers, kept in sync with settings_screen.dart to ensure the
// MCP screen matches the rest of the app's settings surfaces.
List<Widget> _withVerticalSpacing(List<Widget> children, {double gap = 12}) {
  if (children.isEmpty) return const [];
  return [
    for (var index = 0; index < children.length; index++) ...[
      children[index],
      if (index != children.length - 1) SizedBox(height: gap),
    ],
  ];
}

Color _panelColor(BuildContext context) {
  return ShadTheme.of(context).colorScheme.secondary;
}

Color _surfaceColor(BuildContext context) {
  return ShadTheme.of(context).colorScheme.card;
}

Color _outlineColor(BuildContext context, {double alpha = 0.6}) {
  return ShadTheme.of(context).colorScheme.border.withValues(alpha: alpha);
}

class _WebBrowserCard extends ConsumerStatefulWidget {
  const _WebBrowserCard();

  @override
  ConsumerState<_WebBrowserCard> createState() => __WebBrowserCardState();
}

class __WebBrowserCardState extends ConsumerState<_WebBrowserCard> {
  static const _providerOptions = <String, String>{
    'auto': 'Auto (keyless ring → DDG)',
    'searxng': 'SearXNG (self-hosted, private)',
    'ring': 'Keyless ring (exa/parallel)',
    'ddg': 'DuckDuckGo (no key)',
    'tavily': 'Tavily',
    'brave': 'Brave',
    'serper': 'Serper',
  };

  final _apiKeyController = TextEditingController();
  final _apiKeyFocusNode = FocusNode();
  final _searxUrlController = TextEditingController();
  final _searxUrlFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _apiKeyController.text = ref.read(settingsProvider).webSearchApiKey ?? '';
    _apiKeyFocusNode.addListener(_onApiKeyFocusChange);
    _searxUrlController.text = ref.read(settingsProvider).webSearxUrl ?? '';
    _searxUrlFocusNode.addListener(_onSearxUrlFocusChange);
  }

  @override
  void dispose() {
    _apiKeyFocusNode.removeListener(_onApiKeyFocusChange);
    _apiKeyFocusNode.dispose();
    _apiKeyController.dispose();
    _searxUrlFocusNode.removeListener(_onSearxUrlFocusChange);
    _searxUrlFocusNode.dispose();
    _searxUrlController.dispose();
    super.dispose();
  }

  void _onApiKeyFocusChange() {
    // Most users dismiss the keyboard by tapping elsewhere rather than
    // pressing a keyboard "done" action, which doesn't fire onSubmitted
    // or onEditingComplete. Save on focus loss too so typed values apply.
    if (!_apiKeyFocusNode.hasFocus) {
      _saveApiKey();
    }
  }

  void _onSearxUrlFocusChange() {
    if (!_searxUrlFocusNode.hasFocus) {
      _saveSearxUrl();
    }
  }

  void _saveApiKey() {
    final key = _apiKeyController.text.trim();
    if (key == (ref.read(settingsProvider).webSearchApiKey ?? '')) return;
    ref
        .read(settingsProvider.notifier)
        .setWebSearchApiKey(key.isEmpty ? null : key);
    ref.invalidate(availableToolsProvider);
  }

  void _saveSearxUrl() {
    final url = _searxUrlController.text.trim();
    if (url == (ref.read(settingsProvider).webSearxUrl ?? '')) return;
    ref
        .read(settingsProvider.notifier)
        .setWebSearxUrl(url.isEmpty ? null : url);
    ref.invalidate(availableToolsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final enabled = settings.webToolsEnabled;

    return _McpSectionCard(
      title: l10n.web_browser_card_title,
      accent: const Color(0xFF0EA5E9),
      icon: HugeIcons.strokeRoundedGlobe02,
      trailing: ShadSwitch(
        key: const Key('web_tools_toggle'),
        value: enabled,
        onChanged: (value) {
          ref.read(settingsProvider.notifier).setWebToolsEnabled(value);
          ref.invalidate(availableToolsProvider);
        },
      ),
      children: [
        Text(
          l10n.web_browser_card_desc,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Opacity(
          opacity: enabled ? 1.0 : 0.55,
          child: IgnorePointer(
            ignoring: !enabled,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.web_search_provider,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                ShadSelect<String>(
                  key: const Key('web_search_provider_select'),
                  initialValue: settings.webSearchProvider,
                  selectedOptionBuilder: (context, value) =>
                      Text(_providerOptions[value] ?? value),
                  options: [
                    for (final entry in _providerOptions.entries)
                      ShadOption(value: entry.key, child: Text(entry.value)),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    ref
                        .read(settingsProvider.notifier)
                        .setWebSearchProvider(value);
                    ref.invalidate(availableToolsProvider);
                  },
                ),
                const SizedBox(height: 12),
                if (settings.webSearchProvider == 'searxng') ...[
                  Text(
                    l10n.searx_base_url_label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ShadInput(
                    key: const Key('web_searx_url'),
                    controller: _searxUrlController,
                    focusNode: _searxUrlFocusNode,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.url,
                    placeholder: Text(l10n.searx_base_url_hint),
                    onSubmitted: (_) => _saveSearxUrl(),
                    onEditingComplete: () => _saveSearxUrl(),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  l10n.web_search_provider_key,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                ShadInput(
                  key: const Key('web_search_api_key'),
                  controller: _apiKeyController,
                  focusNode: _apiKeyFocusNode,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  placeholder: Text(l10n.web_search_key_hint),
                  onSubmitted: (_) => _saveApiKey(),
                  onEditingComplete: () => _saveApiKey(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ConfiguredMcpServersCard extends ConsumerStatefulWidget {
  const _ConfiguredMcpServersCard({required this.onServersChanged});

  final VoidCallback onServersChanged;

  @override
  ConsumerState<_ConfiguredMcpServersCard> createState() =>
      __ConfiguredMcpServersCardState();
}

class __ConfiguredMcpServersCardState
    extends ConsumerState<_ConfiguredMcpServersCard> {
  final _serverLabelController = TextEditingController();
  final _serverUrlController = TextEditingController();

  @override
  void dispose() {
    _serverLabelController.dispose();
    _serverUrlController.dispose();
    super.dispose();
  }

  void _addServer() {
    final label = _serverLabelController.text.trim();
    final url = _serverUrlController.text.trim();
    if (label.isEmpty && url.isEmpty) return;

    final McpIntegration integration;
    if (label.contains('/') || url.contains('/')) {
      final raw = label.isNotEmpty ? label : url;
      final pluginId = raw.contains('/') ? raw : 'mcp/$raw';
      integration = McpIntegration(
        type: McpIntegrationType.plugin,
        pluginId: pluginId,
        serverLabel: label.isNotEmpty ? label : null,
      );
    } else {
      if (label.isEmpty || url.isEmpty) return;
      integration = McpIntegration(
        type: McpIntegrationType.ephemeralMcp,
        serverLabel: label,
        serverUrl: url,
      );
    }

    ref.read(settingsProvider.notifier).addSavedMcpIntegration(integration);
    ref.read(chatMcpConfigProvider.notifier).addIntegration(integration);
    _serverLabelController.clear();
    _serverUrlController.clear();
    widget.onServersChanged();
  }

  void _showImportJsonDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final jsonController = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              const HugeIcon(icon: HugeIcons.strokeRoundedFileImport, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.import_mcp_json_dialog_title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark
                        ? AppColors.darkBackground
                        : AppColors.lightSurface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isDark
                          ? AppColors.darkSurfaceCard
                          : AppColors.lightBorder,
                    ),
                  ),
                  child: Text(
                    l10n.import_mcp_json_instructions,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? AppColors.darkMutedText
                          : AppColors.lightMutedText,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ShadInput(
                  controller: jsonController,
                  maxLines: 8,
                  placeholder: Text(
                    l10n.import_mcp_json_placeholder,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            ShadButton.ghost(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancel),
            ),
            ShadButton(
              onPressed: () {
                final jsonStr = jsonController.text.trim();
                if (jsonStr.isNotEmpty) {
                  final count = ref
                      .read(chatMcpConfigProvider.notifier)
                      .importIntegrationsFromJson(jsonStr);
                  Navigator.of(dialogContext).pop();
                  widget.onServersChanged();

                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(
                      content: Text(
                        count > 0
                            ? l10n.mcp_import_success(count)
                            : l10n.mcp_import_failed,
                      ),
                      backgroundColor: count > 0 ? Colors.green : Colors.red,
                    ),
                  );
                }
              },
              child: Text(l10n.import_mcp_json),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(settingsProvider);
    final savedIntegrations = settings.savedMcpIntegrations;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return _McpSectionCard(
      title: l10n.active_integrations,
      accent: const Color(0xFF3B82F6),
      icon: HugeIcons.strokeRoundedMcpServer,
      trailing: ShadButton.outline(
        size: ShadButtonSize.sm,
        onPressed: () => _showImportJsonDialog(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const HugeIcon(icon: HugeIcons.strokeRoundedFileImport, size: 16),
            const SizedBox(width: 4),
            Text(l10n.import_mcp_json),
          ],
        ),
      ),
      children: [
        if (savedIntegrations.isNotEmpty) ...[
          ListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: savedIntegrations.length,
            itemBuilder: (context, index) {
              final integration = savedIntegrations[index];
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: isDark
                      ? AppColors.darkBackground
                      : AppColors.lightSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark
                        ? AppColors.darkSurfaceCard
                        : AppColors.lightBorder,
                  ),
                ),
                child: ListTile(
                  dense: true,
                  leading: HugeIcon(
                    icon: HugeIcons.strokeRoundedPuzzle,
                    size: 18,
                    color: integration.enabled ? null : Colors.grey,
                  ),
                  title: Text(
                    integration.serverLabel ?? integration.pluginId ?? '',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      decoration: integration.enabled
                          ? TextDecoration.none
                          : TextDecoration.lineThrough,
                      color: integration.enabled
                          ? null
                          : (isDark
                                ? AppColors.darkMutedText
                                : AppColors.lightMutedText),
                    ),
                  ),
                  subtitle: Text(
                    integration.type == McpIntegrationType.plugin
                        ? 'Plugin (${integration.pluginId})'
                        : (integration.serverUrl ?? ''),
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ShadSwitch(
                        value: integration.enabled,
                        onChanged: (v) {
                          ref
                              .read(settingsProvider.notifier)
                              .toggleSavedMcpIntegration(index, v);
                          ref
                              .read(chatMcpConfigProvider.notifier)
                              .toggleIntegration(index, v);
                        },
                      ),
                      const SizedBox(width: 4),
                      ShadIconButton.ghost(
                        icon: const HugeIcon(
                          icon: HugeIcons.strokeRoundedDelete01,
                          size: 18,
                          color: Colors.red,
                        ),
                        onPressed: () {
                          ref
                              .read(settingsProvider.notifier)
                              .removeSavedMcpIntegration(index);
                          ref
                              .read(chatMcpConfigProvider.notifier)
                              .removeIntegration(index);
                          widget.onServersChanged();
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
        Row(
          children: [
            Expanded(
              child: ShadInput(
                controller: _serverLabelController,
                placeholder: Text(l10n.mcp_label_placeholder),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: ShadInput(
                controller: _serverUrlController,
                placeholder: Text(l10n.mcp_url_placeholder),
                keyboardType: TextInputType.url,
              ),
            ),
            const SizedBox(width: 8),
            ShadIconButton(
              icon: const HugeIcon(icon: HugeIcons.strokeRoundedAdd01),
              onPressed: _addServer,
            ),
          ],
        ),
      ],
    );
  }
}

class _TerminalCard extends ConsumerStatefulWidget {
  const _TerminalCard();

  @override
  ConsumerState<_TerminalCard> createState() => __TerminalCardState();
}

class __TerminalCardState extends ConsumerState<_TerminalCard> {
  final _whitelistController = TextEditingController();
  final _whitelistFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _whitelistController.text = ref
        .read(settingsProvider)
        .toolWhitelist
        .join(', ');
    _whitelistFocusNode.addListener(_onWhitelistFocusChange);
  }

  @override
  void dispose() {
    _whitelistFocusNode.removeListener(_onWhitelistFocusChange);
    _whitelistFocusNode.dispose();
    _whitelistController.dispose();
    super.dispose();
  }

  void _onWhitelistFocusChange() {
    if (!_whitelistFocusNode.hasFocus) _saveWhitelist();
  }

  void _saveWhitelist() {
    final entries = _whitelistController.text
        .split(RegExp(r'[,\n]'))
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty && !entry.startsWith('#'))
        .toList();
    final current = ref.read(settingsProvider).toolWhitelist;
    if (const ListEquality<String>().equals(entries, current)) return;
    ref.read(settingsProvider.notifier).setToolWhitelist(entries);
    ref.invalidate(availableToolsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final enabled = settings.terminalToolsEnabled;

    return _McpSectionCard(
      title: l10n.terminal_card_title,
      accent: const Color(0xFF10B981),
      icon: HugeIcons.strokeRoundedTerminal,
      trailing: ShadSwitch(
        key: const Key('terminal_tools_toggle'),
        value: enabled,
        onChanged: (value) {
          ref.read(settingsProvider.notifier).setTerminalToolsEnabled(value);
          ref.invalidate(availableToolsProvider);
        },
      ),
      children: [
        Text(
          l10n.terminal_card_desc,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Opacity(
          opacity: enabled ? 1.0 : 0.55,
          child: IgnorePointer(
            ignoring: !enabled,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.terminal_whitelist_label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                ShadInput(
                  key: const Key('terminal_whitelist_input'),
                  controller: _whitelistController,
                  focusNode: _whitelistFocusNode,
                  autocorrect: false,
                  enableSuggestions: false,
                  placeholder: Text(l10n.terminal_whitelist_hint),
                  onSubmitted: (_) => _saveWhitelist(),
                  onEditingComplete: () => _saveWhitelist(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DeviceCard extends ConsumerWidget {
  const _DeviceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final enabled = settings.deviceToolsEnabled;

    return _McpSectionCard(
      title: l10n.device_card_title,
      accent: const Color(0xFF8B5CF6),
      icon: HugeIcons.strokeRoundedSmartPhone01,
      trailing: ShadSwitch(
        key: const Key('device_tools_toggle'),
        value: enabled,
        onChanged: (value) {
          ref.read(settingsProvider.notifier).setDeviceToolsEnabled(value);
          ref.invalidate(availableToolsProvider);
        },
      ),
      children: [
        Text(
          l10n.device_card_desc,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        // Share-target landing rides on device tooling: gated + dimmed with
        // the same filtered pattern the web/browser card uses.
        Opacity(
          opacity: enabled ? 1.0 : 0.55,
          child: IgnorePointer(
            ignoring: !enabled,
            child: _McpPanel(
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.share_target_label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ShadSwitch(
                    key: const Key('share_target_toggle'),
                    value: settings.shareTargetEnabled,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setShareTargetEnabled(value),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MailConnectorsCard extends ConsumerStatefulWidget {
  const _MailConnectorsCard();

  @override
  ConsumerState<_MailConnectorsCard> createState() =>
      _MailConnectorsCardState();
}

class _MailConnectorsCardState extends ConsumerState<_MailConnectorsCard> {
  /// Provider whose sign-in round-trip is in flight; drives the row's
  /// spinner and disables re-triggering while awaiting the consent sheet.
  MailProvider? _connecting;

  final _imapEmailController = TextEditingController();
  final _imapPasswordController = TextEditingController();
  final _imapHostController = TextEditingController();

  @override
  void dispose() {
    _imapEmailController.dispose();
    _imapPasswordController.dispose();
    _imapHostController.dispose();
    super.dispose();
  }

  MailAccount? _accountFor(MailProvider provider, AppSettings settings) {
    for (final row in settings.mailConnectorAccounts) {
      final account = MailAccount.fromMap(row);
      if (account.provider == provider && account.email.isNotEmpty) {
        return account;
      }
    }
    return null;
  }

  Future<void> _connect(MailProvider provider) async {
    setState(() => _connecting = provider);
    try {
      // The gateway surfaces misconfiguration (SHA-1 / OAuth client, Azure
      // registration) through MailConnectorException — the UI only renders
      // its message here; successful sign-in yields the account identity.
      final email = await _signInEmail(provider);
      if (!mounted) return;
      if (email.isEmpty) {
        // Backed out of the consent sheet — nothing to persist, silently.
        return;
      }
      _storeAccount(provider, email);
    } on MailConnectorException catch (error) {
      _toast(error.message);
    } catch (error) {
      _toast(error.toString());
    } finally {
      if (mounted) setState(() => _connecting = null);
    }
  }

  /// Interactive sign-in; null/empty email = user backed out of consent.
  /// The imap provider never enters here — it connects through the form
  /// panels below ([_connectImap]), not an OAuth consent sheet.
  Future<String> _signInEmail(MailProvider provider) {
    switch (provider) {
      case MailProvider.gmail:
        final clientId = MailConnectorConfig.googleServerClientId;
        return GoogleMailAuthGateway(
          serverClientId: clientId.isEmpty ? null : clientId,
        ).signIn().then((token) => token?.email ?? '');
      case MailProvider.outlook:
        return MsalOutlookAuthGateway(
          clientId: MailConnectorConfig.outlookClientId,
          tokens: ref.read(mailTokenStoreProvider),
        ).signIn().then((token) => token?.email ?? '');
      case MailProvider.imap:
        throw StateError('imap connects through the form, not OAuth');
    }
  }

  /// Upserts the provider's identity row (settings only carry provider +
  /// email; tokens live in the platform caches + token store). An optional
  /// [host] lands in the row for the imap connector's manual override.
  void _storeAccount(MailProvider provider, String email, [String? host]) {
    final rows = ref
        .read(settingsProvider)
        .mailConnectorAccounts
        .where(
          (row) =>
              MailProviderName.fromName(row['provider']?.toString()) !=
              provider,
        )
        .toList();
    rows.add({
      'provider': MailProviderName.nameOf(provider),
      'email': email,
      if (host != null && host.isNotEmpty) 'host': host,
    });
    ref
        .read(settingsProvider.notifier)
        .setMailConnectorAccounts(List.unmodifiable(rows));
    ref.invalidate(availableToolsProvider);
  }

  Future<void> _disconnect(MailProvider provider) async {
    // Capture the identity before the row goes away — the imap clean-up
    // needs the email to purge its token-store entry.
    final account = _accountFor(provider, ref.read(settingsProvider));
    final rows = ref
        .read(settingsProvider)
        .mailConnectorAccounts
        .where(
          (row) =>
              MailProviderName.fromName(row['provider']?.toString()) !=
              provider,
        )
        .toList();
    ref
        .read(settingsProvider.notifier)
        .setMailConnectorAccounts(List.unmodifiable(rows));
    ref.invalidate(availableToolsProvider);
    // Removing the identity row first (it is what gates registration);
    // platform-cache sign-out is best-effort afterwards.
    try {
      switch (provider) {
        case MailProvider.gmail:
          final clientId = MailConnectorConfig.googleServerClientId;
          await GoogleMailAuthGateway(
            serverClientId: clientId.isEmpty ? null : clientId,
          ).signOut();
        case MailProvider.outlook:
          await MsalOutlookAuthGateway(
            clientId: MailConnectorConfig.outlookClientId,
            tokens: ref.read(mailTokenStoreProvider),
          ).signOut();
        case MailProvider.imap:
          if (account != null) {
            await ref
                .read(mailTokenStoreProvider)
                .clear(MailProvider.imap, account.email);
          }
      }
    } catch (_) {}
  }

  /// IMAP connect flow: a one-off live validation against the server with
  /// the typed credentials; on success the identity row (plus optional host
  /// override) lands in settings and the app password goes to the token
  /// store — far-future expiry since basic-auth passwords don't rotate on
  /// their own. Failures surface as the probe's model-readable message.
  Future<void> _connectImap() async {
    final l10n = AppLocalizations.of(context)!;
    final email = _imapEmailController.text.trim().toLowerCase();
    final password = _imapPasswordController.text;
    final host = _imapHostController.text.trim();
    if (email.isEmpty || password.isEmpty) {
      _toast(l10n.imap_fields_required);
      return;
    }
    setState(() => _connecting = MailProvider.imap);
    try {
      final failure = await ref
          .read(imapConnectProbeProvider)
          .verify(
            email: email,
            password: password,
            host: host.isEmpty ? null : host,
          );
      if (!mounted) return;
      if (failure != null) {
        _toast(failure);
        return;
      }
      _storeAccount(MailProvider.imap, email, host);
      await ref
          .read(mailTokenStoreProvider)
          .updateToken(
            MailProvider.imap,
            email,
            password,
            DateTime.now().add(const Duration(days: 3650)),
          );
      _imapPasswordController.clear();
    } finally {
      if (mounted) setState(() => _connecting = null);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);

    return _McpSectionCard(
      title: l10n.mail_connectors_card_title,
      accent: const Color(0xFF2563EB),
      icon: HugeIcons.strokeRoundedMail01,
      children: [
        Text(
          l10n.mail_connectors_card_desc,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        _providerRow(
          context,
          MailProvider.gmail,
          HugeIcons.strokeRoundedMail01,
          account: _accountFor(MailProvider.gmail, settings),
          connectLabel: l10n.mail_connect_gmail,
        ),
        _providerRow(
          context,
          MailProvider.outlook,
          HugeIcons.strokeRoundedMicrosoft,
          account: _accountFor(MailProvider.outlook, settings),
          connectLabel: l10n.mail_connect_outlook,
        ),
        _imapRow(context, settings),
      ],
    );
  }

  /// The imap connector is password-based, so its surface is a form:
  /// e-mail + app password + an optional manual host. A connected account
  /// collapses the form back into the shared connected-row rendering.
  Widget _imapRow(BuildContext context, AppSettings settings) {
    final account = _accountFor(MailProvider.imap, settings);
    if (account != null) {
      return _providerRow(
        context,
        MailProvider.imap,
        HugeIcons.strokeRoundedMailSecure01,
        account: account,
        connectLabel: '',
      );
    }
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final connecting = _connecting == MailProvider.imap;

    return _McpPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Center(
                  child: HugeIcon(
                    icon: HugeIcons.strokeRoundedMailSecure01,
                    color: Color(0xFF2563EB),
                    size: 15,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.mail_connect_imap,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.imap_hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          ShadInput(
            key: const Key('imap_email_input'),
            controller: _imapEmailController,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            enableSuggestions: false,
            placeholder: Text(l10n.imap_email_hint),
          ),
          const SizedBox(height: 8),
          ShadInput(
            key: const Key('imap_password_input'),
            controller: _imapPasswordController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            placeholder: Text(l10n.imap_password_hint),
          ),
          const SizedBox(height: 8),
          ShadInput(
            key: const Key('imap_host_input'),
            controller: _imapHostController,
            autocorrect: false,
            enableSuggestions: false,
            placeholder: Text(l10n.imap_host_hint),
          ),
          const SizedBox(height: 10),
          ShadButton(
            key: const Key('imap_connect_button'),
            onPressed: connecting ? null : _connectImap,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (connecting) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(l10n.imap_connect),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _providerRow(
    BuildContext context,
    MailProvider provider,
    List<List<dynamic>> icon, {
    required MailAccount? account,
    required String connectLabel,
  }) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final accent = const Color(0xFF2563EB);
    final connecting = _connecting == provider;

    return _McpPanel(
      child: account == null
          ? InkWell(
              onTap: connecting ? null : () => _connect(provider),
              borderRadius: BorderRadius.circular(10),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: HugeIcon(icon: icon, color: accent, size: 15),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      connectLabel,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  connecting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : HugeIcon(
                          icon: HugeIcons.strokeRoundedArrowRight01,
                          size: 16,
                          color: theme.colorScheme.outline,
                        ),
                ],
              ),
            )
          : Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: HugeIcon(icon: icon, color: accent, size: 15),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.mail_connected_as(account.email),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: () => _disconnect(provider),
                  child: Text(l10n.mail_disconnect),
                ),
              ],
            ),
    );
  }
}
