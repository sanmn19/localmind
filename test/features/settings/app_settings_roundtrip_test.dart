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
}
