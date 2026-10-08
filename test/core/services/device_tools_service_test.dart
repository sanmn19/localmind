import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/services/device_tools_service.dart';

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
            return 'ok';
          });

      final result = await const MethodChannelDeviceAppLauncher().composeEmail(
        to: 'alice@example.com',
        subject: 'Import plans',
        body: 'Line one',
        cc: ['bob@example.com'],
      );

      expect(result, 'ok');
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
            return 'ok';
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
            return 'ok';
          });

      final result = await const MethodChannelDeviceAppLauncher().open(
        'com.example.app',
      );

      expect(result, 'ok');
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
}
