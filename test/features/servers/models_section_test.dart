import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:localmind/features/models/data/manual_model_repository.dart';
import 'package:localmind/features/models/data/manual_model_store.dart';
import 'package:localmind/features/models/data/models/manual_model.dart';
import 'package:localmind/features/models/data/models/model_info.dart';
import 'package:localmind/features/models/providers/manual_model_providers.dart';
import 'package:localmind/features/servers/providers/server_providers.dart';
import 'package:localmind/features/servers/views/components/models_section.dart';
import 'package:localmind/l10n/app_localizations.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('edit mode lists manual rows and removes one', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final repo = ManualModelRepository(InMemoryManualModelStore())
      ..add(
        ManualModel(
          serverId: 's1',
          modelId: 'manual-1',
          displayName: 'My Model',
          createdAt: DateTime(2026, 10, 19),
        ),
      );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          manualModelRepositoryProvider.overrideWithValue(repo),
          sharedPreferencesProvider.overrideWithValue(prefs),
          availableModelsProvider(
            's1',
          ).overrideWith((ref) async => const <ModelInfo>[]),
        ],
        child: _wrap(
          const ModelsSection(
            serverId: 's1',
            serverType: ServerType.openAICompatible,
            isEditing: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('My Model'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('remove_manual_model_manual-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('My Model'), findsNothing);
    expect(repo.listForServer('s1'), isEmpty);
  });

  testWidgets('add mode stages rows until Save', (tester) async {
    final repo = ManualModelRepository(InMemoryManualModelStore());
    var staged = const <ManualModel>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          manualModelRepositoryProvider.overrideWithValue(repo),
          availableModelsProvider(
            'pending',
          ).overrideWith((ref) async => const <ModelInfo>[]),
        ],
        child: _wrap(
          ModelsSection(
            serverId: 'pending',
            serverType: ServerType.openAICompatible,
            isEditing: false,
            onPendingChanged: (rows) => staged = rows,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('models_section_add')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('manual_model_id_field')),
      'manual-2',
    );
    await tester.enterText(
      find.byKey(const ValueKey('manual_model_name_field')),
      'Second Model',
    );
    await tester.tap(find.byKey(const ValueKey('manual_model_save')));
    await tester.pumpAndSettle();

    expect(staged, hasLength(1));
    expect(staged.single.modelId, 'manual-2');
    expect(repo.listForServer('pending'), isEmpty);
  });
}
