import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/services/device_tools_service.dart';
import 'package:localmind/features/chat/data/mcp_client.dart';
import 'package:localmind/features/chat/data/mcp_server_manager.dart';
import 'package:localmind/features/mcp/data/device_contacts_repository.dart';
import 'package:localmind/features/mcp/data/device_mcp_server.dart';

class _FakeLauncher implements DeviceAppLauncher {
  _FakeLauncher({this.installed = const []});

  final composeCalls =
      <({String to, String subject, String body, List<String>? cc})>[];
  String? lastComposeUri;
  final openCalls = <String>[];
  final List<DeviceAppEntry> installed;

  @override
  Future<String> composeEmail({
    required String to,
    required String subject,
    required String body,
    List<String>? cc,
  }) async {
    composeCalls.add((to: to, subject: subject, body: body, cc: cc));
    // Mirrors the native launcher shape: build the intent URI from the
    // received fields, exactly like the platform side does.
    lastComposeUri = composeEmailIntent(
      to: to,
      subject: subject,
      body: body,
      cc: cc,
    );
    return 'Opened your mail app with a message to $to';
  }

  @override
  Future<String> open(String target) async {
    openCalls.add(target);
    return 'Opened $target';
  }

  @override
  Future<List<DeviceAppEntry>> listInstalled() async => installed;
}

class _ThrowingLauncher implements DeviceAppLauncher {
  @override
  Future<String> composeEmail({
    required String to,
    required String subject,
    required String body,
    List<String>? cc,
  }) async {
    throw DeviceChannelUnavailable();
  }

  @override
  Future<String> open(String target) async {
    throw DeviceChannelUnavailable();
  }

  @override
  Future<List<DeviceAppEntry>> listInstalled() async {
    throw DeviceChannelUnavailable();
  }
}

class _FakeScreenshotService implements DeviceScreenshotService {
  final calls = <({String? package, bool scroll})>[];

  /// The canned contract line the chat layer later parses `[path=…]` from.
  String next =
      'Screenshot captured (3 screens stitched)\n'
      '[path=/tmp/tool_x.png]\n'
      '[frames=3]';

  @override
  Future<String> screenshot({String? package, bool scroll = false}) async {
    calls.add((package: package, scroll: scroll));
    return next;
  }
}

/// Screenshot boundary that always fails with the service-off code — the
/// native contract for "the accessibility capture service is not enabled".
class _ServiceOffScreenshotService implements DeviceScreenshotService {
  @override
  Future<String> screenshot({String? package, bool scroll = false}) async {
    throw DeviceChannelUnavailable(deviceToolsErrorScreenCaptureServiceOff);
  }
}

class _ThrowingScreenshotService implements DeviceScreenshotService {
  @override
  Future<String> screenshot({String? package, bool scroll = false}) async {
    throw DeviceChannelUnavailable();
  }
}

class _FakeContacts implements DeviceContactsService {
  final searchQueries = <String>[];
  final byEmailQueries = <String>[];
  final byPhoneQueries = <String>[];
  List<ContactSummary> next = const [];

  @override
  Future<List<ContactSummary>> search(String query) async {
    searchQueries.add(query);
    return next;
  }

  @override
  Future<List<ContactSummary>> byEmail(String email) async {
    byEmailQueries.add(email);
    return next;
  }

  @override
  Future<List<ContactSummary>> byPhone(String phone) async {
    byPhoneQueries.add(phone);
    return next;
  }
}

class _DeniedContactsPermission implements ContactsPermissionClient {
  @override
  Future<bool> isGranted() async => false;

  @override
  Future<bool> isPermanentlyDenied() async => true;

  @override
  Future<bool> request() async => false;
}

class _ThrowingContacts implements DeviceContactsService {
  @override
  Future<List<ContactSummary>> search(String query) async {
    throw DeviceChannelUnavailable();
  }

  @override
  Future<List<ContactSummary>> byEmail(String email) async {
    throw DeviceChannelUnavailable();
  }

