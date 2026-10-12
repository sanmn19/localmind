import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../../../core/logger/app_logger.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/storage_providers.dart';
import '../../../core/services/device_tools_service.dart';
import '../../../core/storage/entities.dart';
import '../../../core/storage/objectbox_store.dart';
import '../../../objectbox.g.dart';
import '../data/chat_service.dart';
import '../data/background_engine.dart';
import '../data/background_runner.dart';
import '../data/tools/tool_registry.dart';
import '../data/tools/builtin_tool_provider.dart';
import '../data/tools/mcp_tool_provider.dart';
import '../data/tools/tool_definition.dart';
import '../data/mcp_server_manager.dart';
import '../data/background_task_service.dart';
import '../data/models/background_task.dart';
import '../data/models/message.dart';
import 'package:localmind/features/mail/data/google_auth_client.dart';
import 'package:localmind/features/mail/data/gmail_repository.dart';
import 'package:localmind/features/mail/data/imap_repository.dart';
import 'package:localmind/features/mail/data/mail_connector_config.dart';
import 'package:localmind/features/mail/data/mail_common.dart';
import 'package:localmind/features/mail/data/mail_token_store.dart';
import 'package:localmind/features/mail/data/outlook_auth_client.dart';
import 'package:localmind/features/mail/data/outlook_repository.dart';
import 'package:localmind/features/mail/mail_mcp_server.dart';
import 'package:dio/dio.dart';
import '../data/tool_budget.dart';
import '../../mcp/data/device_contacts_repository.dart';
import '../../mcp/data/device_mcp_server.dart';
import '../../mcp/data/terminal_mcp_server.dart';
import '../../mcp/data/web/keyless_mcp_ring.dart';
import '../../mcp/data/web/web_fetch_service.dart';
import '../../mcp/data/web/web_search_service.dart';
import '../../skills/data/skills_mcp_server.dart';
import '../../skills/data/skills_provider.dart';
import '../../skills/data/skills_store.dart';
import '../../notifications/notifications_listener_channel.dart';
import '../../notifications/notifications_mcp_server.dart';
import 'package:localmind/features/conversations/providers/conversation_providers.dart';
import 'chat_params_providers.dart';
import 'model_selection_providers.dart';

/// Per-turn web-tool budgets, owning state in the notifier's tool path.
/// One instance per app session: consecutive tool rounds of a reply SHARE
/// a budget via the chain token (variantGroupId), and nothing needs
/// disposing — the plain instance dies with this provider.
final webToolBudgetProvider = Provider<WebToolBudget>((ref) {
  return WebToolBudget();
});

final mcpServerManagerProvider = Provider<McpServerManager>((ref) {
  final packageInfo = ref.watch(packageInfoProvider);
  return McpServerManager(appVersion: packageInfo.value?.version ?? '1.0.0');
});

final builtInToolProviderProvider = Provider<BuiltInToolProvider>((ref) {
  final settings = ref.watch(settingsProvider);
  return BuiltInToolProvider(
    calendarToolsEnabled: settings.calendarToolsEnabled,
    locationToolsEnabled: settings.locationToolsEnabled,
  );
});

final toolRegistryProvider = Provider<ToolRegistry>((ref) {
  final mcpServerManager = ref.watch(mcpServerManagerProvider);
  return ToolRegistry(
    providers: [
      ref.watch(builtInToolProviderProvider),
      McpToolProvider(serverManager: mcpServerManager),
    ],
  );
});

final availableToolsProvider = FutureProvider<List<ToolDefinition>>((
  ref,
) async {
  final registry = ref.watch(toolRegistryProvider);
  return registry.listTools();
});

