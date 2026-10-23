import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/core/logger/app_logger.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/features/ask_local/ask_local_notifier.dart';
import 'package:localmind/features/ask_local/data/ask_local_card_bootstrap.dart';
import 'package:localmind/features/ask_local/data/ask_local_card_channel.dart';
import 'package:localmind/features/ask_local/data/ask_local_conversation_service.dart';
import 'package:localmind/features/chat/data/chat_service.dart';
import 'package:localmind/features/ask_local/views/ask_local_card.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/l10n/app_localizations.dart';

/// Ask Local card isolate boot (the overlay window's second engine
/// entrypoint, registered by AskLocalOverlayWindow with auto plugin
/// registration OFF).
///
/// Byte order:
/// 1. binding + the T3 placeholder surface (the window must show SOMETHING
///    on its first frame);
/// 2. EARLY channel wiring: the card-channel handler (Kotlin→Dart payload
///    pushes + closed events) registers BEFORE the first pull so a
///    re-delivery racing boot can never be missed;
/// 3. bounded initial-payload pull → the lite container over the
///    bootstrap snapshot (attached store + frozen settings + env closures)
///    → the real card surface replaces the placeholder;
/// 4. every later payload re-push (new ask while shown) flows through the
///    SAME applied channel callback into the live notifier (re-delivery
///    idempotent there).
@pragma('vm:entry-point')
void askLocalCardMain() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(_bootAskLocalCard());
}

Future<void> _bootAskLocalCard() async {
  final channel = AskLocalCardChannel();
  final director = CardBootDirector(channel: channel);
  channel.manage(
    (delivery) => unawaited(director.apply(delivery)),
    director.reapClosed,
  );
  runApp(const _AskLocalCardProgressPlaceholder());
  unawaited(director.injectInitial(channel));
}

/// The boot placeholder — T3's dialog-style progress surface kept verbatim
/// so the window never renders an empty frame before the card materialises.
class _AskLocalCardProgressPlaceholder extends StatelessWidget {
  const _AskLocalCardProgressPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          color: const Color(0xF2FAFAFA),
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.all(28),
        child: const CircularProgressIndicator(
          key: Key('ask_local_card_progress'),
          strokeWidth: 3,
        ),
      ),
    );
  }
}

/// Directors the card boot: ONE container per engine, built at most once
/// and always surfaced — a build throw keeps the placeholder up and swaps
/// in the typed boot-failure banner (the card's degraded-state pattern),
/// with the memoize re-armed so a later re-delivery can retry the build.
class CardBootDirector {
  CardBootDirector({
    required this.channel,
    this.attachAt,
    this.runAppHook,
  });

  final AskLocalCardChannel channel;

  /// Store-attach seam (defaults to
  /// [ObjectBoxStore.attachAsSecondaryIsolateAt]; tests inject fakes).
  final Future<ObjectBoxStore?> Function(String storeDir)? attachAt;

  /// Root-widget seam (defaults to [runApp]; tests count/inspect frames).
  final void Function(Widget app)? runAppHook;

  Future<ProviderContainer>? _booting;
  bool _failureUp = false;

  /// The container once built; null until [apply] built it successfully.
  ProviderContainer? get container => _container;
  ProviderContainer? _container;

  void _showApp(Widget app) {
    final hook = runAppHook;
    if (hook == null) {
      runApp(app);
    } else {
      hook(app);
    }
  }

  Future<void> injectInitial(AskLocalCardChannel channel) async {
    final delivery = await channel.requestInitialPayload();
    if (delivery != null) {
      await apply(delivery);
    }
  }

  Future<void> apply(AskLocalCardDelivery delivery) async {
    try {
      final container = await _containerFor(delivery.bootstrap);
      _failureUp = false;
      unawaited(
        container.read(askLocalCardNotifierProvider.notifier).applyDelivery(
              delivery,
            ),
      );
    } catch (error) {
      Log.error('Ask Local card boot failed: $error');
      _failBoot(error);
    }
  }

  void reapClosed() {
    _container?.read(askLocalCardNotifierProvider.notifier).reapClosed();
  }

