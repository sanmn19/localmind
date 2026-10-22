import 'core/widgets/share_receive_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'l10n/app_localizations.dart';

import 'core/models/enums.dart';
import 'core/providers/app_providers.dart';
import 'core/routes/app_routes.dart';
import 'core/routes/shell_back_scope.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/locale_utils.dart';
import 'core/utils/platform_support.dart';
import 'core/widgets/android_assistant_invocation_host.dart';
import 'core/widgets/web_server_registration_host.dart';
import 'features/chat/providers/chat_mcp_providers.dart';
import 'features/chat/providers/chat_providers.dart';
import 'features/conversations/data/models/conversation.dart';
import 'features/conversations/providers/conversation_providers.dart' as conv;
import 'features/chat/views/chat_screen.dart';
import 'features/conversations/views/chat_history_screen.dart';
import 'features/desktop/data/models/desktop_window.dart';
import 'features/desktop/views/components/desktop_command_palette.dart';
import 'features/desktop/views/desktop_host.dart';
import 'features/mcp/views/mcp_tools_screen.dart';
import 'features/on_device/views/model_manager_screen.dart';
import 'features/os_widget/views/os_widget_invocation_host.dart';
import 'features/onboarding/screens/onboarding_language_screen.dart';
import 'features/onboarding/screens/onboarding_model_download_screen.dart';
import 'features/onboarding/screens/onboarding_notification_permission_screen.dart';
import 'features/onboarding/screens/onboarding_server_setup_screen.dart';
import 'features/onboarding/screens/onboarding_server_type_screen.dart';
import 'features/onboarding/screens/onboarding_theme_screen.dart';
import 'features/personas/views/create_persona_screen.dart';
import 'features/personas/views/persona_list_screen.dart';
import 'features/servers/data/models/server.dart';
import 'features/servers/providers/server_providers.dart';
import 'features/servers/views/add_server_screen.dart';
import 'features/servers/views/server_list_screen.dart';
import 'features/tts/views/tts_model_manager_screen.dart';
import 'features/saved_messages/views/saved_messages_screen.dart';
import 'features/settings/views/settings_screen.dart';
import 'features/skills/data/skills_store.dart';
import 'features/background/views/background_tasks_page.dart';
import 'features/skills/views/skill_editor_screen.dart';
import 'features/skills/views/skills_screen.dart';
import 'features/cloud_sync/views/cloud_sync_screen.dart';
import 'features/lm_studio_catalog/views/lm_studio_model_browser_screen.dart';
import 'features/sidebar/sidebar_drawer.dart';
import 'features/sidebar/sidebar_widget.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/',
    redirect: (context, state) {
      final hasCompletedOnboarding = ref
          .read(settingsProvider)
          .hasCompletedOnboarding;
      final isGoingToOnboarding = state.uri.toString().startsWith(
        '/onboarding',
      );

      if (!hasCompletedOnboarding && !isGoingToOnboarding) {
        return AppRoutes.onboarding;
      }

      if (hasCompletedOnboarding && isGoingToOnboarding) {
        return AppRoutes.home;
      }

      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.onboarding,
        pageBuilder: (context, state) =>
            const MaterialPage(child: OnboardingLanguageScreen()),
      ),
      GoRoute(
        path: AppRoutes.onboardingServerType,
        pageBuilder: (context, state) =>
            const MaterialPage(child: OnboardingServerTypeScreen()),
      ),
      GoRoute(
        path: AppRoutes.onboardingSetup,
        pageBuilder: (context, state) {
          final serverType = state.extra as ServerType?;
          return MaterialPage(
            child: OnboardingServerSetupScreen(
              selectedType: serverType ?? ServerType.lmStudio,
            ),
          );
        },
      ),
      GoRoute(
        path: AppRoutes.onboardingModelDownload,
        pageBuilder: (context, state) =>
            const MaterialPage(child: OnboardingModelDownloadScreen()),
      ),
      GoRoute(
        path: AppRoutes.onboardingTheme,
        pageBuilder: (context, state) =>
            const MaterialPage(child: OnboardingThemeScreen()),
      ),
      GoRoute(
        path: AppRoutes.onboardingNotifications,
        pageBuilder: (context, state) =>
            const MaterialPage(child: OnboardingNotificationPermissionScreen()),
      ),
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) {
          return OsWidgetInvocationHost(
            child: WebServerRegistrationHost(
              child: AndroidAssistantInvocationHost(
                child: ShareReceiveHost(child: AppShell(child: child)),
              ),
            ),
          );
        },
        routes: [
          GoRoute(
            path: AppRoutes.home,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ShellBackScope(child: ChatScreen()),
            ),
          ),
          GoRoute(
            path: AppRoutes.servers,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ShellBackScope(child: ServerListScreen()),
            ),
          ),
          GoRoute(
            path: AppRoutes.addServer,
            pageBuilder: (context, state) {
              final server = state.extra as Server?;
              return MaterialPage(
                child: ShellBackScope(
                  child: AddServerScreen(editServer: server),
                ),
              );
            },
          ),
          GoRoute(
            path: AppRoutes.personas,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ShellBackScope(child: PersonaListScreen()),
            ),
          ),
          GoRoute(
            path: AppRoutes.createPersona,
            pageBuilder: (context, state) {
              final persona = state.extra as dynamic;
              return MaterialPage(
                child: ShellBackScope(
                  child: CreatePersonaScreen(editPersona: persona),
                ),
              );
            },
          ),
          GoRoute(
            path: AppRoutes.settings,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ShellBackScope(child: SettingsViews()),
            ),
          ),
          GoRoute(
            path: AppRoutes.cloudSync,
            pageBuilder: (context, state) => const MaterialPage(
              child: ShellBackScope(child: CloudSyncScreen()),
            ),
          ),
          GoRoute(
            path: AppRoutes.chatHistory,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ShellBackScope(child: ChatHistoryScreen()),
            ),
          ),
          GoRoute(
            path: AppRoutes.mcpTools,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ShellBackScope(child: McpToolsScreen()),
            ),
          ),
          GoRoute(
            path: AppRoutes.skills,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ShellBackScope(child: SkillsScreen()),
            ),
          ),
          GoRoute(
            path: AppRoutes.skillEditor,
            pageBuilder: (context, state) {
              final skill = state.extra as SkillEntry?;
              return MaterialPage(
                child: ShellBackScope(
                  child: SkillEditorScreen(existing: skill),
                ),
              );
            },
          ),
          GoRoute(
            path: AppRoutes.background,
            pageBuilder: (context, state) {
              final focus = state.uri.queryParameters['focus'];
              return NoTransitionPage(
                child: ShellBackScope(
                  child: BackgroundTasksPage(focusOwnerId: focus),
                ),
              );
            },
          ),
          GoRoute(
            path: AppRoutes.onDeviceModels,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ShellBackScope(child: OnDeviceModelManagerScreen()),
            ),
          ),
          GoRoute(
            path: AppRoutes.ttsModels,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ShellBackScope(child: TtsModelManagerScreen()),
            ),
          ),
          GoRoute(
            path: AppRoutes.savedMessages,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ShellBackScope(child: SavedMessagesScreen()),
            ),
          ),
          GoRoute(
            path: AppRoutes.lmStudioModelBrowser,
            pageBuilder: (context, state) {
              final server = state.extra as Server?;
              if (server == null) {
                return const MaterialPage(child: SizedBox.shrink());
              }
              return MaterialPage(
                child: ShellBackScope(
                  child: LmStudioModelBrowserScreen(server: server),
                ),
              );
            },
          ),
        ],
      ),
    ],
  );
});

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final appThemeType = ref.watch(themeModeProvider);
    final localeCode = ref.watch(settingsProvider.select((s) => s.localeCode));
    final selectedLocale = findSupportedLocale(
      localeCode,
      AppLocalizations.supportedLocales,
    );

    ThemeData theme = AppTheme.lightTheme;
    ThemeData darkTheme = AppTheme.darkTheme;
    ThemeMode themeMode = ThemeMode.system;

    var shadTheme = AppTheme.lightShadTheme;
    var shadDarkTheme = AppTheme.darkShadTheme;

    switch (appThemeType) {
      case AppThemeType.light:
        themeMode = ThemeMode.light;
        shadTheme = AppTheme.lightShadTheme;
        break;
      case AppThemeType.dark:
        themeMode = ThemeMode.dark;
        shadTheme = AppTheme.darkShadTheme;
        // Also ensure shadDarkTheme matches so there's no mismatch
        shadDarkTheme = AppTheme.darkShadTheme;
        break;
      case AppThemeType.claude:
        themeMode = ThemeMode.light; // Force light mode for claude basically
        theme = AppTheme.claudeTheme;
        shadTheme = AppTheme.claudeShadTheme;
        break;
      case AppThemeType.system:
        themeMode = ThemeMode.system;
        shadTheme = AppTheme.lightShadTheme;
        shadDarkTheme = AppTheme.darkShadTheme;
        break;
    }

    return ShadApp.custom(
      themeMode: themeMode,
      theme: shadTheme,
      darkTheme: shadDarkTheme,
      appBuilder: (context) {
        return MaterialApp.router(
          title: 'LocalMind',
          debugShowCheckedModeBanner: false,
          theme: theme,
          darkTheme: darkTheme,
          themeMode: themeMode,
          routerConfig: router,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          locale: selectedLocale,
          localeResolutionCallback: (locale, supportedLocales) {
            if (selectedLocale != null) {
              return selectedLocale;
            }
            for (final l in supportedLocales) {
              if (l.languageCode == locale?.languageCode) return l;
            }
            return const Locale('en');
          },
          builder: (context, child) {
            return ShadAppBuilder(child: child!);
          },
        );
      },
    );
  }
}

