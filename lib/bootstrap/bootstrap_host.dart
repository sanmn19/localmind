import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show FlutterLocalNotificationsPlugin, NotificationResponse;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../core/providers/app_providers.dart';
import '../core/providers/highlighter_provider.dart';
import '../core/providers/storage_providers.dart';
import '../core/storage/objectbox_store.dart';
import '../core/widgets/screen_memory_lifecycle_host.dart';
import '../features/on_device/data/on_device_gemma_service.dart';
import '../features/on_device/providers/on_device_providers.dart';
import '../core/models/enums.dart';
import '../core/routes/app_routes.dart';
import '../features/personas/providers/personas_providers.dart';
import '../features/servers/data/models/server.dart';
import '../features/servers/providers/server_providers.dart';
import '../features/chat/data/background_engine.dart';
import '../features/chat/providers/tooling_providers.dart';
import '../features/chat/utils/message_variants.dart';
import '../features/conversations/providers/conversation_providers.dart'
    as conv;
import '../features/skills/data/skills_provider.dart';
import '../features/cloud_sync/views/cloud_sync_lifecycle_host.dart';
import '../core/logger/app_logger.dart';
import '../core/utils/locale_utils.dart';
import '../features/ask_local/data/ask_local_main_channel.dart';
import '../objectbox.g.dart';
import 'bootstrap_screen.dart';
import 'bootstrap_state.dart';
import 'safe_riverpod_scope_host.dart';

class BootstrapHost extends StatefulWidget {
  const BootstrapHost({super.key});

  @override
  State<BootstrapHost> createState() => _BootstrapHostState();
}

class _BootstrapHostState extends State<BootstrapHost> {
  BootstrapState _state = const BootstrapState();
  ProviderContainer? _container;
  Locale? _savedLocale;

  @override
  void initState() {
    super.initState();
    _runBootstrap();
  }

  Future<void> _runBootstrap() async {
    _updateStage(BootstrapStage.initializing, 'Initializing...');

    try {
      final results = await Future.wait([
        initializeHighlighter(),
        SharedPreferences.getInstance(),
        ObjectBoxStore.create(),
      ]);

      final prefs = results[1] as SharedPreferences;
      final database = results[2] as ObjectBoxStore;

      // Seed built-in personas once before any provider reads the database.
      PersonasNotifier.seedIfNeeded(database);

      _updateStage(BootstrapStage.preparingApp, 'Preparing app...');

      try {
        final settingsJson = prefs.getString('appSettings');
        if (settingsJson != null) {
          final settings = json.decode(settingsJson) as Map<String, dynamic>;
          final code = settings['localeCode'] as String?;
          _savedLocale = parseLocaleCode(code);
        }
      } catch (_) {}

      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(database),
        ],
      );

      _updateStage(
        BootstrapStage.initializingServices,
        'Initializing services...',
      );

      final hfToken = container.read(
        settingsProvider.select((s) => s.huggingFaceToken),
      );
      await OnDeviceGemmaService.initialize(huggingFaceToken: hfToken);

      // Migrate models from old custom download location in background to prevent cold start ANR
      OnDeviceGemmaService.migrateOldModels().catchError((e) {
        Log.error('Error migrating old models: $e');
        return 0;
      });

      _updateStage(BootstrapStage.configuringServer, 'Configuring server...');
      final servers = await container.read(serversProvider.future);
      final hasOnDevice = servers.any(
        (s) => s.type == ServerType.onDevice || s.id == 'on-device',
      );
      if (!hasOnDevice) {
        final server = Server(
          id: 'on-device',
          name: 'On-Device',
          type: ServerType.onDevice,
          host: '',
          port: 0,
          isDefault: false,
          createdAt: DateTime.now(),
          lastConnectedAt: DateTime.now(),
          status: ConnectionStatus.connected,
          iconName: 'strokeRoundedSmartPhone01',
        );
        await container.read(serversProvider.notifier).addServer(server);
      }

      // Eagerly resolve foundational state providers so their initial state
      // is stable before UncontrolledProviderScope mounts the widget tree.
      container.read(settingsProvider);
      container.read(activeServerIdProvider);
      container.read(activeServerProvider);
      container.read(connectionStatusProvider);
      container.read(onDeviceEngineProvider);

      // Skills load from the documents skills/ dir without blocking
      // startup; until the refresh resolves, request assembly just reads
      // the (empty) in-memory mirror. Failures are logged, not fatal.
      unawaited(
        container.read(skillsProvider.notifier).refresh().catchError((
          Object e,
          StackTrace s,
        ) {
          Log.error('Failed to load skills: $e');
          Log.error('$s');
        }),
      );