Future<bool> shouldAutoApproveTool(
  String toolName, {
  Map<String, dynamic> args = const {},
  required bool webToolsEnabled,
  required bool terminalToolsEnabled,
  bool deviceToolsEnabled = false,
  bool mailAccountsConnected = false,
  bool skillsEnabled = false,
  bool backgroundTasksEnabled = false,
  bool notificationToolsEnabled = false,
  required ToolRegistry registry,
  required TerminalWhitelist? whitelist,
}) async {
  if (toolName == 'calc.add' || toolName == 'calc.multiply') return true;

  if (await registry.isLocalTool(toolName, {webMcpServerUrl})) {
    return webToolsEnabled;
  }

  if (await registry.isLocalTool(toolName, {deviceMcpServerUrl})) {
    // The whole apps.*/contacts.* surface auto-runs while locally owned:
    // every tool ends in the OS itself (mail app review, launcher, contact
    // read-only look-up), so the toggle — not a per-tool whitelist — gates.
    return deviceToolsEnabled;
  }

  if (await registry.isLocalTool(toolName, {mailMcpServerUrl})) {
    if (toolName == 'mail.send') return false;
    return mailAccountsConnected && toolName.startsWith('mail.');
  }

  if (await registry.isLocalTool(toolName, {terminalMcpServerUrl})) {
    if (!terminalToolsEnabled) return false;
    switch (toolName) {
      case 'net.http':
        return whitelist?.allowsTool(
              TerminalWhitelist.whitelistOnlyToolEntry,
            ) ??
            false;
      case 'terminal.run':
        final command = args['command'] is String
            ? args['command']! as String
            : '';
        return whitelist?.allows(command) ?? false;
      default:
        return false;
    }
  }

  if (await registry.isLocalTool(toolName, {skillsMcpServerUrl})) {
    // Reads (list + on-demand body loads) ride the standard local-server
    // bypass. Writes NEVER auto-approve: adding or deleting skills from
    // chat always goes through the approval dialog, whatever the toggle
    // says — the user must see it happen.
    if (toolName == 'skills.list' || toolName == 'skills.read') {
      return skillsEnabled;
    }
    return false;
  }

  if (await registry.isLocalTool(toolName, {bgMcpServerUrl})) {
    // bg.spawn NEVER auto-approves: standing up an autonomous scheduled
    // thread always crosses the approval dialog, whatever the toggle says
    // (mail.send precedent). The read/status surface and the cancel relay
    // ride the toggle, like web/terminal reads.
    if (toolName == 'bg.spawn') return false;
    return backgroundTasksEnabled;
  }

  if (await registry.isLocalTool(toolName, {notificationsMcpServerUrl})) {
    // notifications.read_recent is read-only observation of the current
    // session's ring, so it rides its toggle like web/terminal reads — no
    // per-tool whitelist needed.
    return notificationToolsEnabled;
  }

  return false;
}

WebSearchProvider webSearchProviderFromName(String name) {
  switch (name) {
    case 'tavily':
      return WebSearchProvider.tavily;
    case 'brave':
      return WebSearchProvider.brave;
    case 'serper':
      return WebSearchProvider.serper;
    case 'searxng':
      return WebSearchProvider.searxng;
    case 'ring':
      return WebSearchProvider.keylessRing;
    case 'auto':
      return WebSearchProvider.auto;
    default:
      return WebSearchProvider.ddgLite;
  }
}

