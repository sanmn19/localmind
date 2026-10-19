import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/features/models/components/model_tile.dart';
import 'package:localmind/features/models/data/models/model_info.dart';
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

ModelInfo _model(ModelAvailability availability) => ModelInfo(
      id: 'm1',
      name: 'Model One',
      serverType: ServerType.openAICompatible,
      serverId: 's1',
      availability: availability,
    );

void main() {
  testWidgets('unavailable tile is greyed with an Unavailable badge',
      (tester) async {
    await tester.pumpWidget(
      _wrap(
        ModelTile(
          model: _model(ModelAvailability.unavailable),
          isSelected: false,
          isLoaded: false,
          isDark: false,
          onTap: () {},
        ),
      ),
    );

    expect(find.text('Unavailable'), findsOneWidget);
    final opacity = tester.widget<Opacity>(find.byType(Opacity).first);
    expect(opacity.opacity, 0.45);
  });

  testWidgets('available tile has no badge and is fully opaque',
      (tester) async {
    await tester.pumpWidget(
      _wrap(
        ModelTile(
          model: _model(ModelAvailability.available),
          isSelected: false,
          isLoaded: false,
          isDark: false,
          onTap: () {},
        ),
      ),
    );

    expect(find.text('Unavailable'), findsNothing);
    expect(find.text('Load'), findsNothing);
    expect(find.text('Status unknown'), findsNothing);
    final opacity = tester.widget<Opacity>(find.byType(Opacity).first);
    expect(opacity.opacity, 1.0);
  });

  testWidgets('loadable tile shows a Load badge', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ModelTile(
          model: _model(ModelAvailability.loadable),
          isSelected: false,
          isLoaded: false,
          isDark: false,
          onTap: () {},
        ),
      ),
    );

    expect(find.text('Load'), findsOneWidget);
  });
}
