import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/models/enums.dart';
import 'package:localmind/core/providers/storage_providers.dart';
import 'package:localmind/features/chat/data/fork_service.dart';
import 'package:localmind/features/chat/data/models/chat_parameters.dart';
import 'package:localmind/features/chat/data/models/fork_anchor.dart';
import 'package:localmind/features/chat/data/models/message.dart';
import 'package:localmind/features/chat/providers/chat_providers.dart';
import 'package:localmind/features/chat/providers/fork_panel_overlay.dart';
import 'package:localmind/features/chat/views/components/chat_bubble/assistant_bubble.dart';
import 'package:localmind/features/servers/data/models/server.dart';
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

/// Static main timeline for assistant_bubble's fork-creation gate: the gate
/// resolves the anchor through ChatNotifier.mainTimelineUpTo. A seed list
/// that omits the bubble's message simulates an inactive-variant bubble.
class _StaticMainChatNotifier extends ChatNotifier {
  _StaticMainChatNotifier({required this.seed});

  final List<Message> seed;

  @override
  ChatState build() =>
      ChatState(messages: List.of(seed), allMessages: List.of(seed));
}

Server _remoteServer() {
  return Server(
    id: 'remote',
    name: 'Remote',
    type: ServerType.ollama,
    host: '127.0.0.1',
    port: 11434,
    createdAt: DateTime(2026, 10, 5),
    lastConnectedAt: DateTime(2026, 10, 5),
    status: ConnectionStatus.connected,
  );
}

Message _assistantMessage(
  String content, {
  String id = 'msg-done',
  String conversationId = 'conv-1',
  MessageStatus status = MessageStatus.complete,
  String? errorMessage,
}) {
  return Message(
    id: id,
    conversationId: conversationId,
    role: MessageRole.assistant,
    content: content,
    createdAt: DateTime(2026),
    status: status,
    errorMessage: errorMessage,
  );
}

Widget _buildHarness({
  required SharedPreferences prefs,
  required Message message,
  required _FakeForkService service,
  List<Message>? mainSeed,
}) {
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      forkServiceProvider.overrideWithValue(service),
      activeChatTargetProvider.overrideWithValue(
        ActiveChatTarget(
          server: _remoteServer(),
          selectedModel: null,
          effectiveModelId: 'model',
          modelLabel: 'Model',
        ),
      ),
      chatParamsProvider.overrideWithValue(ChatParameters.defaults()),
      chatProvider.overrideWith(
        () => _StaticMainChatNotifier(seed: mainSeed ?? [message]),
      ),
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
    'fork action is gated to fully completed bubbles: an error bubble with '
    'partial content offers Copy but no fork (fix 4)',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = _FakeForkService(const []);
      await tester.pumpWidget(
        _buildHarness(
          prefs: prefs,
          message: _assistantMessage(
            'Partial stream kept in the transcript',
            status: MessageStatus.error,
            errorMessage: 'stream died',
          ),
          service: service,
        ),
      );
      await tester.pump();

      await tester.longPress(find.text('Partial stream kept in the transcript'));
      await tester.pumpAndSettle();

      expect(find.byType(SelectionArea), findsOneWidget);
      expect(find.text('Fork from this selection'), findsNothing);
      expect(find.text('Copy'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fork creation is rejected with a visible error when the message left '
    'the active timeline — no anchor row persists (fix 3)',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = _FakeForkService(const []);
      await tester.pumpWidget(
        _buildHarness(
          prefs: prefs,
          message: _assistantMessage('Ada Lovelace wrote it'),
          service: service,
          // The bubble message is OFF the resolved timeline (inactive
          // variant): _StaticMainChatNotifier never surfaces it.
          mainSeed: const [],
        ),
      );
      await tester.pump();

      await tester.longPress(find.text('Ada Lovelace wrote it'));
      await tester.pumpAndSettle();
      tester
          .state<SelectableRegionState>(find.byType(SelectableRegion))
          .selectAll(SelectionChangedCause.toolbar);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Fork from this selection'));
      await tester.pumpAndSettle();

      expect(service.createCalls, 0, reason: 'no anchor row persists');
      final container = _containerOf(tester);
      expect(container.read(forkPanelOverlayProvider).isOpen, isFalse);
      expect(find.byKey(kForkPanelContainerKey), findsNothing);
      // The rejection is visible, not silent.
      expect(
        find.textContaining("This selection's anchor is unavailable"),
        findsOneWidget,
      );
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

      // The harness long-press only word-selects ('Lovelace'). Drive the
      // toolbar's Select All route so the live selection covers the whole
      // paragraph, then fork: the captured span must equal the anchor text.
      tester
          .state<SelectableRegionState>(find.byType(SelectableRegion))
          .selectAll(SelectionChangedCause.toolbar);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Fork from this selection'));
      await tester.pumpAndSettle();

      expect(service.createCalls, 1);
      expect(service.lastAnchorMessageId, 'msg-done');
      // The exact captured span must equal what the user selected — it is
      // stored verbatim as the anchor's `selectedText` (highlight-band key).
      expect(service.lastSelection, 'Ada Lovelace wrote it');

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

  testWidgets(
    ' disposing the provider container while the panel is open removes its overlay entry',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          forkServiceProvider.overrideWithValue(
            _FakeForkService([await _seedAnchor()]),
          ),
        ],
      );
      // Disposing here (not via addTearDown) IS the behavior under test.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ListView(
                children: [
                  const SizedBox(height: 40),
                  AssistantBubble(
                    message: _assistantMessage(
                      'Intro line up top.\nAda Lovelace wrote it\nOutro line down low.',
                    ),
                    isStreaming: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(kForkPanelContainerKey), findsOneWidget);

      // Dispose while open: the controller teardown must remove the entry
      // and tolerate being torn down rather than leave it dangling.
      container.dispose();
      await tester.pump();

      expect(find.byKey(kForkPanelContainerKey), findsNothing);
    },
  );

  testWidgets('chip fallback clips at the grapheme boundary, never inside a surrogate pair', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final selection = 'x' * 31 + '😀'; // 33 UTF-16 units; char 32 would split the pair
    final service = _FakeForkService([
      await _seedAnchor(id: 'anchor-surrogate', selectedText: selection),
    ]);
    // Content does not contain the selection verbatim → chip fallback path.
    await tester.pumpWidget(
      _buildHarness(
        prefs: prefs,
        message: _assistantMessage('A completely different body text.'),
        service: service,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('fork_chip_anchor-surrogate')),
      findsOneWidget,
    );
    // The clipped label still ends with the intact emoji — a split surrogate
    // would not be findable as the composed character.
    expect(find.textContaining('😀'), findsOneWidget);
  });
}