/// Keeps the in-process local MCP servers in step with their settings.
///
/// A [Provider] only runs while it is being watched, so a UI surface that
/// should keep the web, terminal AND skills servers in sync MUST watch this
/// provider: `ref.watch(webServerRegistrationProvider);` (used by the MCP
/// tools screen). Rebuilds on any settings change and (de)registers the
/// `web.search` / `web.fetch` server, the `terminal.run` / `net.http`
/// server and the `skills.list` / `skills.add` / `skills.delete` server
/// accordingly. The historical provider/web-host names are kept even though
/// this now covers all local servers (cosmetic only).
final webServerRegistrationProvider = Provider<void>((ref) {
  final settings = ref.watch(settingsProvider);
  final manager = ref.watch(mcpServerManagerProvider);
  if (settings.webToolsEnabled) {
    // One ring per registration: search and fetch share session/cursor state
    // so an exa fetch rescue reuses the session a prior search established.
    final ring = KeylessMcpRing();
    manager.addWebServer(
      WebServices(
        search: WebSearchService(
          provider: webSearchProviderFromName(settings.webSearchProvider),
          apiKey: settings.webSearchApiKey,
          searxUrl: settings.webSearxUrl,
          ring: ring,
        ),
        fetch: WebFetchService(fallbackRing: ring),
      ),
    );
  } else if (manager.hasWebServer()) {
    manager.removeServer(webMcpServerLabel);
  }
  if (settings.terminalToolsEnabled) {
    // Fresh services each rebuild — a whitelist edit re-registers the
    // server so the approval layer sees the current entries immediately.
    manager.addTerminalServer(
      TerminalServices(
        runner: const ShellProcessRunner(),
        http: NetHttpTool(),
        whitelist: TerminalWhitelist(settings.toolWhitelist),
      ),
    );
  } else if (manager.hasTerminalServer()) {
    manager.removeServer(terminalMcpServerLabel);
  }
  if (settings.skillsEnabled) {
    // ASYMMETRY (by design): the registration only re-runs on a SETTINGS
    // change, but the write tools bridge straight into the skills provider —
    // every store write is followed by SkillsNotifier.refresh(), so the
    // next chat request's system-builder picks model-added skills up
    // mid-conversation without waiting for a re-registration.
    manager.addSkillsServer(
      SkillsServices(
        list: () => SkillsStore(ref.read(skillsFileHostProvider)).refresh(),
        add: (name, description, content) async {
          final store = SkillsStore(ref.read(skillsFileHostProvider));
          await store.add(
            SkillEntry(name: name, description: description, body: content),
          );
          await ref.read(skillsProvider.notifier).refresh();
        },
        delete: (name) async {
          await SkillsStore(ref.read(skillsFileHostProvider)).delete(name);
          await ref.read(skillsProvider.notifier).refresh();
        },
        enabled: () => ref.read(settingsProvider).skillsEnabled,
      ),
    );
  } else if (manager.hasSkillsServer()) {
    manager.removeServer(skillsMcpServerLabel);
  }
  if (settings.deviceToolsEnabled) {
    // Launcher calls ride the method channel; contacts read straight from
    // the flutter_contacts plugin with the READ_CONTACTS runtime permission
    // gated inside the repository (Task 2 filled the native handlers,
    // Task 3 swapped contacts to the real repository).
    manager.addDeviceServer(
      DeviceServices(
        contacts: const DeviceContactsRepository(),
        launcher: const MethodChannelDeviceAppLauncher(),
        screenshot: const MethodChannelDeviceScreenshotService(),
      ),
    );
  } else if (manager.hasDeviceServer()) {
    manager.removeServer(deviceMcpServerLabel);
  }
  if (settings.backgroundTasksEnabled) {
    // The spawn orchestration lives HERE (riverpod context): the hidden
    // task conversation rides the same create path as normal chats, stamped
    // isBackground at creation (fork stamp parity), the task row goes through
    // BackgroundTasksService.createTask (cap enforced there), and the run
    // request relays through the v1 no-op `runRequester` (Task 4 wires the
    // engine loop to this seam).
    final service = ref.watch(backgroundTasksServiceProvider);
    manager.addBackgroundServer(
      BackgroundServices(
        currentOwnerConversationId: () =>
            ref.read(activeConversationIdProvider),
        spawn: ({required String ownerConversationId, required String prompt,
              int? loopMinutes, int? maxRuns}) {
          return _spawnBackgroundTask(
            ref,
            service,
            ownerConversationId: ownerConversationId,
            prompt: prompt,
            loopMinutes: loopMinutes,
            maxRuns: maxRuns,
          );
        },
        tasksFor: (ownerConversationId) => ref
            .read(backgroundTasksServiceProvider)
            .tasksFor(ownerConversationId),
        cancelTask: (taskId) => ref
            .read(backgroundTasksServiceProvider)
            .cancelTask(taskId),
        runRequester: (taskId) {
          // Bridge to the live engine (cap enforced DB-side by createTask;
          // the engine's own guard covers direct relays).
          try {
            unawaited(_ensureTaskRunning(ref, taskId));
          } catch (error) {
            Log.error('Background run request failed: $error');
          }
        },
      ),
    );
  } else if (manager.hasBackgroundServer()) {
    manager.removeServer(bgMcpServerLabel);
  }
  if (settings.notificationToolsEnabled) {
    // Fresh services each rebuild; the channel closure resolves the
    // listener's LIVE grant/ring at call time (the grant can change
    // mid-session), and the fetch filter is applied DART-side per the
    // tool's arguments. Tool-side clamping happens in the manager.
    manager.addNotificationsServer(
      NotificationsServices(
        recent: ({int? max, int? sinceMinutes, String? package}) =>
            const NotificationListenerChannel().fetchRecent(
          max: max ?? notificationsReadRecentMaxDefault,
          sinceMinutes: sinceMinutes,
          package: package,
        ),
      ),
    );
  } else if (manager.hasNotificationsServer()) {
    manager.removeServer(notificationsMcpServerLabel);
  }
  // Mail connectors register from the connected accounts list (provider +
  // email rows) — the connected toggle lives with the account, and each
  // repository owns the token gateway for its account. Only rows that
  // actually identify an account produce a repository; an imap row is the
  // e-mail + app-password connector (password read from the token store).
  if (settings.mailConnectorAccounts.isNotEmpty) {
    final store = ref.watch(mailTokenStoreProvider);
    final accounts = settings.mailConnectorAccounts.map(MailAccount.fromMap);
    final gmailAccount = accounts
        .firstWhere(
          (account) => account.provider == MailProvider.gmail,
          orElse: () =>
              const MailAccount(provider: MailProvider.gmail, email: ''),
        )
        .email;
    final outlookAccount = accounts
        .firstWhere(
          (account) => account.provider == MailProvider.outlook,
          orElse: () => MailAccount(provider: MailProvider.outlook, email: ''),
        )
        .email;
    final imapRow = settings.mailConnectorAccounts.firstWhere(
      (row) => row['provider']?.toString() == MailProviderName.imap,
      orElse: () => const <String, dynamic>{'provider': 'imap', 'email': ''},
    );
    final imapHost = imapRow['host']?.toString();
    manager.addMailServer(
      MailServices(
        gmail: gmailAccount.isEmpty
            ? null
            : GmailRepository(
                accountEmail: gmailAccount,
                dio: Dio(),
                tokens: store,
                gateway: GoogleMailAuthGateway(
                  serverClientId:
                      MailConnectorConfig.googleServerClientId.isEmpty
                      ? null
                      : MailConnectorConfig.googleServerClientId,
                ),
              ),
        outlook: outlookAccount.isEmpty
            ? null
            : OutlookRepository(
                accountEmail: outlookAccount,
                dio: Dio(),
                tokens: store,
                gateway: MsalOutlookAuthGateway(
                  clientId: MailConnectorConfig.outlookClientId,
                  tokens: store,
                ),
              ),
        imap: imapRow['email']?.toString().isEmpty == false
            ? ImapRepository(
                accountEmail: imapRow['email']!.toString(),
                tokens: store,
                hostOverride: (imapHost == null || imapHost.isEmpty)
                    ? null
                    : imapHost,
              )
            : null,
      ),
    );
  } else if (manager.hasMailServer()) {
    manager.removeServer(mailMcpServerLabel);
  }
  ref.onDispose(() {
    if (manager.hasWebServer()) {
      // Not awaited — teardown best-effort.
      manager.removeServer(webMcpServerLabel);
    }
    if (manager.hasTerminalServer()) {
      manager.removeServer(terminalMcpServerLabel);
    }
    if (manager.hasSkillsServer()) {
      manager.removeServer(skillsMcpServerLabel);
    }
    if (manager.hasDeviceServer()) {
      manager.removeServer(deviceMcpServerLabel);
    }
    if (manager.hasBackgroundServer()) {
      manager.removeServer(bgMcpServerLabel);
    }
    if (manager.hasNotificationsServer()) {
      manager.removeServer(notificationsMcpServerLabel);
    }
  });
});

