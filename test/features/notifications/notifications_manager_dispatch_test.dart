import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/mcp_client.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/notifications/notifications_mcp_server.dart';

// Manager dispatch of the local notifications.read_recent tool: `max`
// clamps to 1..50 (default 20), `since_minutes` is integer-typed and the
// `package` filter trims — a blank one folds into "all apps" (null),
// never an error.

void main() {
  late McpServerManager manager;
  late int? spyMax;
  late int? spySinceMinutes;
  late String? spyPackage;
  late int spyCalls;

  setUp(() {
    spyMax = null;
    spySinceMinutes = null;
    spyPackage = null;
    spyCalls = 0;
    manager = McpServerManager();
    manager.addNotificationsServer(
      NotificationsServices(
        recent: ({int? max, int? sinceMinutes, String? package}) async {
          spyCalls++;
          spyMax = max;
          spySinceMinutes = sinceMinutes;
          spyPackage = package;
          return const [];
        },
      ),
    );
  });

  Future<void> read(Map<String, dynamic> args) =>
      manager.callTool(notificationsMcpServerLabel, 'notifications.read_recent', args);

  group('max clamp', () {
    test('caps at the 50-battle-tested top', () async {
      await read({'max': 100});
      expect(spyMax, 50);
    });

    test('floor at 1, default 20 when absent', () async {
      await read({'max': 0});
      expect(spyMax, 1);
      await read({'max': -5});
      expect(spyMax, 1);
      await read({});
      expect(spyMax, notificationsReadRecentMaxDefault);
    });
  });

  group('since_minutes typing', () {
    test('rejects non-integers with McpException before reading the ring',
        () async {
      await expectLater(
        read({'since_minutes': '15'}),
        throwsA(isA<McpException>()),
      );
      await expectLater(
        read({'since_minutes': 15.0}),
        throwsA(isA<McpException>()),
      );
      expect(spyCalls, 0, reason: 'bad args must not reach the ring');
    });

    test('integer since_minutes passes through', () async {
      await read({'since_minutes': 15});
      expect(spySinceMinutes, 15);
    });
  });

  group('package filter', () {
    test('blank package reads as all apps, not an error', () async {
      await read({'package': '   '});
      expect(spyPackage, isNull);

      await read({});
      expect(spyPackage, isNull);
    });

    test('trimmed exact package passes through', () async {
      await read({'package': ' com.example.mail '});
      expect(spyPackage, 'com.example.mail');
    });
  });
}
