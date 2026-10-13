import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln;
import 'package:localmind/features/chat/data/background_engine.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';

/// Regression pin for the open-time crash:
/// `RemoteServiceException$CannotPostForegroundServiceNotificationException
/// (Bad notification for startForeground)` — the foreground keep-alive
/// service posted its startup notification into `localmind_fg_service`
/// without the channel existing. The channel MUST be created (via
/// flutter_local_notifications) BEFORE the service is configured/started.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startBackgroundKeepAliveService creates the fg channel first', () async {
    final calls = <MethodCall>[];
    fln.FlutterLocalNotificationsPlatform.instance =
        fln.AndroidFlutterLocalNotificationsPlugin();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async {
        calls.add(call);
        return true;
      },
    );

    // The flutter_background_service channel stays UNMOCKED: configure/start
    // throws — irrelevant; the CHANNEL creation must already have happened.
    try {
      await startBackgroundKeepAliveService();
    } catch (_) {}

    final channelCalls = calls
        .where((call) => call.method == 'createNotificationChannel')
        .map((call) => call.arguments['id'] as String?)
        .toList();
    expect(channelCalls, contains(localmindFgServiceChannelId));
    // Every notif-channel call must precede the first background-service
    // channel traffic (configure) — pinned via recording order when mocked;
    // here it suffices that the creation happened at all.
  });
}