/// The bg.spawn orchestration (registration-side closure): create the
/// hidden `isBackground` task conversation off the shared create path, seed
/// the task row through [BackgroundTasksService.createTask] (the engine cap
/// is enforced there), and return the task for the dispatch's run-request
/// relay. A cap refusal must not leave the freshly minted hidden
/// conversation dangling — it is deleted again on the way out.
Future<BackgroundTask> _spawnBackgroundTask(
  Ref ref,
  BackgroundTasksService service, {
  required String ownerConversationId,
  required String prompt,
  int? loopMinutes,
  int? maxRuns,
}) async {
  final conversations = ref.read(conversationsProvider.notifier);
  final taskConversation = await conversations.createConversation(
    title: backgroundSpawnTitle(prompt),
    isBackground: true,
  );
  try {
    return await service.createTask(
      ownerConversationId: ownerConversationId,
      prompt: prompt,
      loopMinutes: loopMinutes,
      maxRuns: maxRuns,
      taskConversationId: taskConversation.id,
    );
  } catch (error) {
    await conversations.deleteConversation(taskConversation.id);
    rethrow;
  }
}

/// `BG: <prompt-32>` — the hidden task thread's title (same flattened
/// prompt the task row stores, truncated once at creation), where
/// `<prompt-32>` stands for the first 32 chars of the flattened prompt.
String backgroundSpawnTitle(String prompt) {
  final flattened = prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
  final head = flattened.length <= 32
      ? flattened
      : '${flattened.substring(0, 32)}…';
  return 'BG: $head';
}

