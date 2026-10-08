import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/services/device_tools_service.dart';
import 'package:localmind/features/mcp/data/device_contacts_repository.dart';

class _FakePermission implements ContactsPermissionClient {
  _FakePermission({
    this.initiallyGranted = false,
    this.grantedOnRequest = false,
    this.permanentlyDenied = false,
  });

  bool initiallyGranted;
  bool grantedOnRequest;
  bool permanentlyDenied;
  int requestCount = 0;
  bool isPermanentlyDeniedCalled = false;

  @override
  Future<bool> isGranted() async => initiallyGranted;

  @override
  Future<bool> isPermanentlyDenied() async {
    isPermanentlyDeniedCalled = true;
    return permanentlyDenied;
  }

  @override
  Future<bool> request() async {
    requestCount++;
    initiallyGranted = grantedOnRequest;
    return grantedOnRequest;
  }
}

class _FakePlugin implements ContactsPluginClient {
  _FakePlugin([this.rows = const []]);

  List<ContactsPluginRow> rows;
  int fetchCount = 0;

  @override
  Future<List<ContactsPluginRow>> fetch() async {
    fetchCount++;
    return rows;
  }
}

ContactsPluginRow row(String name, List<String> emails, List<String> phones) =>
    ContactsPluginRow(name: name, emails: emails, phones: phones);