  /// Race-safe memoized build: overlapping deliveries (initial pull vs a
  /// re-push racing boot) share the ONE container future; a failed build
  /// clears the memoize so a later re-delivery retries from scratch.
  Future<ProviderContainer> _containerFor(
    AskLocalCardBootstrapPayload? bootstrap,
  ) {
    final booting = _booting;
    if (booting != null) return booting;
    final future = _buildContainer(bootstrap);
    _booting = future;
    // Success keeps the memoize; a throw arms a retry and hands the typed
    // failure to [apply]'s catch (the future shape stays identical for
    // every waiter that shared it).
    future.then<int>((_) => 0, onError: (Object _) {
      if (identical(_booting, future)) _booting = null;
    });
    return future;
  }

  /// Lite container: attached store (bootstrap's storeDir), FROZEN settings
  /// (the envelope's full AppSettings snapshot; defaults when absent), env
  /// closures. NO shared_preferences/path_provider plugins are registered
  /// in this engine — the snapshot avoids them by construction.
  Future<ProviderContainer> _buildContainer(
    AskLocalCardBootstrapPayload? bootstrap,
  ) async {
    ObjectBoxStore? db;
    AppSettings settings = AppSettings();
    if (bootstrap != null) {
      // An envelope-carrying boot MUST land its store: a failed attach is a
      // boot failure (rethrown below through [apply]'s typed banner) — the
      // card would otherwise silently run with NO history persistence, which
      // is worse than an honest typed error + a retry on the next delivery.
      db = await (attachAt ?? ObjectBoxStore.attachAsSecondaryIsolateAt)
          .call(bootstrap.storeDir);
      try {
        if (bootstrap.settingsJson.isNotEmpty) {
          settings = AppSettings.fromJson(bootstrap.settingsJson);
        }
      } catch (error) {
        Log.error('Ask Local settings snapshot decode failed: $error');
      }
    }

    _container = ProviderContainer(
      overrides: [
        if (db != null) databaseProvider.overrideWithValue(db),
        settingsProvider.overrideWith(
          () => _FrozenCardSettingsNotifier(settings),
        ),
        askLocalCardEnvProvider.overrideWithValue(
          AskLocalCardEnv(
            conversationService: AskLocalConversationService(db),
            serviceFor: _cardChatServiceFor,
            remoteExecuteTool: (toolName, arguments) =>
                channel.executeTool(toolName, arguments),
            captureNow: () => channel.captureNow(),
            closeCard: () => channel.closeCard(),
            resizeCard: (heightDp) => channel.resizeFloatingCard(heightDp),
          ),
        ),
      ],
    );
    _showApp(UncontrolledProviderScope(
      container: _container!,
      child: const AskLocalCardApp(),
    ));
    return _container!;
  }

  /// Typed boot-failure surfacing: the placeholder surface stays as the
  /// window's base and the typed error banner replaces the card look ONCE
  /// per failure (repeated failing deliveries keep it without re-paints).
  void _failBoot(Object error) {
    if (_failureUp && _container == null) return;
    _failureUp = true;
    _showApp(_AskLocalCardBootFailure(error: error));
  }

  ChatService? _cardChatServiceFor(AskLocalCardBootstrapPayload bootstrap) {
    final server = bootstrap.server.toServer();
    if (server.isOnDevice) {
      return null;
    }
    return ChatService.forServer(server.type, Dio());
  }
}

/// Boot-failure frame: the placeholder look + the degraded-failure banner
/// pattern (rounded error container + typed label + the underlying error)
/// so a failed bootstrap reads as the same visual family the card uses for
/// its degraded sends.
class _AskLocalCardBootFailure extends StatelessWidget {
  const _AskLocalCardBootFailure({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Container(
            key: const Key('ask_local_boot_failure'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xF2FAFAFA),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: Color(0xFFDC2626),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${AppLocalizations.of(context)!.ask_local_boot_failed}\n'
                    '$error',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFDC2626),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The card's settings source of truth: the payload snapshot. Inert writes
/// (the card never edits settings) — reads need no shared_preferences
/// channel in the overlay engine.
class _FrozenCardSettingsNotifier extends SettingsNotifier {
  _FrozenCardSettingsNotifier(this._snapshot);

  final AppSettings _snapshot;

  @override
  AppSettings build() => _snapshot;
}
