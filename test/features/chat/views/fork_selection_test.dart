import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/features/chat/data/fork_service.dart';
import 'package:localmind/features/chat/data/models/fork_anchor.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/providers/fork_panel_overlay.dart';
import 'package:localmind/features/chat/views/components/chat_bubble/assistant_bubble.dart';
import 'package:localmind/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeForkService extends ForkService {
  _FakeForkService(this.seed) : super();

  final List<ForkAnchor> seed;
  int createCalls = 0;
  String? lastSelection;
  String? lastAnchorMessageId;

  @override
  Future<ForkAnchor> createFork({
    required String mainConversationId,
    required String anchorMessageId,
    required String selectedText,
  }) async {
    createCalls++;
    lastSelection = selectedText;
    lastAnchorMessageId = anchorMessageId;
    return ForkAnchor(
      id: 'anchor-new-$createCalls',
      mainConversationId: mainConversationId,
      anchorMessageId: anchorMessageId,
      selectedText: selectedText,
      forkConversationId: 'fork-new-$createCalls',
      createdAt: DateTime(2026, 10, 8, 12),
    );
  }

  @override
  Future<List<ForkAnchor>> anchorsFor(String mainConversationId) async => seed;
}

Message _assistantMessage(
  String content, {
  String id = 'msg-done',
  String conversationId = 'conv-1',
}) {
  return Message(
    id: id,
    conversationId: conversationId,
    role: MessageRole.assistant,
    content: content,
    createdAt: DateTime(2026),
    status: MessageStatus.complete,
  );
}

Widget _buildHarness({
  required SharedPreferences prefs,
  required Message message,
  required _FakeForkService service,
}) {
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      forkServiceProvider.overrideWithValue(service),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: AssistantBubble(message: message, isStreaming: false),
        ),
      ),
    ),
  );
}

ProviderContainer _containerOf(WidgetTester tester) {
  return ProviderScope.containerOf(
    tester.element(find.byType(AssistantBubble)),
  );
}

Future<ForkAnchor> _seedAnchor({
  String id = 'anchor-seed',
  String selectedText = 'Ada Lovelace wrote it',
  String anchorMessageId = 'msg-done',
}) async {
  return ForkAnchor(
    id: id,
    mainConversationId: 'conv-1',
    anchorMessageId: anchorMessageId,
    selectedText: selectedText,
    forkConversationId: 'fork-seed',
    createdAt: DateTime(2026, 10, 8, 12),
  );
}