class AppShell extends ConsumerStatefulWidget {
  final Widget child;

  const AppShell({super.key, required this.child});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _isDrawerOpen = false;
  bool _isHome = true;
  bool _hasActiveChat = false;

  /// What Back does when a page of the shell intercepts it. Reads live
  /// state so [ShellBackPolicy] can hand out this same tear-off every build.
  void _handleBack() {
    final override = ShellBackOverride.read(context);
    if (override != null) {
      override();
      return;
    }
    final scaffold = _scaffoldKey.currentState;
    if (scaffold?.isDrawerOpen ?? false) {
      scaffold!.closeDrawer();
      return;
    }
    if (!_isHome) {
      context.go(AppRoutes.home);
      return;
    }
    if (_hasActiveChat) {
      final origin = ref.read(chatOriginProvider);
      ref.read(chatOriginProvider.notifier).clear();
      switch (origin) {
        case ChatOrigin.history:
          context.go(AppRoutes.chatHistory);
        case ChatOrigin.savedMessages:
          context.go(AppRoutes.savedMessages);
        case ChatOrigin.none:
          ref.read(chatProvider.notifier).startNewConversation();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    _isHome = location == AppRoutes.home;

    // macOS runs one native window with an in-app window manager. Every other
    // platform keeps the router-driven shell.
    if (isMacDesktop) {
      return DesktopHost(
        initialRoute: location,
        sidebar: const SidebarWidget(),
        screenBuilder: buildDesktopScreen,
        conversationCommands: () => _desktopConversationCommands(ref),
        startNewChat: () async {
          await ref.read(chatProvider.notifier).startNewConversation();
          return ref.read(conv.activeConversationIdProvider);
        },
      );
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    _hasActiveChat = ref.watch(conv.activeConversationProvider) != null;
    final hasOverride = ShellBackOverride.maybeOf(context) != null;

    // On the empty home screen with the drawer closed, Back is left to the
    // OS so it leaves the app (with the predictive-back animation).
    final shellChild = ShellBackPolicy(
      interceptsAll: hasOverride || _isDrawerOpen,
      interceptsRoot: !_isHome || _hasActiveChat,
      onBack: _handleBack,
      child: widget.child,
    );

    return ShadResponsiveBuilder(
      builder: (context, breakpoint) {
        final isDesktop = breakpoint >= ShadTheme.of(context).breakpoints.md;

        if (isDesktop) {
          return Scaffold(
            key: _scaffoldKey,
            body: Row(
              children: [
                const SidebarWidget(),
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: isDark
                      ? const Color(0xFF1A1A1A)
                      : const Color(0xFFE5E5E5),
                ),
                Expanded(child: shellChild),
              ],
            ),
          );
        }

        return Scaffold(
          key: _scaffoldKey,
          body: shellChild,
          drawer: const ConversationDrawer(),
          onDrawerChanged: (isOpen) => setState(() => _isDrawerOpen = isOpen),
        );
      },
    );
  }
}

/// Builds the screen hosted by one desktop tab.
///
/// This is the only place that maps tabs onto feature screens, so the desktop
/// feature itself never imports a sibling feature. Chat tabs that belong to a
/// conversation are composed by [DesktopChatWindow] here as well. Tabs that need
/// router `extra` (add-server, persona, skill editor, model browser) open without
/// one after a relaunch and fall back to their create state.
Widget buildDesktopScreen(DesktopWindowState window) {
  return switch (window.kind) {
    DesktopWindowKind.chat =>
      window.conversationId == null
          ? const ChatScreen()
          : DesktopChatWindow(conversationId: window.conversationId!),
    DesktopWindowKind.history => const ChatHistoryScreen(),
    DesktopWindowKind.savedMessages => const SavedMessagesScreen(),
    DesktopWindowKind.servers => const ServerListScreen(),
    DesktopWindowKind.addServer => const AddServerScreen(),
    DesktopWindowKind.personas => const PersonaListScreen(),
    DesktopWindowKind.createPersona => const CreatePersonaScreen(),
    DesktopWindowKind.settings => const SettingsViews(),
    DesktopWindowKind.cloudSync => const CloudSyncScreen(),
    DesktopWindowKind.mcpTools => const McpToolsScreen(),
    DesktopWindowKind.skills => const SkillsScreen(),
    DesktopWindowKind.skillEditor => const SkillEditorScreen(),
    DesktopWindowKind.background => const BackgroundTasksPage(),
    DesktopWindowKind.onDeviceModels => const OnDeviceModelManagerScreen(),
    DesktopWindowKind.ttsModels => const TtsModelManagerScreen(),
    DesktopWindowKind.lmStudioModels => const _DesktopLmStudioBrowser(),
    DesktopWindowKind.onboarding => const OnboardingLanguageScreen(),
  };
}

/// One chat tab, bound to a single conversation.
///
/// It composes the chat screen and the conversation that screen is fixed to,
/// which is why it lives beside [buildDesktopScreen] in the app layer instead of
/// in the desktop feature.
class DesktopChatWindow extends ConsumerWidget {
  const DesktopChatWindow({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(conv.conversationsProvider)
        .when(
          data: (conversations) {
            final conversation = conversations
                .where((candidate) => candidate.id == conversationId)
                .firstOrNull;
            if (conversation == null) {
              return const _MissingConversationState();
            }
            return ProviderScope(
              // A window keeps one session per conversation; a different
              // conversation in the same slot gets a fresh notifier.
              key: ValueKey(conversation.id),
              overrides: [
                chatProvider.overrideWith(
                  () => ChatNotifier(resumeLastChat: false),
                ),
                // Every piece of app-wide chat state this window's screen can
                // touch is scoped, so a window never changes the main chat.
                conv.activeConversationIdProvider.overrideWith(
                  () => _FixedActiveConversationIdNotifier(conversation.id),
                ),
                conv.activeConversationProvider.overrideWith(
                  () => _FixedActiveConversationNotifier(conversation),
                ),
                activeGenerationsProvider.overrideWith(
                  ActiveGenerationsNotifier.new,
                ),
                isStreamingProvider.overrideWith(IsStreamingNotifier.new),
                chatMcpConfigProvider.overrideWith(ChatMcpConfigNotifier.new),
              ],
              child: _ConversationLoader(conversation: conversation),
            );
          },
          loading: () =>
              const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          error: (error, stackTrace) => const _MissingConversationState(),
        );
  }
}

/// Loads the window's conversation into its own [ChatNotifier] once.
class _ConversationLoader extends ConsumerStatefulWidget {
  const _ConversationLoader({required this.conversation});

  final Conversation conversation;

  @override
  ConsumerState<_ConversationLoader> createState() =>
      _ConversationLoaderState();
}

class _ConversationLoaderState extends ConsumerState<_ConversationLoader> {
  String? _loadedConversationId;
  bool _isReady = false;
  bool _hasFailed = false;

  @override
  void initState() {
    super.initState();
    _scheduleLoad();
  }

  @override
  void didUpdateWidget(covariant _ConversationLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_loadedConversationId != widget.conversation.id) {
      _isReady = false;
      _hasFailed = false;
      _scheduleLoad();
    }
  }

  void _scheduleLoad() {
    final id = widget.conversation.id;
    if (_loadedConversationId == id) return;
    _loadedConversationId = id;
    // Provider state can't be written while the tree is building, so the load
    // starts after the first frame. `activate: false` keeps the app-wide active
    // conversation untouched: opening a second window must not steal the first
    // one's active chat.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      var failed = false;
      try {
        await ref
            .read(chatProvider.notifier)
            .loadConversation(widget.conversation, activate: false);
      } catch (_) {
        failed = true;
      } finally {
        if (mounted) {
          setState(() {
            _hasFailed = failed;
            _isReady = true;
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_hasFailed) {
      return const _MissingConversationState();
    }
    return const ChatScreen();
  }
}

/// The window's active conversation id, fixed to the one it was opened for.
class _FixedActiveConversationIdNotifier
    extends conv.ActiveConversationIdNotifier {
  _FixedActiveConversationIdNotifier(this.conversationId);

  final String conversationId;

  @override
  String? build() => conversationId;

  @override
  void setActiveConversation(Conversation? conversation) {
    // Window-side loads and new chats stay inside this scope.
    state = conversation?.id;
  }

  @override
  void setActiveConversationId(String? id) {
    state = id;
  }
}

/// The window's active conversation, following its scoped active id.
class _FixedActiveConversationNotifier extends conv.ActiveConversationNotifier {
  _FixedActiveConversationNotifier(this.conversation);

  final Conversation conversation;

  @override
  Conversation? build() {
    final id = ref.watch(conv.activeConversationIdProvider);
    if (id == null) return null;
    final conversations =
        ref.watch(conv.conversationsProvider).value ?? const [];
    return conversations.where((candidate) => candidate.id == id).firstOrNull;
  }

  @override
  void setActiveConversation(Conversation? conversation) {
    // The scoped id notifier absorbs the change; the global active
    // conversation belongs to whichever window the user last worked in.
    ref
        .read(conv.activeConversationIdProvider.notifier)
        .setActiveConversation(conversation);
    state = conversation;
  }
}

class _MissingConversationState extends StatelessWidget {
  const _MissingConversationState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return Center(
      key: const ValueKey('desktop-chat-missing'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HugeIcon(
            icon: HugeIcons.strokeRoundedAiChat01,
            size: 32,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.history_missing_title,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// The LM Studio model browser for the active server.
///
/// The browser needs a server, which the router used to pass as `extra`. A window
/// keeps no extra after a relaunch, so it falls back to the active server.
class _DesktopLmStudioBrowser extends ConsumerWidget {
  const _DesktopLmStudioBrowser();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(activeServerProvider);
    if (server == null || server.type != ServerType.lmStudio) {
      return const SizedBox.shrink();
    }
    return LmStudioModelBrowserScreen(server: server);
  }
}

/// How many of the most recent conversations the palette lists.
const int _recentDesktopConversations = 8;

/// The most recent conversations as command-palette commands.
///
/// The desktop feature does not import conversations, so the app builds these
/// commands and the palette only lists them.
List<DesktopCommand> _desktopConversationCommands(WidgetRef ref) {
  final conversations = ref.watch(conv.conversationsProvider).value ?? const [];
  return [
    for (final conversation in conversations.take(_recentDesktopConversations))
      DesktopCommand(
        id: '${DesktopCommand.conversationPrefix}${conversation.id}',
        label: conversation.title,
        kind: DesktopWindowKind.chat,
      ),
  ];
}
