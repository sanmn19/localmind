import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/providers/app_providers.dart';
import 'package:localmind/features/chat/data/tool_activity_grouping.dart';
import 'package:localmind/features/chat/views/components/message_list/components/tool_activity_block.dart';
import 'package:localmind/features/chat/views/components/reasoning_widget.dart';
import 'package:localmind/features/settings/data/models/app_settings.dart';
import 'package:localmind/l10n/app_localizations.dart';

Widget _pump(ToolActivitySnapshot snapshot) {
  return ProviderScope(
    overrides: [
      settingsProvider.overrideWith(
        () => _MockSettingsNotifier(AppSettings(autoCollapseThinking: true)),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(children: [ToolActivityBlock(snapshot: snapshot)]),
        ),
      ),
    ),
  );
}

class _MockSettingsNotifier extends SettingsNotifier {
  final AppSettings _initial;
  _MockSettingsNotifier(this._initial);

  @override
  AppSettings build() => _initial;
}

ToolActivitySnapshot _snapshotTwoCalls(String? reasoning) {
  return ToolActivitySnapshot(
    calls: [
      const ChainToolCall(
        toolName: 'web.search',
        arguments: {'query': 'flutter riverpod'},
      ),
      ChainToolCall(
        toolName: 'web.fetch',
        arguments: const {'url': 'https://example.com/riv'},
        result: 'long result text ${'x' * 180} END-MARKER',
      ),
    ],
    reasoning: reasoning,
  );
}

/// The expand/collapse size factor of the block itself — the first
/// [SizeTransition] inside the card, before any nested collapsible ones.
double _sizeFactor(WidgetTester tester) {
  final transition = tester
      .widgetList<SizeTransition>(find.byType(SizeTransition))
      .first;
  return transition.sizeFactor.value;
}

void main() {
  testWidgets('collapsed card shows title and call count', (tester) async {
    await tester.pumpWidget(_pump(_snapshotTwoCalls('chain mind')));
    await tester.pumpAndSettle();

    expect(find.text('Web activity'), findsOneWidget);
    expect(find.text('2 calls'), findsOneWidget);
    expect(_sizeFactor(tester), 0.0);
  });

  testWidgets('tapping the header expands the call lines', (tester) async {
    await tester.pumpWidget(_pump(_snapshotTwoCalls(null)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Web activity'));
    await tester.pumpAndSettle();

    expect(_sizeFactor(tester), 1.0);
    expect(find.textContaining('web.search'), findsOneWidget);
    expect(find.textContaining('web.fetch'), findsOneWidget);
    // Arguments render compactly as a single line of JSON.
    expect(find.textContaining('"query"'), findsOneWidget);
    // The result preview is truncated to the first 160 characters: visible,
    // the far end of the result is not, and the ellipsis is there.
    final preview = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((data) => data.contains('long result text'))
        .single;
    expect(preview.endsWith('…'), isTrue);
    expect(preview.contains('END-MARKER'), isFalse);
  });

  testWidgets('expanding again re-collapses the card', (tester) async {
    await tester.pumpWidget(_pump(_snapshotTwoCalls('chain mind')));
    await tester.tap(find.text('Web activity'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Web activity'));
    await tester.pumpAndSettle();

    expect(_sizeFactor(tester), 0.0);
  });

  testWidgets('expanding exposes a thinking section for reasoning', (
    tester,
  ) async {
    await tester.pumpWidget(_pump(_snapshotTwoCalls('chain mind')));
    await tester.tap(find.text('Web activity'));
    await tester.pumpAndSettle();

    expect(find.byType(ReasoningWidget), findsOneWidget);
  });

  testWidgets('expanded card hides thinking when there is no reasoning', (
    tester,
  ) async {
    await tester.pumpWidget(_pump(_snapshotTwoCalls(null)));
    await tester.tap(find.text('Web activity'));
    await tester.pumpAndSettle();

    expect(find.byType(ReasoningWidget), findsNothing);
  });

  testWidgets('result preview truncates to 160 chars with an ellipsis', (
    tester,
  ) async {
    expect(toolCallResultPreview('x' * 200).length, 161);
    expect(toolCallResultPreview('x' * 200).endsWith('…'), isTrue);
    expect(toolCallResultPreview('short'), 'short');
    // Arguments compact to one JSON line; empty argument maps render empty.
    expect(toolCallArgsCompact(const {}), isEmpty);
    expect(toolCallArgsCompact(const {'q': 'riverpod'}), '{"q":"riverpod"}');
  });
}
