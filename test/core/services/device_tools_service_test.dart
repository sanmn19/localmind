import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/services/device_tools_service.dart';
import 'package:localmind/features/mcp/data/device_mcp_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceToolsChannel, null);
  });

  group('MethodChannelDeviceAppLauncher', () {
    test('composeEmail invokes composeEmail with the field payload', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(deviceToolsChannel, (call) async {
            calls.add(call);
            return true;
          });

      final result = await const MethodChannelDeviceAppLauncher().composeEmail(
        to: 'alice@example.com',
        subject: 'Import plans',
        body: 'Line one',
        cc: ['bob@example.com'],
      );

      expect(
        result,
        'Opened your mail app with a message to alice@example.com',
      );
      expect(calls, hasLength(1));
      expect(calls.single.method, deviceToolsMethodNameComposeEmail);
      expect(calls.single.arguments, {
        'to': 'alice@example.com',
        'subject': 'Import plans',
        'body': 'Line one',
        'cc': ['bob@example.com'],
      });
    });

    test('composeEmail omits cc when the model sent none', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(deviceToolsChannel, (call) async {
            calls.add(call);
            return true;
          });

      await const MethodChannelDeviceAppLauncher().composeEmail(
        to: 'alice@example.com',
        subject: 'Hi',
        body: 'Body',
      );

      expect(calls.single.arguments, {
        'to': 'alice@example.com',
        'subject': 'Hi',
        'body': 'Body',
      });
    });

    test('open invokes openApp with the target', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(deviceToolsChannel, (call) async {
            calls.add(call);
            return true;
          });

      final result = await const MethodChannelDeviceAppLauncher().open(
        'com.example.app',
      );

      expect(result, 'Opened com.example.app');
      expect(calls.single.method, deviceToolsMethodNameOpenApp);
      expect(calls.single.arguments, {'target': 'com.example.app'});
    });

    test('listInstalled maps native rows to DeviceAppEntry', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(deviceToolsChannel, (call) async {
            calls.add(call);
            return [
              {'label': 'Mail', 'package': 'com.android.mail'},
              {'label': 'Maps', 'package': 'com.google.maps'},
            ];
          });

      final apps = await const MethodChannelDeviceAppLauncher().listInstalled();

      expect(calls.single.method, deviceToolsMethodNameListInstalledApps);
      expect(apps, hasLength(2));
      expect(apps.first.label, 'Mail');
      expect(apps.first.package, 'com.android.mail');
      expect(apps.last.label, 'Maps');
      expect(apps.last.package, 'com.google.maps');
    });

    test(
      'a missing platform handler raises DeviceChannelUnavailable',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(deviceToolsChannel, (call) async {
              throw MissingPluginException('no host on this platform');
            });

        await expectLater(
          const MethodChannelDeviceAppLauncher().composeEmail(
            to: 'a@example.com',
            subject: 's',
            body: 'b',
          ),
          throwsA(isA<DeviceChannelUnavailable>()),
        );
        await expectLater(
          const MethodChannelDeviceAppLauncher().open('com.example.app'),
          throwsA(isA<DeviceChannelUnavailable>()),
        );
        await expectLater(
          const MethodChannelDeviceAppLauncher().listInstalled(),
          throwsA(isA<DeviceChannelUnavailable>()),
        );
      },
    );

    test(
      'the channel payload mirrors the pinned native mailto parity string',
      () async {
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(deviceToolsChannel, (call) async {
              calls.add(call);
              return true;
            });

        await const MethodChannelDeviceAppLauncher().composeEmail(
          to: 'alice@example.com',
          subject: 'Import plans',
          body: 'Line one\nLine two',
          cc: ['bob@example.com', 'carol@example.com'],
        );

        // CROSS-CHECK pinning Dart↔Kotlin parity: MainActivity.kt's
        // composeEmail builds the mailto: URI from the received fields with
        // Uri.encode(part, "-_.!~*'()") (Dart's Uri.encodeComponent leave
        // set) and a comma-joined cc. Its required output is exactly what
        // device_mcp_server_test.dart pins for the pure Dart builder.
        expect(
          composeEmailIntent(
            to: 'alice@example.com',
            subject: 'Import plans',
            body: 'Line one\nLine two',
            cc: ['bob@example.com', 'carol@example.com'],
          ),
          'mailto:alice@example.com?subject=Import%20plans'
          '&body=Line%20one%0ALine%20two'
          '&cc=bob%40example.com,carol%40example.com',
        );
        expect(calls.single.arguments, {
          'to': 'alice@example.com',
          'subject': 'Import plans',
          'body': 'Line one\nLine two',
          'cc': ['bob@example.com', 'carol@example.com'],
        });
      },
    );

    test(
      'each native error code maps to a reason-carrying exception',
      () async {
        for (final code in const [
          deviceToolsErrorNoMailApp,
          deviceToolsErrorAppNotInstalled,
          deviceToolsErrorSecurityException,
        ]) {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(deviceToolsChannel, (call) async {
                throw PlatformException(code: code);
              });

          await expectLater(
            const MethodChannelDeviceAppLauncher().composeEmail(
              to: 'a@example.com',
              subject: 's',
              body: 'b',
            ),
            throwsA(
              isA<DeviceChannelUnavailable>().having(
                (failure) => failure.reason,
                'reason',
                code,
              ),
            ),
          );
          await expectLater(
            const MethodChannelDeviceAppLauncher().open('com.example.app'),
            throwsA(
              isA<DeviceChannelUnavailable>().having(
                (failure) => failure.reason,
                'reason',
                code,
              ),
            ),
          );
          await expectLater(
            const MethodChannelDeviceAppLauncher().listInstalled(),
            throwsA(
              isA<DeviceChannelUnavailable>().having(
                (failure) => failure.reason,
                'reason',
                code,
              ),
            ),
          );
        }
      },
    );
  });

  group('MethodChannelDeviceContactsService', () {
    test('search invokes searchContacts and maps summaries', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(deviceToolsChannel, (call) async {
            calls.add(call);
            return [
              {
                'name': 'Alice Example',
                'emails': ['alice@example.com'],
                'phones': ['+15551000111'],
              },
            ];
          });

      final contacts = await const MethodChannelDeviceContactsService().search(
        'alice',
      );

      expect(calls.single.method, deviceToolsMethodNameSearchContacts);
      expect(calls.single.arguments, {'query': 'alice'});
      expect(contacts, hasLength(1));
      expect(contacts.single.name, 'Alice Example');
      expect(contacts.single.emails, ['alice@example.com']);
      expect(contacts.single.phones, ['+15551000111']);
    });

    test('by_email and by_phone use their dedicated channel methods', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(deviceToolsChannel, (call) async {
            calls.add(call);
            return const [];
          });

      final service = const MethodChannelDeviceContactsService();
      expect(await service.byEmail('a@example.com'), isEmpty);
      expect(await service.byPhone('+1555'), isEmpty);

      expect(calls.map((c) => c.method), [
        deviceToolsMethodNameContactByEmail,
        deviceToolsMethodNameContactByPhone,
      ]);
      expect(calls.first.arguments, {'email': 'a@example.com'});
      expect(calls.last.arguments, {'phone': '+1555'});
    });

    test(
      'a failing contacts channel raises DeviceChannelUnavailable',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(deviceToolsChannel, (call) async {
              throw PlatformException(code: 'contacts_error');
            });

        await expectLater(
          const MethodChannelDeviceContactsService().search('x'),
          throwsA(isA<DeviceChannelUnavailable>()),
        );
      },
    );
  });

  group('MethodChannelDeviceScreenshotService', () {
    test(
      'screenshot invokes the screenshot method with package and scroll',
      () async {
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(deviceToolsChannel, (call) async {
              calls.add(call);
              return {'path': '/cache/tool_1759920000000.png', 'frames': 3};
            });

        final result = await const MethodChannelDeviceScreenshotService()
            .screenshot(package: 'com.example.app', scroll: true);

        expect(calls, hasLength(1));
        expect(calls.single.method, deviceToolsMethodNameScreenshot);
        expect(calls.single.arguments, {
          'package': 'com.example.app',
          'scroll': true,
        });
        expect(
          result,
          'Screenshot captured (3 screens stitched)\n'
          '[path=/cache/tool_1759920000000.png]\n'
          '[frames=3]',
        );
      },
    );

    test(
      'a package-less capture omits the package key and reads as one screen',
      () async {
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(deviceToolsChannel, (call) async {
              calls.add(call);
              return {'path': '/cache/tool_1759920000001.png', 'frames': 1};
            });

        final result = await const MethodChannelDeviceScreenshotService()
            .screenshot();

        expect(calls.single.arguments, {'scroll': false});
        expect(
          result,
          'Screenshot captured (1 screen)\n'
          '[path=/cache/tool_1759920000001.png]\n'
          '[frames=1]',
        );
      },
    );

    test(
      'a native payload without a path renders a model-readable failure',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(deviceToolsChannel, (call) async {
              return {'path': '', 'frames': 0};
            });

        final result = await const MethodChannelDeviceScreenshotService()
            .screenshot(scroll: true);

        expect(result, 'ERROR: screenshot capture failed');
      },
    );

    test(
      'the service-off error code carries through as the exception reason',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(deviceToolsChannel, (call) async {
              throw PlatformException(code: 'screen_capture_service_off');
            });

        await expectLater(
          const MethodChannelDeviceScreenshotService().screenshot(),
          throwsA(
            isA<DeviceChannelUnavailable>().having(
              (failure) => failure.reason,
              'reason',
              deviceToolsErrorScreenCaptureServiceOff,
            ),
          ),
        );
      },
    );
  });
}