/// One rendered row of the Background card: a task plus the display title
/// of the conversation that owns it.
class BackgroundTaskRow {
  const BackgroundTaskRow({required this.task, required this.ownerTitle});

  final BackgroundTask task;
  final String ownerTitle;
}

/// Background-card rows: every task owned by a conversation in the
/// conversations state, oldest first per owner. Riding the conversations
/// state means delete cascades re-render the card automatically; the
/// dispatch + card invalidate this provider after writes (cancel/spawn).
final backgroundTaskRowsProvider = FutureProvider<List<BackgroundTaskRow>>((
  ref,
) async {
  final conversations = ref.watch(conversationsProvider).value;
  final service = ref.watch(backgroundTasksServiceProvider);
  if (conversations == null || conversations.isEmpty) return const [];
  final rows = <BackgroundTaskRow>[];
  for (final conversation in conversations) {
    for (final task in await service.tasksFor(conversation.id)) {
      rows.add(BackgroundTaskRow(task: task, ownerTitle: conversation.title));
    }
  }
  return rows;
});

/// The LIVE [BackgroundRunEngine] for chat-owned background sub-agent tasks.
///
/// Runs turns IN the main isolate; the Android foreground service's job is to
/// keep the process alive while minimized so the driver's sleep/wake keeps
/// ticking. Engine deps resolve against the CURRENT provider state at call
/// time (fresh target/tool snapshot per run); the engine instance is
/// keep-alive for the session.
final backgroundEngineProvider = Provider<BackgroundRunEngine>((ref) {
  final service = ref.read(backgroundTasksServiceProvider);

  final engine = BackgroundRunEngine(
    taskById: service.taskById,
    runningTasks: service.runningTasks,
    recordRun: service.recordRun,
    markFinished: (taskId, {resultMessageId, ownerMessageId}) =>
        service.markFinished(
          taskId,
          resultMessageId: resultMessageId,
          ownerMessageId: ownerMessageId,
        ),
    markFailed: service.markFailed,
    conversationExists: (conversationId) => _conversationExists(
      ref.read(databaseProvider),
      conversationId,
    ),
    conversationTitle: (conversationId) => _conversationTitle(
      ref.read(databaseProvider),
      conversationId,
    ),
    buildRunSnapshot: () => _backgroundRunSnapshot(ref),
    loadRows: (conversationId) =>
        _backgroundRows(ref.read(databaseProvider), conversationId),
    persistRow: (row) =>
        _persistBackgroundRow(ref.read(databaseProvider), row),
    executeTool: (name, args) =>
        ref.read(toolRegistryProvider).execute(name, args),
    chatServiceFor: (server) => ChatService.forServer(server.type, Dio()),
    notifyResult: (ownerTitle, task, content) =>
        BackgroundResultNotifier().post(
      ownerTitle: ownerTitle,
      task: task,
      content: content,
    ),
    onEngineTouched: () {
      if (ref.mounted) ref.invalidate(backgroundTaskRowsProvider);
    },
  );

  service.attachCancelRequester((taskId) {
    engine.cancelRunsFor(taskId);
  });
  ref.onDispose(() {
    service.attachCancelRequester((taskId) {});
    engine.dispose();
  });

  return engine;
});

/// Runs the still-running background task loops after an app restart.
final backgroundResumeProvider = Provider<void>((ref) {
  final service = ref.read(backgroundTasksServiceProvider);
  Future<void> resume() async {
    if (!ref.read(settingsProvider).backgroundTasksEnabled) return;
    if (await service.runningCount() == 0) return;
    try {
      await startBackgroundKeepAliveService();
    } catch (error) {
      Log.error('Background keep-alive service start failed: $error');
    }
    // The engine runs in this isolate; resume loops directly.
    unawaited(ref.read(backgroundEngineProvider).resumePending());
  }

  // Bookkeeping after the first frame so conversation state exists.
  unawaited(Future<void>.delayed(const Duration(seconds: 2), resume));
});

