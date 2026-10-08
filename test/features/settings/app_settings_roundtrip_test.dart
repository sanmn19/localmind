import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/providers/tooling_providers.dart';
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
}