void main() {
  testWidgets(
    'long selection on a completed bubble offers Fork from this selection',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = _FakeForkService(const []);
      await tester.pumpWidget(
        _buildHarness(
          prefs: prefs,
          message: _assistantMessage('Ada Lovelace wrote it'),
          service: service,
        ),
      );
      await tester.pump();

      await tester.longPress(find.text('Ada Lovelace wrote it'));
      await tester.pumpAndSettle();

      expect(find.byType(SelectionArea), findsOneWidget);
      expect(find.text('Fork from this selection'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
    },
  );

  testWidgets(
    'tapping the fork menu action creates an anchor and opens the overlay',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = _FakeForkService(const []);
      await tester.pumpWidget(
        _buildHarness(
          prefs: prefs,
          message: _assistantMessage('Ada Lovelace wrote it'),
          service: service,
        ),
      );
      await tester.pump();

      await tester.longPress(find.text('Ada Lovelace wrote it'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fork from this selection'));
      await tester.pumpAndSettle();

      expect(service.createCalls, 1);
      expect(service.lastAnchorMessageId, 'msg-done');
      expect(service.lastSelection, isNotEmpty);

      final container = _containerOf(tester);
      final state = container.read(forkPanelOverlayProvider);
      expect(state.isOpen, isTrue);
      expect(state.anchor, isNotNull);
      expect(find.byKey(kForkPanelContainerKey), findsOneWidget);

      container.read(forkPanelOverlayProvider.notifier).close();
      await tester.pumpAndSettle();
      expect(find.byKey(kForkPanelContainerKey), findsNothing);
      expect(container.read(forkPanelOverlayProvider).isOpen, isFalse);
    },
  );

  testWidgets('seeded anchor renders the yellow band around the matching lines; tapping it reopens the panel', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = _FakeForkService([
      await _seedAnchor(),
    ]);
    await tester.pumpWidget(
      _buildHarness(
        prefs: prefs,
        message: _assistantMessage(
          'Intro line up top.\nAda Lovelace wrote it\nOutro line down low.',
        ),
        service: service,
      ),
    );
    await tester.pumpAndSettle();

    final bandKey = const ValueKey<String>('fork_band_anchor-seed');
    final band = tester.widget<Container>(find.byKey(bandKey));
    expect(band.color, kForkHighlightColor);

    expect(
      find.text('Intro line up top.'),
      findsOneWidget,
    );
    expect(find.text('Outro line down low.'), findsOneWidget);

    await tester.tap(find.byKey(bandKey));
    await tester.pumpAndSettle();

    final container = _containerOf(tester);
    final state = container.read(forkPanelOverlayProvider);
    expect(state.isOpen, isTrue);
    expect(state.anchor?.id, 'anchor-seed');
    expect(state.anchor?.forkConversationId, 'fork-seed');
    expect(find.byKey(kForkPanelContainerKey), findsOneWidget);
  });

  testWidgets('anchor whose span is inside a code fence falls back to the chip', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = _FakeForkService([
      await _seedAnchor(id: 'anchor-inside-fence', selectedText: 'fenced body line'),
    ]);
    await tester.pumpWidget(
      _buildHarness(
        prefs: prefs,
        message: _assistantMessage(
          'alpha intro\n```python\nfenced body line\n```\ntail after block',
        ),
        service: service,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('fork_band_anchor-inside-fence')), findsNothing);
    final chipKey = const ValueKey<String>('fork_chip_anchor-inside-fence');
    await tester.tap(find.byKey(chipKey));
    await tester.pumpAndSettle();

    final container = _containerOf(tester);
    expect(container.read(forkPanelOverlayProvider).isOpen, isTrue);
  });

  testWidgets('anchor spanning a closed fence pair falls back to the chip (fence counts differ)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = _FakeForkService([
      await _seedAnchor(id: 'anchor-after-fence', selectedText: 'the fork line'),
    ]);
    await tester.pumpWidget(
      _buildHarness(
        prefs: prefs,
        message: _assistantMessage('```\ncode A\n```\nthe fork line'),
        service: service,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('fork_band_anchor-after-fence')), findsNothing);
    expect(
        find.byKey(const ValueKey<String>('fork_chip_anchor-after-fence')),
        findsOneWidget);
  });

  testWidgets('outside tap closes the anchored overlay without deleting the anchor', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = _FakeForkService([
      await _seedAnchor(),
    ]);
    await tester.pumpWidget(
      _buildHarness(
        prefs: prefs,
        message: _assistantMessage(
          'Intro line up top.\nAda Lovelace wrote it\nOutro line down low.',
        ),
        service: service,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('fork_band_anchor-seed')));
    await tester.pumpAndSettle();
    expect(find.byKey(kForkPanelContainerKey), findsOneWidget);

    await tester.tapAt(const Offset(760, 16));
    await tester.pumpAndSettle();

    final container = _containerOf(tester);
    expect(find.byKey(kForkPanelContainerKey), findsNothing);
    expect(container.read(forkPanelOverlayProvider).isOpen, isFalse);
  });

  testWidgets('overlay controller keeps at most one entry and guards re-open of the same anchor', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = _FakeForkService(const []);
    await tester.pumpWidget(
      _buildHarness(
        prefs: prefs,
        message: _assistantMessage('Ada Lovelace wrote it'),
        service: service,
      ),
    );
    await tester.pump();

    final container = _containerOf(tester);
    final controller = container.read(forkPanelOverlayProvider.notifier);
    final anchorA = await _seedAnchor(id: 'anchor-a');
    final anchorB = await _seedAnchor(
      id: 'anchor-b',
      selectedText: 'Ada Lovelace wrote it',
      anchorMessageId: 'msg-done',
    );

    controller.open(anchorA, LayerLink());
    await tester.pump();
    expect(find.byKey(kForkPanelContainerKey), findsOneWidget);

    controller.open(anchorA, LayerLink());
    await tester.pump();
    expect(find.byKey(kForkPanelContainerKey), findsOneWidget);

    controller.open(anchorB, LayerLink());
    await tester.pump();
    expect(find.byKey(kForkPanelContainerKey), findsOneWidget);

    controller.close();
    await tester.pump();
    expect(find.byKey(kForkPanelContainerKey), findsNothing);
    expect(container.read(forkPanelOverlayProvider).isOpen, isFalse);
  });
}
