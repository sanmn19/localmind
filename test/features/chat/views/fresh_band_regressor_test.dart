import 'dart:async';

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

/// Regression harness for the device report: a freshly created fork never
/// renders its highlight band (and the anchored text stays untappable),
/// while persisted anchors at mount keep rendering. `fork_selection_test`'s
/// fake resolves `anchorsFor` instantly, hiding the real store's async
/// window (`runInTransactionAsync` spawns an isolate per read/write) —
/// every read here is gated behind a completer the test releases exactly
/// when the store round-trip would land on device.
class _GatedForkService extends ForkService {
  _GatedForkService(List<ForkAnchor> seed) : seed = List.of(seed);

  /// Mutable copy: createFork appends the freshly minted anchor so the
  /// post-invalidate re-read surfaces it (same contract as the instant
  /// fake in fork_selection_test).
  final List<ForkAnchor> seed;
  int createCalls = 0;
  String? lastSelection;

  final List<Completer<List<ForkAnchor>>> _readGates = [];

  /// Resolves every pending anchorsFor read with the CURRENT seed —
  /// mirroring the moment the store round-trip lands on device.
  void flushReads() {
    final flush = List.of(seed);
    final gates = List.of(_readGates);
    _readGates.clear();
    for (final gate in gates) {
      gate.complete(flush);
    }
  }

  int get pendingReads => _readGates.length;

  @override
  Future<List<ForkAnchor>> anchorsFor(String mainConversationId) {
    final gate = Completer<List<ForkAnchor>>();
    _readGates.add(gate);
    return gate.future;
  }

  @override
  Future<ForkAnchor> createFork({
    required String mainConversationId,
    required String anchorMessageId,
    required String selectedText,
  }) async {
    createCalls++;
    lastSelection = selectedText;
    final anchor = ForkAnchor(
      id: 'anchor-new-$createCalls',
      mainConversationId: mainConversationId,
      anchorMessageId: anchorMessageId,
      selectedText: selectedText,
      forkConversationId: 'fork-new-$createCalls',
      createdAt: DateTime(2026, 10, 8, 12),
    );
    seed.add(anchor);
    return anchor;
  }
}

/// Errors the NEXT `flushReads()`-released read once (the device shape:
/// a re-read landing inside the write's isolate window throws), then
/// returns to the clean gated behavior.
class FlakyOnceGatedForkService extends _GatedForkService {
  FlakyOnceGatedForkService(super.seed);

  bool nextReadFails = false;

  @override
  Future<List<ForkAnchor>> anchorsFor(String mainConversationId) {
    if (nextReadFails) {
      nextReadFails = false;
      return Future.error(StateError('simulated readable-store window clash'));
    }
    return super.anchorsFor(mainConversationId);
  }
}

/// Static main timeline for assistant_bubble's fork-creation gate: the
/// gate resolves the anchor through ChatNotifier.mainTimelineUpTo. A seed
/// list that omits the bubble's message simulates an inactive-variant bubble.
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
  required _GatedForkService service,
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
        () => _StaticMainChatNotifier(seed: [message]),
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

Future<void> _tapForkFromWholeSelection(WidgetTester tester) async {
  await tester.longPress(find.text('Ada Lovelace wrote it'));
  await tester.pumpAndSettle();
  // The harness long-press only word-selects; drive Select All so the
  // captured span covers the whole paragraph (matches the user flow and
  // the band-matching text).
  tester
      .state<SelectableRegionState>(find.byType(SelectableRegion))
      .selectAll(SelectionChangedCause.toolbar);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Fork from this selection'));
}