void main() {
  group('DeviceContactsRepository', () {
    group('search', () {
      test('matches name/email/phone contains and maps summaries', () async {
        final permission = _FakePermission(initiallyGranted: true);
        final plugin = _FakePlugin([
          row('Bravo Blue', ['b@example.com'], ['+1 555 010-0202']),
          row('Alpha Adams', ['ALPHA@example.com'], ['555-0101']),
          row('Charlie Chain', [], ['999 555 0103']),
        ]);
        final repo = DeviceContactsRepository(
          permissionClient: permission,
          pluginClient: plugin,
        );

        // Name contains, case-insensitive.
        expect((await repo.search('bravo')).single.name, 'Bravo Blue');
        // Email contains (case-insensitive on both sides), sorted by name.
        expect((await repo.search('@Example.com')).map((c) => c.name), [
          'Alpha Adams',
          'Bravo Blue',
        ]);
        // Phone contains.
        expect((await repo.search('010-0202')).single.name, 'Bravo Blue');
      });

      test('non-matching contact rows are dropped entirely', () async {
        final repo = DeviceContactsRepository(
          permissionClient: _FakePermission(initiallyGranted: true),
          pluginClient: _FakePlugin([
            row('Alice One', ['a@example.com'], ['555-0001']),
            row('Bob Two', ['b@example.com'], ['555-0002']),
          ]),
        );

        final hits = await repo.search('bob');

        expect(hits, hasLength(1));
        expect(hits.single.name, 'Bob Two');
      });

      test('a blank query short-circuits to an empty list', () async {
        final permission = _FakePermission(initiallyGranted: true);
        final plugin = _FakePlugin([row('A', [], [])]);
        final repo = DeviceContactsRepository(
          permissionClient: permission,
          pluginClient: plugin,
        );

        expect(await repo.search(''), isEmpty);
        expect(await repo.search('   '), isEmpty);
        expect(plugin.fetchCount, 0);
        expect(permission.requestCount, 0);
      });

      test('results are sorted by name and capped at 30', () async {
        final rows = <ContactsPluginRow>[
          row('Zed Zeta n33', [], []),
          for (var i = 1; i <= 32; i++)
            row('Zed Zeta n$i', ['zed$i@example.com'], []),
        ];
        final repo = DeviceContactsRepository(
          permissionClient: _FakePermission(initiallyGranted: true),
          pluginClient: _FakePlugin(rows),
        );

        final hits = await repo.search('zed');

        expect(hits, hasLength(30));
        final expectedNames = [
          for (final r in rows)
            if (r.name.contains('Zed')) r.name,
        ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        expect(hits.map((c) => c.name), expectedNames.take(30));
      });
    });

    group('dedupe + mapping', () {
      test('same name + primary email collapse into one summary', () async {
        final repo = DeviceContactsRepository(
          permissionClient: _FakePermission(initiallyGranted: true),
          pluginClient: _FakePlugin([
            row('Taylor Swift', ['taylor@example.com'], ['555-1']),
            row('taylor swift', ['TAYLOR@example.com'], ['555-1', '555-1']),
            row('Taylor Swift', ['taylor2@example.com'], []),
          ]),
        );

        final hits = await repo.search('taylor');

        expect(hits, hasLength(2));
        // The collapsed cluster keeps a single normalized field set:
        // per-row email/phone duplicates disappear with the same key.
        expect(hits.first.name, 'Taylor Swift');
        expect(hits.first.emails, ['taylor@example.com']);
        expect(hits.first.phones, ['555-1']);
        expect(hits.last.name, 'Taylor Swift');
        expect(hits.last.emails, ['taylor2@example.com']);
      });
    });

    group('byEmail', () {
      test('exact case-insensitive match scoped to the email fields', () async {
        final repo = DeviceContactsRepository(
          permissionClient: _FakePermission(initiallyGranted: true),
          pluginClient: _FakePlugin([
            row('Taylor Swift', ['taylor@example.com'], []),
            row('Una Union', ['taylor@example.com'], []),
            row('Vera Vex', ['vera@v.com', 'taylor@example.com'], []),
            row('Carol Cue', ['carol@example.com'], []),
          ]),
        );

        final hits = await repo.byEmail('TAYLOR@example.coM');

        // Dedupe applies: the two single-email rows share name/primary.
        expect(hits.map((c) => '${c.name}|${c.emails}'), {
          'Taylor Swift|[taylor@example.com]',
          'Una Union|[taylor@example.com]',
          'Vera Vex|[vera@v.com, taylor@example.com]',
        });
      });

      test('a name never matches byEmail and a prefix match works', () async {
        final repo = DeviceContactsRepository(
          permissionClient: _FakePermission(initiallyGranted: true),
          pluginClient: _FakePlugin([
            row('Alice One', ['a@example.com'], ['555-0001']),
          ]),
        );

        expect(await repo.byEmail('alice one'), isEmpty);
        expect((await repo.byEmail('a@')).single.emails, ['a@example.com']);
        expect(await repo.byEmail('   '), isEmpty);
      });
    });

    group('byPhone', () {
      test('digits-only comparison across formatting variants', () async {
        final repo = DeviceContactsRepository(
          permissionClient: _FakePermission(initiallyGranted: true),
          pluginClient: _FakePlugin([
            row('A One', ['a@x.com'], ['+1 (555) 010-0111']),
            row('B Two', [], ['55501002222']),
            row('C Three', [], ['+155501003333']),
          ]),
        );

        // Last-ten equality (country code dropped on the stored side).
        expect((await repo.byPhone('5550100111')).single.name, 'A One');
        // Full digits equality (country code on both sides).
        expect((await repo.byPhone('+1 555-010-0111')).single.name, 'A One');
        // Full containment (query inside the stored digits).
        expect((await repo.byPhone('01002222')).single.name, 'B Two');
        // Country-coded query against a bare stored number.
        expect((await repo.byPhone('+1555010033')).single.name, 'C Three');
      });

      test('a digit-less query or a name finds nothing byPhone', () async {
        final repo = DeviceContactsRepository(
          permissionClient: _FakePermission(initiallyGranted: true),
          pluginClient: _FakePlugin([
            row('A One', ['a@x.com'], ['555-0']),
          ]),
        );

        expect(await repo.byPhone('---'), isEmpty);
        expect(await repo.byPhone('A One'), isEmpty);
        expect(await repo.byPhone('   '), isEmpty);
      });
    });

    group('permission gate', () {
      test(
        'requests before the first query when not already granted',
        () async {
          final permission = _FakePermission(
            initiallyGranted: false,
            grantedOnRequest: true,
          );
          final plugin = _FakePlugin([
            row('Alice One', ['a@example.com'], []),
          ]);
          final repo = DeviceContactsRepository(
            permissionClient: permission,
            pluginClient: plugin,
          );

          await repo.search('alice');

          expect(permission.requestCount, 1);
          expect(plugin.fetchCount, 1);
        },
      );

      test('an already-granted state never re-prompts', () async {
        final permission = _FakePermission(initiallyGranted: true);
        final plugin = _FakePlugin(const []);
        final repo = DeviceContactsRepository(
          permissionClient: permission,
          pluginClient: plugin,
        );

        await repo.search('x');
        await repo.byEmail('x@y.com');
        await repo.byPhone('12');

        expect(permission.requestCount, 0);
        expect(permission.isPermanentlyDeniedCalled, isFalse);
        expect(plugin.fetchCount, 3);
      });

      test(
        'a denied or permanently-denied permission raises contacts permission',
        () async {
          for (final permanentlyDenied in const [false, true]) {
            final permission = _FakePermission(
              grantedOnRequest: false,
              permanentlyDenied: permanentlyDenied,
            );
            final plugin = _FakePlugin([row('A One', [], [])]);
            final repo = DeviceContactsRepository(
              permissionClient: permission,
              pluginClient: plugin,
            );

            await expectLater(
              repo.search('a'),
              throwsA(isA<ContactsPermissionDenied>()),
            );
            expect(plugin.fetchCount, 0);
            expect(permission.requestCount, 1);
          }
        },
      );

      test('both denial states render one settings-guidance surface', () async {
        final permanent = _FakePermission(
          grantedOnRequest: false,
          permanentlyDenied: true,
        );
        final repo = DeviceContactsRepository(
          permissionClient: permanent,
          pluginClient: _FakePlugin(),
        );

        Object? caught;
        try {
          await repo.search('a');
        } catch (e) {
          caught = e;
        }

        expect(caught, isA<ContactsPermissionDenied>());
        expect(
          caught.toString(),
          'contacts permission needed — grant it in system settings',
        );
      });
    });

    test('a plugin failure surfaces as DeviceChannelUnavailable', () async {
      final repo = DeviceContactsRepository(
        permissionClient: _FakePermission(initiallyGranted: true),
        pluginClient: _BrokenPlugin(),
      );

      await expectLater(
        repo.search('a'),
        throwsA(isA<DeviceChannelUnavailable>()),
      );
    });
  });
}

class _BrokenPlugin implements ContactsPluginClient {
  @override
  Future<List<ContactsPluginRow>> fetch() async {
    throw Exception('contacts channel broken');
  }
}