/// Starts the Android foreground-service keep-alive (flutter_background_);
/// throw-suppressed for host tests / unsupported platforms.
Future<void> startBackgroundKeepAliveService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onBackgroundServiceKeepAlive,
      isForegroundMode: true,
      autoStart: false,
      notificationChannelId: localmindFgServiceChannelId,
      initialNotificationTitle: 'LocalMind',
      initialNotificationContent: 'Background tasks running',
      foregroundServiceNotificationId: 0xb6c0ffee,
      autoStartOnBoot: false,
    ),
    iosConfiguration: IosConfiguration(),
  );
  await service.startService();
}

/// Restarts the Android keep-alive notification (host tests / unsupported
/// platforms swallow the plugin-channel failure).
@pragma('vm:entry-point')
Future<void> onBackgroundServiceKeepAlive(ServiceInstance service) async {
  // The engine keeps running in the MAIN isolate; this service isolate only
  // holds the foreground notification (process-alive), so it stays inert.
}

/// Bridges a spawn relay into the engine; saturation is a logged refusal
/// (createTask already enforces the DB-level cap).
Future<void> _ensureTaskRunning(Ref ref, String taskId) async {
  try {
    ref.read(backgroundEngineProvider).requestRun(taskId);
  } on StateError catch (error) {
    Log.error('Background engine refuses task $taskId: $error');
  }
}

Future<bool> _conversationExists(ObjectBoxStore db, String conversationId) {
  final query = db.conversationBox
      .query(ConversationEntity_.id.equals(conversationId))
      .build();
  final count = query.count();
  query.close();
  return Future.value(count > 0);
}

Future<String?> _conversationTitle(ObjectBoxStore db, String conversationId) {
  final query = db.conversationBox
      .query(ConversationEntity_.id.equals(conversationId))
      .build();
  final rows = query.find();
  query.close();
  return Future.value(rows.isEmpty ? null : rows.first.title);
}

/// The auto-approvable toolset a background snapshot exposes: evaluated per
/// tool with the CURRENT flags, then structurally minus bg.*/notifications.*
/// (children never spawn further tasks or harvest notifications).
Future<BackgroundRunSnapshot> _backgroundRunSnapshot(Ref ref) async {
  final target = ref.read(activeChatTargetProvider);
  final server = target.server;
  final modelId = target.effectiveModelId;
  if (server == null || modelId == null) {
    throw StateError('No ready model target for background sub-agent runs.');
  }
  final settings = ref.read(settingsProvider);
  final registry = ref.read(toolRegistryProvider);
  final whitelist = settings.toolWhitelist.isEmpty
      ? null
      : TerminalWhitelist(settings.toolWhitelist);
  final defs = <ToolDefinition>[];
  for (final def in await registry.listTools()) {
    if (bgNeverAvailableToolPrefixes.any(def.name.startsWith)) continue;
    final approved = await shouldAutoApproveTool(
      def.name,
      webToolsEnabled: settings.webToolsEnabled,
      terminalToolsEnabled: settings.terminalToolsEnabled,
      deviceToolsEnabled: settings.deviceToolsEnabled,
      mailAccountsConnected: settings.mailConnectorAccounts.isNotEmpty,
      skillsEnabled: settings.skillsEnabled,
      registry: registry,
      whitelist: whitelist,
    );
    if (approved) defs.add(def);
  }
  return BackgroundRunSnapshot(
    server: server,
    modelId: modelId,
    params: ref.read(chatParamsProvider),
    toolDefs: defs,
  );
}

Future<List<Message>> _backgroundRows(ObjectBoxStore db, String convId) {
  final rows = db.messageBox
      .query(MessageEntity_.conversationUid.equals(convId))
      .build()
      .find()
      .map((entity) => entity.toDomain())
      .toList()
    ..sort((a, b) {
      final order = a.threadOrder.compareTo(b.threadOrder);
      if (order != 0) return order;
      return a.createdAt.compareTo(b.createdAt);
    });
  return Future.value(rows);
}

Future<void> _persistBackgroundRow(ObjectBoxStore db, Message row) {
  db.messageBox.put(MessageEntity.fromDomain(row));
  return Future.value();
}