/// Advances the test clock by 2 frames (fake-async pumps), the shape the
/// real store round-trip resolves with on device.
Future<void> _advanceTwoFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'fresh fork: band renders once the post-creation anchors re-read lands '
    '(device async window — data empty at tap)',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = _GatedForkService(const []);
      await tester.pumpWidget(
        _buildHarness(
          prefs: prefs,
          message: _assistantMessage('Ada Lovelace wrote it'),
          service: service,
        ),
      );
      await tester.pump();
      // Device-true order: the MOUNT read already resolved (empty anchors)
      // before the user forks.
      service.flushReads();
      await _advanceTwoFrames(tester);
      expect(service.pendingReads, 0);
      expect(
        find.byKey(const ValueKey<String>('fork_band_anchor-new-1')),
        findsNothing,
      );

      // (a) tap the fork-menu action creating the anchor.
      await _tapForkFromWholeSelection(tester);
      // (b) settle the creation + panel open machinery.
      await tester.pumpAndSettle();
      expect(service.createCalls, 1);
      expect(service.lastSelection, 'Ada Lovelace wrote it');

      // The store round-trip lands AFTER the invalidate — 2-frame window.
      service.flushReads();
      await _advanceTwoFrames(tester);

      // The fresh fork's auto-opened panel covers the bubble until the
      // store read lands; closing it mirrors the user's next step.
      final container = _containerOf(tester);
      container.read(forkPanelOverlayProvider.notifier).close();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('fork_band_anchor-new-1')),
        findsOneWidget,
        reason:
            'the band must render when the post-invalidate anchors read '
            'arrives (device report: a fresh fork never renders it)',
      );

      // The band is the reopen path: tapping it opens the anchored panel.
      await tester.tap(
        find.byKey(const ValueKey<String>('fork_band_anchor-new-1')),
      );
      await tester.pumpAndSettle();
      expect(_containerOf(tester).read(forkPanelOverlayProvider).isOpen,
          isTrue);
    },
  );

  testWidgets(
    'pure restart shape: the provider resolves LATE with a persisted anchor '
    'and the band still renders after settle',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = _GatedForkService([
        ForkAnchor(
          id: 'anchor-seed',
          mainConversationId: 'conv-1',
          anchorMessageId: 'msg-done',
          selectedText: 'Ada Lovelace wrote it',
          forkConversationId: 'fork-seed',
          createdAt: DateTime(2026, 10, 8, 12),
        ),
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
      await tester.pump();
      expect(service.pendingReads, 1, reason: 'initial anchors read pending');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
        findsNothing,
        reason: 'the read is still in flight — no band yet',
      );

      // Restart shape: the read lands late with the persisted anchors.
      service.flushReads();
      await _advanceTwoFrames(tester);
      expect(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
        findsOneWidget,
      );

      // …and the band remains tappable to reopen (restart parity).
      await tester.tap(
        find.byKey(const ValueKey<String>('fork_band_anchor-seed')),
      );
      await tester.pumpAndSettle();
      expect(_containerOf(tester).read(forkPanelOverlayProvider).isOpen,
          isTrue);
    },
  );

  testWidgets(
    'red case: the post-invalidate re-read ERRORS once (device isolate '
    'window) — the fresh fork must still surface its band, not vanish '
    'forever',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = FlakyOnceGatedForkService(const []);
      await tester.pumpWidget(
        _buildHarness(
          prefs: prefs,
          message: _assistantMessage('Ada Lovelace wrote it'),
          service: service,
        ),
      );
      await tester.pump();
      // Mount read resolves clean (device-true order: empty anchors at tap).
      service.flushReads();
      await _advanceTwoFrames(tester);
      expect(service.pendingReads, 0);

      // The re-read that the creation path fires errors ONCE (ObjectBox's
      // runInTransactionAsync isolate window clashing the fresh write).
      // Prior code collapses that generation into `const []` FOREVER: no
      // band, no chip, no tap target — the exact device report. Error-typed
      // failures also bypass riverpod 3's default container retry (it skips
      // `Error` subclasses), so the swallow needs an explicit retry.
      service.nextReadFails = true;
      await _tapForkFromWholeSelection(tester);
      await tester.pumpAndSettle();
      expect(service.createCalls, 1, reason: 'creation succeeded — the fork');
      expect(service.lastSelection, 'Ada Lovelace wrote it');
      service.nextReadFails = false;

      service.flushReads();
      await _advanceTwoFrames(tester);

      expect(
        find.byKey(const ValueKey<String>('fork_band_anchor-new-1')),
        findsOneWidget,
        reason:
            'a succeeded creation must not be silently swallowed by an '
            'errored anchors read — the bounded retry must surface the band',
      );
      final container = _containerOf(tester);
      container.read(forkPanelOverlayProvider.notifier).close();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('fork_band_anchor-new-1')),
      );
      await tester.pumpAndSettle();
      expect(_containerOf(tester).read(forkPanelOverlayProvider).isOpen,
          isTrue);
    },
  );
}
