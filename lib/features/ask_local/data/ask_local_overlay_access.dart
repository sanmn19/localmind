import 'package:flutter/services.dart';

import 'ask_local_payload.dart';

/// Thrown by [AskLocalOverlayAccess.openOverlayNow] when the platform side
/// reports the "display over other apps" grant is missing
/// (`overlay_permission_missing`) — callers route the user to the settings
/// deep-link instead of retrying the show.
class AskLocalOverlayPermissionException implements Exception {
  const AskLocalOverlayPermissionException();

  @override
  String toString() => 'overlay_permission_missing';
}

/// Method-channel wrapper for the overlay half of `localmind/ask_local`
/// (`localmind/ask_local` for calls, `localmind/ask_local/events` for the
/// closed function-back) plus the endpoint constants. Every read is bounded
/// by the house 3s channel timeout (the notifications-listener precedent)
/// and degrades rather than throwing, so host tests and unsupported
/// platforms read as "not granted / nothing shown".
class AskLocalOverlayAccess {
  const AskLocalOverlayAccess();

  static const MethodChannel _channel = MethodChannel(
    AskLocalRequestPayload.askLocalChannel,
  );

  /// True when Android would let us mount the TYPE_APPLICATION_OVERLAY
  /// window (Settings.canDrawOverlays). Not granted → the grant row shows
  /// its recovery button instead of any card.
  Future<bool> isOverlayPermitted() async {
    try {
      final permitted = await _channel
          .invokeMethod<bool>('isOverlayPermitted')
          .timeout(_channelTimeout);
      return permitted ?? false;
    } on Exception {
      // MissingPluginException under host tests; any channel failure reads
      // the same as "not granted" (matches the notifications-wrapper house).
      return false;
    }
  }

  /// Shows the floating card with [capturePath] + [selectedText], carrying
  /// the optional card [bootstrap] envelope (Task 4: the snapshot the card
  /// engine streams with). Returns whether the window is up.
  /// [AskLocalOverlayPermissionException] is thrown — verbatim from the
  /// `overlay_permission_missing` platform error — so callers can
  /// distinguish a settings trip from a plain miss.
  Future<bool> openOverlayNow({
    String? capturePath,
    required String selectedText,
    Map<String, Object?> bootstrap = const <String, Object?>{},
  }) async {
    try {
      final opened = await _channel
          .invokeMethod<bool>('openOverlayNow', {
            'capturePath': capturePath,
            'selectedText': selectedText,
            if (bootstrap.isNotEmpty) 'bootstrap': bootstrap,
          })
          .timeout(_channelTimeout);
      return opened ?? false;
    } on PlatformException catch (error) {
      if (error.code == 'overlay_permission_missing') {
        throw const AskLocalOverlayPermissionException();
      }
      rethrow;
    } on Exception {
      // Timeout (and MissingPlugin under host tests): the card is not up.
      return false;
    }
  }

  /// Re-checks the live overlay grant after a settings trip.
  Future<void> openOverlaySettings() async {
    try {
      await _channel
          .invokeMethod<void>('openOverlaySettings')
          .timeout(_channelTimeout);
    } on Exception {
      // Host tests / other platforms have no settings screen to open.
    }
  }

  /// Closes the card if shown; idempotent (false when nothing is up).
  Future<bool> closeCard() async {
    try {
      final closed = await _channel
          .invokeMethod<bool>('closeCard')
          .timeout(_channelTimeout);
      return closed ?? false;
    } on Exception {
      return false;
    }
  }

  /// Binding discovery for the one live card: true while the overlay
  /// window is mounted.
  Future<bool> isCardShown() async {
    try {
      final shown = await _channel
          .invokeMethod<bool>('isCardShown')
          .timeout(_channelTimeout);
      return shown ?? false;
    } on Exception {
      return false;
    }
  }

  /// Function-back stream: fires when the overlay window is torn down by
  /// anything BUT a Dart close request (permission revoked mid-flight,
  /// window-token teardown). Broadcast — any number of listeners is safe.
  Stream<bool> cardClosedEvents() =>
      _closedEvents.receiveBroadcastStream().asBroadcastStream().map(
            (_) => true,
          );

  static const EventChannel _closedEvents = EventChannel(
    'localmind/ask_local/events',
  );

  /// Widget-test hosts leave unmocked platform-channel futures pending
  /// forever; every read is bounded so callers always resolve (offline /
  /// forbearing device behavior matches the "not granted" read).
  static const _channelTimeout = Duration(seconds: 3);
}