      // Background sub-agent loops resume without blocking startup (only
      // affects persisted running rows; backgroundTasksEnabled off → no-op).
      container.read(backgroundResumeProvider);

      // Background result notifications route taps into the owning chat
      // (review I3): non-blocking registration, house pattern of the
      // skills refresh above.
      _registerBackgroundResultRouting();

      // The ask-local MAIN half: Kotlin's staging pushes, the pending pull
      // and the card engine's execute-tool forwards land here once the
      // live app container exists (a snapshot envelope is resolved
      // MAIN-side, so the card receives every field at overlay-open).
      _installAskLocalMainChannel(container);

      _container = container;
      _updateStage(BootstrapStage.done, 'Ready');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_handleNotificationLaunch());
      });
    } catch (e) {
      _state = BootstrapState(
        stage: BootstrapStage.error,
        statusMessage: 'Startup failed',
        error: e,
      );
      if (mounted) setState(() {});
    }
  }

  void _updateStage(BootstrapStage stage, String message) {
    if (!mounted) return;
    setState(() {
      _state = BootstrapState(stage: stage, statusMessage: message);
    });
  }

  /// Registers the local-notification tap routing for background task
  /// result payloads (review I3). Ours-only by prefix; foreign payloads are
  /// ignored so other notification producers stay unaffected.
  void _registerBackgroundResultRouting() {
    BackgroundResultNotifier.onNotificationTap =
        (NotificationResponse response) {
      final ownerId = BgNotificationPayload.tryParse(response.payload);
      if (ownerId == null) return;
      unawaited(_openOwnerChatForBgResult(ownerId));
    };
  }

  /// A tap that launches the app from a terminated state arrives through the
  /// plugin's launch details instead of the live callback. Route it through the same
  /// owner-chat opener.
  Future<void> _handleNotificationLaunch() async {
    try {
      final details = await FlutterLocalNotificationsPlugin()
          .getNotificationAppLaunchDetails();
      final ownerId = BgNotificationPayload.tryParse(
        details?.notificationResponse?.payload,
      );
      if (ownerId != null) await _openOwnerChatForBgResult(ownerId);
    } catch (error) {
      Log.warning('Notification launch routing failed: $error');
    }
  }

  /// Opens the owner conversation and scrolls to the active timeline's LAST
  /// row — by contract that is the delivered background result row (the same
  /// resolver the engine anchors with). v1: set active id + scroll target.
  Future<void> _openOwnerChatForBgResult(String ownerId) async {
    final container = _container;
    if (container == null) return;
    final db = container.read(databaseProvider);

    final convQuery = db.conversationBox
        .query(ConversationEntity_.id.equals(ownerId))
        .build();
    final exists = convQuery.findFirst() != null;
    convQuery.close();
    if (!exists) return;

    container
        .read(conv.activeConversationIdProvider.notifier)
        .setActiveConversationId(ownerId);
    try {
      container.read(routerProvider).go(AppRoutes.home);
    } catch (_) {
      // The router may not be mounted yet on a cold start; the active id is
      // already set, so the home screen opens the right chat once it mounts.
    }

    final rows = db.messageBox
        .query(MessageEntity_.conversationUid.equals(ownerId))
        .build()
        .find()
        .map((entity) => entity.toDomain())
        .toList()
      ..sort((a, b) {
        final order = a.threadOrder.compareTo(b.threadOrder);
        if (order != 0) return order;
        return a.createdAt.compareTo(b.createdAt);
      });
    final timeline = MessageVariants.resolveActiveTimeline(rows);
    if (timeline.isNotEmpty) {
      container
          .read(conv.scrollToMessageIdProvider.notifier)
          .scrollTo(timeline.last.id);
    }
  }

  /// Ask-local channel seam for unit tests (null = production installer).
  @visibleForTesting
  static void Function(ProviderContainer container)? askLocalChannelInstaller;

  void _installAskLocalMainChannel(ProviderContainer container) {
    final installer = askLocalChannelInstaller;
    if (installer != null) {
      installer(container);
    } else {
      AskLocalMainChannel.install(container);
    }
  }

  @override
  void dispose() {
    AskLocalMainChannel.uninstall();
    _container?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_container != null) {
      return UncontrolledProviderScope(
        container: _container!,
        child: SafeRiverpodScopeHost(
          container: _container!,
          child: const ScreenMemoryLifecycleHost(
            child: CloudSyncLifecycleHost(child: App()),
          ),
        ),
      );
    }

    return BootstrapScreen(
      state: _state,
      locale: _savedLocale,
      onRetry: _state.stage == BootstrapStage.error ? _runBootstrap : null,
    );
  }
}