  @override
  Future<List<ContactSummary>> byPhone(String phone) async {
    throw DeviceChannelUnavailable();
  }
}

Future<McpServerManager> _deviceManager({
  DeviceAppLauncher? launcher,
  DeviceContactsService? contacts,
  DeviceScreenshotService? screenshot,
}) async {
  final manager = McpServerManager();
  await manager.addDeviceServer(
    DeviceServices(
      contacts: contacts ?? _FakeContacts(),
      launcher: launcher ?? _FakeLauncher(),
      screenshot: screenshot ?? _FakeScreenshotService(),
    ),
  );
  return manager;
}

void main() {
  group('device mcp server registration', () {
    test(
      'addDeviceServer advertises every device tool with the local url',
      () async {
        final manager = await _deviceManager();

        expect(manager.hasDeviceServer(), isTrue);
        expect(manager.hasServer(deviceMcpServerLabel), isTrue);
        expect(manager.getServerUrl(deviceMcpServerLabel), deviceMcpServerUrl);
        expect(manager.serverLabels, contains(deviceMcpServerLabel));
        final toolNames = manager
            .getTools(deviceMcpServerLabel)
            .map((t) => t.name)
            .toSet();
        expect(toolNames, {
          'apps.compose_email',
          'apps.open',
          'apps.list_installed',
          'apps.screenshot',
          'contacts.search',
          'contacts.by_email',
          'contacts.by_phone',
        });
        expect(manager.hasWebServer(), isFalse);
        expect(manager.hasTerminalServer(), isFalse);
        expect(manager.getCapabilities(deviceMcpServerLabel)?.tools, isTrue);
      },
    );

    test('re-registration replaces without duplicating', () async {
      final manager = McpServerManager();
      await manager.addDeviceServer(
        DeviceServices(
          contacts: _FakeContacts(),
          launcher: _FakeLauncher(),
          screenshot: _FakeScreenshotService(),
        ),
      );
      await manager.addDeviceServer(
        DeviceServices(
          contacts: _FakeContacts(),
          launcher: _FakeLauncher(),
          screenshot: _FakeScreenshotService(),
        ),
      );

      expect(manager.getTools(deviceMcpServerLabel), hasLength(7));
      expect(manager.getDeviceServices(), isNotNull);
      expect(manager.serverCount, 1);
    });

    test('removeServer and clear tear the device server down', () async {
      final manager = await _deviceManager();
      await manager.removeServer(deviceMcpServerLabel);
      expect(manager.hasDeviceServer(), isFalse);
      expect(manager.getDeviceServices(), isNull);
      expect(manager.getTools(deviceMcpServerLabel), isEmpty);
      expect(manager.hasServer(deviceMcpServerLabel), isFalse);

      final manager2 = await _deviceManager();
      await manager2.clear();
      expect(manager2.hasDeviceServer(), isFalse);
      expect(manager2.hasServer(deviceMcpServerLabel), isFalse);
    });
  });

  group('apps.compose_email dispatch', () {
    test(
      'passes to/subject/body/cc through the launcher and returns its result',
      () async {
        final launcher = _FakeLauncher();
        final manager = await _deviceManager(launcher: launcher);

        final result = await manager.callTool(
          deviceMcpServerLabel,
          'apps.compose_email',
          {
            'to': 'alice@example.com',
            'subject': 'Import plans',
            'body': 'Line one\nLine two',
            'cc': ['bob@example.com', 'carol@example.com'],
          },
        );

        expect(
          result,
          'Opened your mail app with a message to alice@example.com',
        );
        expect(launcher.composeCalls, hasLength(1));
        final call = launcher.composeCalls.single;
        expect(call.to, 'alice@example.com');
        expect(call.subject, 'Import plans');
        expect(call.body, 'Line one\nLine two');
        expect(call.cc, ['bob@example.com', 'carol@example.com']);
        // The launcher (like the native side) builds the mailto intent from
        // the fields — the fake does the same and the QUERY is asserted.
        expect(
          Uri.parse(launcher.lastComposeUri!).query,
          'subject=Import%20plans&body=Line%20one%0ALine%20two'
          '&cc=bob%40example.com,carol%40example.com',
        );
        final parsed = Uri.parse(launcher.lastComposeUri!);
        expect(parsed.scheme, 'mailto');
        expect(parsed.path, 'alice@example.com');
      },
    );

    test(
      'a comma-separated cc string is split before reaching the launcher',
      () async {
        final launcher = _FakeLauncher();
        final manager = await _deviceManager(launcher: launcher);

        await manager.callTool(deviceMcpServerLabel, 'apps.compose_email', {
          'to': 'alice@example.com',
          'subject': 'Hi',
          'body': 'Body',
          'cc': 'bob@example.com, carol@example.com',
        });

        final call = launcher.composeCalls.single;
        expect(call.cc, ['bob@example.com', 'carol@example.com']);
      },
    );

    test('no cc means no cc segment in the built intent', () async {
      final launcher = _FakeLauncher();
      final manager = await _deviceManager(launcher: launcher);

      await manager.callTool(deviceMcpServerLabel, 'apps.compose_email', {
        'to': 'alice@example.com',
        'subject': 'Hi',
        'body': 'Body',
      });

      expect(launcher.composeCalls.single.cc, isNull);
      expect(
        launcher.lastComposeUri,
        'mailto:alice@example.com?subject=Hi&body=Body',
      );
    });

    test(
      'a blank recipient fails with an ERROR and never reaches the launcher',
      () async {
        final launcher = _FakeLauncher();
        final manager = await _deviceManager(launcher: launcher);

        final result = await manager.callTool(
          deviceMcpServerLabel,
          'apps.compose_email',
          {'to': '   ', 'subject': 'Hi', 'body': 'Body'},
        );

        expect(result, 'ERROR: recipient address is required');
        expect(launcher.composeCalls, isEmpty);
      },
    );

    test('non-string arguments reject with McpException', () async {
      final manager = await _deviceManager();

      await expectLater(
        manager.callTool(deviceMcpServerLabel, 'apps.compose_email', {
          'to': 'alice@example.com',
          'subject': 7,
          'body': 'Body',
        }),
        throwsA(isA<McpException>()),
      );
    });
  });

  group('apps.open dispatch', () {
    test('valid package and deep-link targets reach the launcher', () async {
      for (final target in const [
        'com.example.app',
        'https://example.com/page',
        'localmind://share/x1',
      ]) {
        final launcher = _FakeLauncher();
        final manager = await _deviceManager(launcher: launcher);

        final result = await manager.callTool(
          deviceMcpServerLabel,
          'apps.open',
          {'target': target},
        );

        expect(result, 'Opened $target');
        expect(launcher.openCalls, [target], reason: 'target: $target');
      }
    });

    test(
      'invalid targets fail with an ERROR and never reach the launcher',
      () async {
        for (final target in const [
          'Not A Package!',
          'com.example.app/x',
          '',
        ]) {
          final launcher = _FakeLauncher();
          final manager = await _deviceManager(launcher: launcher);

          final result = await manager.callTool(
            deviceMcpServerLabel,
            'apps.open',
            {'target': target},
          );

          expect(
            result,
            'ERROR: not a valid package or deep link: $target',
            reason: 'target: $target',
          );
          expect(launcher.openCalls, isEmpty, reason: 'target: $target');
        }
      },
    );

    test('non-string target rejects with McpException', () async {
      final manager = await _deviceManager();
      await expectLater(
        manager.callTool(deviceMcpServerLabel, 'apps.open', {'target': 9}),
        throwsA(isA<McpException>()),
      );
    });
  });

  group('apps.list_installed dispatch', () {
    test('renders a bullet list of label (package) entries', () async {
      final launcher = _FakeLauncher(
        installed: const [
          DeviceAppEntry(label: 'Mail', package: 'com.android.mail'),
          DeviceAppEntry(label: 'Maps', package: 'com.google.maps'),
        ],
      );
      final manager = await _deviceManager(launcher: launcher);

      final result = await manager.callTool(
        deviceMcpServerLabel,
        'apps.list_installed',
        {},
      );

      expect(result, '- Mail (com.android.mail)\n- Maps (com.google.maps)');
    });

    test('an empty app list reads as plain text, not an error', () async {
      final manager = await _deviceManager(
        launcher: _FakeLauncher(installed: []),
      );
      final result = await manager.callTool(
        deviceMcpServerLabel,
        'apps.list_installed',
        {},
      );
      expect(result, 'No installed apps reported.');
    });
  });

  group('apps.screenshot dispatch', () {
    test(
      'passes package+scroll through and returns the boundary string with a parseable path marker',
      () async {
        final fake = _FakeScreenshotService();
        final manager = await _deviceManager(screenshot: fake);

        final result = await manager.callTool(
          deviceMcpServerLabel,
          'apps.screenshot',
          {'package': 'com.example.app', 'scroll': true},
        );

        expect(fake.calls.single.package, 'com.example.app');
        expect(fake.calls.single.scroll, isTrue);
        expect(result, fake.next);
        // The `[path=…]` marker must parse — the chat layer attaches the
        // image to the follow-up turn based on this marker.
        expect(parseScreenshotAttachPath(result), '/tmp/tool_x.png');
      },
    );

    test('scroll defaults to false and package may be omitted', () async {
      final fake = _FakeScreenshotService()
        ..next =
            'Screenshot captured (1 screen)\n'
            '[path=/tmp/tool_single.png]\n'
            '[frames=1]';
      final manager = await _deviceManager(screenshot: fake);

      final result = await manager.callTool(
        deviceMcpServerLabel,
        'apps.screenshot',
        {},
      );

      expect(fake.calls.single.scroll, isFalse);
      expect(fake.calls.single.package, isNull);
      expect(parseScreenshotAttachPath(result), '/tmp/tool_single.png');
    });

    test('a non-string package rejects with McpException', () async {
      final manager = await _deviceManager();
      await expectLater(
        manager.callTool(deviceMcpServerLabel, 'apps.screenshot', {
          'package': 7,
        }),
        throwsA(isA<McpException>()),
      );
    });

    test(
      'a missing capture service renders the accessibility-settings guidance',
      () async {
        final manager = await _deviceManager(
          screenshot: _ServiceOffScreenshotService(),
        );

        final result = await manager.callTool(
          deviceMcpServerLabel,
          'apps.screenshot',
          {},
        );

        expect(
          result,
          "ERROR: enable LocalMind's Screen Capture in Accessibility settings",
        );
      },
    );

    test('generic channel failures keep the generic ERROR line', () async {
      final manager = await _deviceManager(
        screenshot: _ThrowingScreenshotService(),
      );

      expect(
        await manager.callTool(deviceMcpServerLabel, 'apps.screenshot', {}),
        'ERROR: device channel unavailable',
      );
    });
  });

  group('screenshot marker parse helpers', () {
    test('parseScreenshotAttachPath extracts the bracketed marker only', () {
      expect(
        parseScreenshotAttachPath(
          'Screenshot captured (3 screens stitched)\n'
          '[path=/data/user/0/pro.momin.localmind/cache/tool_screenshots/tool_1.png]\n'
          '[frames=3]',
        ),
        '/data/user/0/pro.momin.localmind/cache/tool_screenshots/tool_1.png',
      );
      expect(
        parseScreenshotAttachPath('ERROR: screenshot capture failed'),
        isNull,
      );
      expect(parseScreenshotAttachPath(''), isNull);
    });
  });

  group('contacts dispatch', () {
    _FakeContacts contacts() {
      final fake = _FakeContacts();
      fake.next = [
        ContactSummary(
          name: 'Alice Example',
          emails: const ['alice@example.com', 'aa@example.com'],
          phones: const ['+15551000111', '+15551000222'],
        ),
      ];
      return fake;
    }

    test(
      'search passes the query through and renders summary bullets',
      () async {
        final fake = contacts();
        final manager = await _deviceManager(
          launcher: _FakeLauncher(),
          contacts: fake,
        );

        final result = await manager.callTool(
          deviceMcpServerLabel,
          'contacts.search',
          {'query': 'alice'},
        );

        expect(fake.searchQueries, ['alice']);
        expect(
          result,
          '- Alice Example — emails: alice@example.com, aa@example.com; '
          'phones: +15551000111, +15551000222',
        );
      },
    );

    test('by_email passes the raw email through', () async {
      final fake = contacts();
      fake.next = [
        ContactSummary(
          name: 'Alice Example',
          emails: const ['alice@example.com'],
          phones: const [],
        ),
      ];
      final manager = await _deviceManager(
        launcher: _FakeLauncher(),
        contacts: fake,
      );

      final result = await manager.callTool(
        deviceMcpServerLabel,
        'contacts.by_email',
        {'email': 'alice@example.com'},
      );

      expect(fake.byEmailQueries, ['alice@example.com']);
      expect(result, '- Alice Example — emails: alice@example.com');
    });

    test(
      'by_phone passes the raw phone through and renders phones-only rows',
      () async {
        final fake = contacts();
        fake.next = [
          ContactSummary(
            name: 'Bob Example',
            emails: const [],
            phones: const ['+15551230000'],
          ),
        ];
        final manager = await _deviceManager(
          launcher: _FakeLauncher(),
          contacts: fake,
        );

        final result = await manager.callTool(
          deviceMcpServerLabel,
          'contacts.by_phone',
          {'phone': '+15551230000'},
        );

        expect(fake.byPhoneQueries, ['+15551230000']);
        expect(result, '- Bob Example — phones: +15551230000');
      },
    );

    test('a summary without details renders the bare name', () async {
      final fake = _FakeContacts();
      fake.next = [
        ContactSummary(name: 'Carol', emails: const [], phones: const []),
      ];
      final manager = await _deviceManager(contacts: fake);

      final result = await manager.callTool(
        deviceMcpServerLabel,
        'contacts.search',
        {'query': 'carol'},
      );
      expect(result, '- Carol');
    });

    test('an empty contact result reads as plain text, not an error', () async {
      final manager = await _deviceManager();
      final result = await manager.callTool(
        deviceMcpServerLabel,
        'contacts.search',
        {'query': 'nobody'},
      );
      expect(result, 'No matching contacts found.');
    });

    test('missing string arguments reject with McpException', () async {
      final manager = await _deviceManager();
      await expectLater(
        manager.callTool(deviceMcpServerLabel, 'contacts.search', {}),
        throwsA(isA<McpException>()),
      );
      await expectLater(
        manager.callTool(deviceMcpServerLabel, 'contacts.by_email', {}),
        throwsA(isA<McpException>()),
      );
      await expectLater(
        manager.callTool(deviceMcpServerLabel, 'contacts.by_phone', {}),
        throwsA(isA<McpException>()),
      );
    });
  });

  group('device output truncation', () {
    test(
      'list_installed output over 6000 chars is capped with [truncated]',
      () async {
        final launcher = _FakeLauncher(
          installed: [
            for (var i = 0; i < 500; i++)
              DeviceAppEntry(
                label: 'Very Long Application Label Suffix $i',
                package: 'com.example.pkg$i',
              ),
          ],
        );
        final manager = await _deviceManager(launcher: launcher);

        final result = await manager.callTool(
          deviceMcpServerLabel,
          'apps.list_installed',
          {},
        );

        expect(result.endsWith('\n[truncated]'), isTrue);
        expect(
          result.length,
          lessThanOrEqualTo(deviceMaxChars + '\n[truncated]'.length),
        );
      },
    );

    test('search output over 6000 chars is capped with [truncated]', () async {
      final fake = _FakeContacts();
      fake.next = [
        for (var i = 0; i < 300; i++)
          ContactSummary(
            name: 'Contact Person Number $i',
            emails: ['person$i@example.com'],
            phones: ['+1555000000$i'],
          ),
      ];
      final manager = await _deviceManager(contacts: fake);

      final result = await manager.callTool(
        deviceMcpServerLabel,
        'contacts.search',
        {'query': 'person'},
      );

      expect(result.endsWith('\n[truncated]'), isTrue);
    });
  });

  group('unknown tools', () {
    test('unknown device tool names throw McpException', () async {
      final manager = await _deviceManager();
      await expectLater(
        manager.callTool(deviceMcpServerLabel, 'apps.nope', {}),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            'Device MCP tool not found: apps.nope',
          ),
        ),
      );
    });
  });

  group('channel-unavailable mapping', () {
    test('launcher channel failures surface as an ERROR string', () async {
      final manager = await _deviceManager(
        launcher: _ThrowingLauncher(),
        contacts: _FakeContacts(),
      );

      expect(
        await manager.callTool(deviceMcpServerLabel, 'apps.compose_email', {
          'to': 'a@example.com',
          'subject': 's',
          'body': 'b',
        }),
        'ERROR: device channel unavailable',
      );
      expect(
        await manager.callTool(deviceMcpServerLabel, 'apps.open', {
          'target': 'com.example.app',
        }),
        'ERROR: device channel unavailable',
      );
      expect(
        await manager.callTool(deviceMcpServerLabel, 'apps.list_installed', {}),
        'ERROR: device channel unavailable',
      );
    });

    test('contacts channel failures surface as an ERROR string', () async {
      final manager = await _deviceManager(
        launcher: _FakeLauncher(),
        contacts: _ThrowingContacts(),
      );

      expect(
        await manager.callTool(deviceMcpServerLabel, 'contacts.search', {
          'query': 'x',
        }),
        'ERROR: device channel unavailable',
      );
    });

    test(
      'a contacts permission rejection renders the settings-guidance line',
      () async {
        final manager = await _deviceManager(
          launcher: _FakeLauncher(),
          contacts: DeviceContactsRepository(
            permissionClient: _DeniedContactsPermission(),
          ),
        );

        for (final call in const [
          ('contacts.search', {'query': 'x'}),
          ('contacts.by_email', {'email': 'x@y.com'}),
          ('contacts.by_phone', {'phone': '555'}),
        ]) {
          expect(
            await manager.callTool(
              deviceMcpServerLabel,
              call.$1,
              call.$2 as Map<String, dynamic>,
            ),
            'ERROR: contacts permission needed — grant it in system settings',
          );
        }
      },
    );
  });

  group('pure intent builders', () {
    test('composeEmailIntent builds the mailto uri query joined &-encoded', () {
      expect(
        composeEmailIntent(
          to: 'alice@example.com',
          subject: 'Import plans',
          body: 'Line one\nLine two',
          cc: ['bob@example.com', 'carol@example.com'],
        ),
        'mailto:alice@example.com?subject=Import%20plans'
        '&body=Line%20one%0ALine%20two&cc=bob%40example.com,carol%40example.com',
      );
      expect(
        composeEmailIntent(
          to: 'alice@example.com',
          subject: 'wat er',
          body: 'b',
        ),
        'mailto:alice@example.com?subject=wat%20er&body=b',
      );
    });

    test('isValidOpenTarget accepts packages and scheme-full deep links', () {
      for (final target in const [
        'com.example.app',
        'org.mozilla.firefox',
        'com.corp.mail_app',
        'a.b',
        'https://example.com/page',
        'localmind://share/x1',
        'ftp://host/file',
      ]) {
        expect(isValidOpenTarget(target), isTrue, reason: 'target: $target');
      }
      for (final target in const [
        'Not A Package!',
        '1a.b',
        'nodots',
        'com.example.app/x',
        '',
        'not a uri',
        '//no-scheme/path',
        'com.example.app/with space',
      ]) {
        expect(isValidOpenTarget(target), isFalse, reason: 'target: $target');
      }
    });
  });
}
