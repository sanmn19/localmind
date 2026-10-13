import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localmind/core/logger/app_logger.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/core/storage/objectbox_store.dart';
import 'package:localmind/features/ask_local/ask_local_notifier.dart';
import 'package:localmind/features/ask_local/data/ask_local_card_bootstrap.dart';
import 'package:localmind/features/ask_local/data/ask_local_card_channel.dart';
import 'package:localmind/features/ask_local/data/ask_local_conversation_service.dart';
import 'package:localmind/features/chat/data/chat_service.dart';
import 'package:localmind/features/ask_local/views/ask_local_card.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';

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
  final director = _CardBootDirector(channel: channel);
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

class _CardBootDirector {
  _CardBootDirector({required this.channel});

  final AskLocalCardChannel channel;
  ProviderContainer? _container;

  Future<void> injectInitial(AskLocalCardChannel channel) async {
    final delivery = await channel.requestInitialPayload();
    if (delivery != null) {
      await apply(delivery);
    }
  }

  Future<void> apply(AskLocalCardDelivery delivery) async {
    await _ensureContainer(delivery.bootstrap);
    unawaited(
      _container?.read(askLocalCardNotifierProvider.notifier).applyDelivery(
            delivery,
          ),
    );
  }

  void reapClosed() {
    _container?.read(askLocalCardNotifierProvider.notifier).reapClosed();
  }

  /// Lite container: attached store (bootstrap's storeDir), FROZEN settings
  /// (the envelope's full AppSettings snapshot; defaults when absent), env
  /// closures. NO shared_preferences/path_provider plugins are registered
  /// in this engine — the snapshot avoids them by construction.
  Future<void> _ensureContainer(AskLocalCardBootstrapPayload? bootstrap) async {
    final existing = _container;
    if (existing != null) return;

    ObjectBoxStore? db;
    AppSettings settings = AppSettings();
    if (bootstrap != null) {
      try {
        db =
            await ObjectBoxStore.attachAsSecondaryIsolateAt(bootstrap.storeDir);
      } catch (error) {
        Log.error('Ask Local store attach failed: $error');
      }
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
    runApp(UncontrolledProviderScope(
      container: _container!,
      child: const AskLocalCardApp(),
    ));
  }

  ChatService? _cardChatServiceFor(AskLocalCardBootstrapPayload bootstrap) {
    final server = bootstrap.server.toServer();
    if (server.isOnDevice) {
      return null;
    }
    return ChatService.forServer(server.type, Dio());
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
