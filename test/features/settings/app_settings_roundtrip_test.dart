import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
import 'package:localmind/features/mail/data/mail_common.dart';
import 'package:localmind/features/mcp/data/web/web_search_service.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';

void main() {
  test(
    'web tool settings default to disabled with the auto provider chain',
    () {
      final settings = AppSettings();
      expect(settings.webToolsEnabled, isFalse);
      expect(settings.webSearchProvider, 'auto');
      expect(settings.webSearchApiKey, isNull);
      expect(settings.webSearxUrl, isNull);
    },
  );

  test('web tool settings survive toMap/fromMap round-trip', () {
    final settings = AppSettings().copyWith(
      webToolsEnabled: true,
      webSearchProvider: 'tavily',
      webSearchApiKey: 'k123',
    );
    final map = settings.toMap();
    expect(map['webToolsEnabled'], isTrue);
    final restored = AppSettings.fromMap(map);
    expect(restored.webToolsEnabled, isTrue);
    expect(restored.webSearchProvider, 'tavily');
    expect(restored.webSearchApiKey, 'k123');
  });

  test('screen processing model survives toMap/fromMap', () {
    final settings = AppSettings().copyWith(
      screenMemoryServerId: 'server-1',
      screenMemoryModelId: 'model-1',
    );
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.screenMemoryServerId, 'server-1');
    expect(restored.screenMemoryModelId, 'model-1');
    expect(AppSettings.fromMap({}).screenMemoryServerId, isNull);
  });

  test('auto-remember defaults off and survives toMap/fromMap', () {
    expect(AppSettings().autoMemoryEnabled, isFalse);
    final restored = AppSettings.fromMap(
      AppSettings().copyWith(autoMemoryEnabled: true).toMap(),
    );
    expect(restored.autoMemoryEnabled, isTrue);
    expect(AppSettings.fromMap({}).autoMemoryEnabled, isFalse);
  });

  test('fromMap tolerates missing web fields (upgrade path)', () {
    final restored = AppSettings.fromMap({'themeMode': 2});
    expect(restored.webToolsEnabled, isFalse);
    expect(restored.webSearchProvider, 'auto');
    expect(restored.webSearchApiKey, isNull);
  });

  test('fromMap keeps legacy ddg values after the auto upgrade', () {
    final restored = AppSettings.fromMap({'webSearchProvider': 'ddg'});
    expect(restored.webSearchProvider, 'ddg');
    expect(
      webSearchProviderFromName(restored.webSearchProvider),
      WebSearchProvider.ddgLite,
    );
  });

  test(
    'copyWith clears webSearchApiKey on explicit null and keeps when omitted',
    () {
      final base = AppSettings().copyWith(webSearchApiKey: 'k123');
      final cleared = base.copyWith(webSearchApiKey: null);
      expect(cleared.webSearchApiKey, isNull);
      final kept = base.copyWith(webToolsEnabled: true);
      expect(kept.webSearchApiKey, 'k123');
    },
  );

  test("fromMap maps 'searxng' to the searxng provider enum", () {
    final restored = AppSettings.fromMap({'webSearchProvider': 'searxng'});
    expect(
      webSearchProviderFromName(restored.webSearchProvider),
      WebSearchProvider.searxng,
    );
  });

  test(
    'copyWith sets and clears webSearxUrl on explicit null, keeps when omitted',
    () {
      final base = AppSettings().copyWith(webSearxUrl: 'http://rig:8888');
      expect(base.webSearxUrl, 'http://rig:8888');
      final cleared = base.copyWith(webSearxUrl: null);
      expect(cleared.webSearxUrl, isNull);
      final kept = base.copyWith(webToolsEnabled: true);
      expect(kept.webSearxUrl, 'http://rig:8888');
    },
  );

  test('webSearxUrl survives the toMap/fromMap round-trip', () {
    final settings = AppSettings().copyWith(
      webSearchProvider: 'searxng',
      webSearxUrl: 'http://rig:8888',
    );
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.webSearchProvider, 'searxng');
    expect(restored.webSearxUrl, 'http://rig:8888');
  });

  test('fromMap tolerates legacy maps without webSearxUrl', () {
    final restored = AppSettings.fromMap({
      'webSearchProvider': 'searxng',
      'webSearchApiKey': 'k123',
    });
    expect(restored.webSearxUrl, isNull);
  });

  test('skillsEnabled defaults to true and survives the round-trip', () {
    expect(AppSettings().skillsEnabled, isTrue);
    final restored = AppSettings.fromMap({'themeMode': 2});
    expect(restored.skillsEnabled, isTrue);
    final off = AppSettings().copyWith(skillsEnabled: false);
    expect(AppSettings.fromMap(off.toMap()).skillsEnabled, isFalse);
  });

  test(
    'backgroundTasksEnabled defaults to false and survives the round-trip',
    () {
      expect(AppSettings().backgroundTasksEnabled, isFalse);
      final restored = AppSettings.fromMap({'themeMode': 2});
      expect(restored.backgroundTasksEnabled, isFalse);
      final on = AppSettings().copyWith(backgroundTasksEnabled: true);
      expect(AppSettings.fromMap(on.toMap()).backgroundTasksEnabled, isTrue);
    },
  );

  test('device tool settings default to disabled', () {
    final settings = AppSettings();
    expect(settings.deviceToolsEnabled, isFalse);
  });

  test('deviceToolsEnabled survives the toMap/fromMap round-trip', () {
    final settings = AppSettings().copyWith(deviceToolsEnabled: true);
    final map = settings.toMap();
    expect(map['deviceToolsEnabled'], isTrue);
    final restored = AppSettings.fromMap(map);
    expect(restored.deviceToolsEnabled, isTrue);
  });

  test('fromMap tolerates missing deviceToolsEnabled (upgrade path)', () {
    final restored = AppSettings.fromMap({'themeMode': 2});
    expect(restored.deviceToolsEnabled, isFalse);
  });

  // Share-target receiving is ON by default: adding the intent-filter makes
  // the app a share target no matter what, so the toggle only gates the
  // Dart-side handling and must not silently flip off on upgrade.
  test('shareTargetEnabled defaults to enabled', () {
    final settings = AppSettings();
    expect(settings.shareTargetEnabled, isTrue);
  });

  test('shareTargetEnabled survives the toMap/fromMap round-trip', () {
    final settings = AppSettings().copyWith(shareTargetEnabled: false);
    final map = settings.toMap();
    expect(map['shareTargetEnabled'], isFalse);
    final restored = AppSettings.fromMap(map);
    expect(restored.shareTargetEnabled, isFalse);
  });

  test('fromMap tolerates missing shareTargetEnabled (upgrade path)', () {
    final restored = AppSettings.fromMap({'themeMode': 2});
    expect(restored.shareTargetEnabled, isTrue);
  });

  test('mail connector rows round-trip, including imap host overrides', () {
    final rows = [
      {'provider': 'gmail', 'email': 'g@gmail.com'},
      {
        'provider': 'imap',
        'email': 'i@example.org',
        'host': 'imap.example.org',
      },
    ];
    final settings = AppSettings().copyWith(mailConnectorAccounts: rows);
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.mailConnectorAccounts, rows);

    final imap = MailAccount.fromMap(rows.last);
    expect(imap.provider, MailProvider.imap);
    expect(imap.email, 'i@example.org');
  });

  test('MailAccount.fromMap maps unknown providers to gmail (legacy '
      'tolerance, imap exact)', () {
    expect(
      MailAccount.fromMap({'provider': 'imap'}).provider,
      MailProvider.imap,
    );
    expect(MailAccount.fromMap({'provider': 'imap'}).email, '');
    expect(
      MailAccount.fromMap({'provider': 'yahoo', 'email': 'x@y'}).provider,
      MailProvider.gmail,
    );
  });

  test('screen settings default off at 500 ms and 60 s', () {
    final settings = AppSettings();
    expect(settings.screenMemoryEnabled, isFalse);
    expect(settings.screenMemorySampleIntervalMs, 500);
    expect(settings.screenMemoryBatchIntervalSeconds, 60);
    expect(settings.screenMemoryBlockedApps, isNotEmpty);
  });

  test('screen settings survive the toMap/fromMap round-trip', () {
    final settings = AppSettings().copyWith(
      screenMemoryEnabled: true,
      screenMemorySampleIntervalMs: 1000,
      screenMemoryBatchIntervalSeconds: 120,
      screenMemoryBlockedApps: const ['com.bank', 'com.wallet'],
    );
    final map = settings.toMap();
    expect(map['screenMemoryEnabled'], isTrue);
    final restored = AppSettings.fromMap(map);
    expect(restored.screenMemoryEnabled, isTrue);
    expect(restored.screenMemorySampleIntervalMs, 1000);
    expect(restored.screenMemoryBatchIntervalSeconds, 120);
    expect(restored.screenMemoryBlockedApps, ['com.bank', 'com.wallet']);
  });

  test('fromMap tolerates missing screen settings (upgrade path)', () {
    final restored = AppSettings.fromMap({'themeMode': 2});
    expect(restored.screenMemoryEnabled, isFalse);
    expect(restored.screenMemorySampleIntervalMs, 500);
    expect(restored.screenMemoryBatchIntervalSeconds, 60);
    expect(restored.screenMemoryBlockedApps, isNotEmpty);
  });

  test('an empty blocked-apps list can be saved and restored', () {
    final settings = AppSettings().copyWith(screenMemoryBlockedApps: const []);
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.screenMemoryBlockedApps, isEmpty);
  });
}
