import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/fork_anchor.dart';
import '../views/components/fork_chat_panel.dart';
import 'fork_chat_notifier.dart';

const ValueKey<String> kForkPanelContainerKey =
    ValueKey<String>('fork_panel_container');

/// Band-anchored placement solver (task 5 of the fork-tools work). Pure and
/// unit-testable: the panel prefers to hover ABOVE the highlight band (its
/// bottom exactly 8px clear of the band's top), falls back to below, and
/// clamps to the chat screen's safe area when neither window fits — the
/// gesture-bar zone (`safePadding.bottom + 8`) must never be covered.
class ForkPanelGeometry {
  const ForkPanelGeometry._();

  /// Clear gap between the panel and the band edge / safe-area edge.
  static const double edgeGap = 8;

  /// Horizontal inset floor for the panel inside the host surface.
  static const double sidePadding = 12;

  /// Panel scroll surface cap — 60% of the app's host height (UX 7).
  static const double maxHeightFraction = 0.6;

  /// Panel's natural content height under the height cap.
  static const double naturalHeight = 420;

  /// Solves the panel's top-left [Offset] inside the host surface.
  ///
  /// Order of preference: above → below → clamped (hug the top-safe edge).
  /// When the panel fits nowhere the vertically-preferred pose (above) wins
  /// against the max-allowable bottom clamp, then the top safe edge floors
  /// the result — a degenerate (taller-than-host) panel still starts in
  /// view. Horizontally the panel centers on the band between the side
  /// padding floors.
  static Offset solve({
    required Rect bandRect,
    required Size hostSize,
    required EdgeInsets safePadding,
    required Size panelSize,
  }) {
    final topFloor = safePadding.top + edgeGap;
    final maxAllowableTop =
        hostSize.height - safePadding.bottom - edgeGap - panelSize.height;
    final preferredAbove = bandRect.top - edgeGap - panelSize.height;
    final belowTop = bandRect.bottom + edgeGap;

    double top;
    if (preferredAbove >= topFloor) {
      top = preferredAbove;
    } else if (belowTop <= maxAllowableTop && belowTop >= topFloor) {
      top = belowTop;
    } else {
      top = math.max(
        math.min(preferredAbove, maxAllowableTop),
        topFloor,
      );
    }

    final maxLeft = math.max(
      sidePadding,
      hostSize.width - panelSize.width - sidePadding,
    );
    final left = (bandRect.center.dx - panelSize.width / 2)
        .clamp(sidePadding, maxLeft)
        .toDouble();
    return Offset(left, top);
  }

  /// The panel's Positioned extent: width = min(560, hostWidth - 24) and
  /// height capped at [maxHeightFraction] of the safe host height.
  static ({double width, double height}) panelExtent({
    required Size hostSize,
    required EdgeInsets safePadding,
  }) {
    final safeHeight = hostSize.height - safePadding.vertical;
    return (
      width: math.min(560.0, hostSize.width - 24),
      height: math.min(naturalHeight, safeHeight * maxHeightFraction),
    );
  }

  /// Pose used when the band rect could not be measured (render object
  /// unmounted between tap and open): a horizontal-center band just under
  /// the top safe edge, so the solver drops the panel below it.
  static Rect fallbackBandRect({
    required Size hostSize,
    required EdgeInsets safePadding,
  }) {
    final y = safePadding.top + edgeGap;
    return Rect.fromLTRB(hostSize.width / 2, y, hostSize.width / 2, y + 40);
  }
}

/// State of the anchored fork panel overlay: hidden, or shown with the
/// [ForkAnchor] the panel must present plus the measured highlight-band
/// [Rect] (host coordinates) it anchors to.
class ForkPanelOverlayState {
  const ForkPanelOverlayState({this.anchor, this.bandRect});

  final ForkAnchor? anchor;

  /// Measured band rect in the root overlay's coordinates; null when the
  /// measurement raced an unmount (the host then uses its fallback pose).
  final Rect? bandRect;

  bool get isOpen => anchor != null;
}

/// Drives the single band-anchored fork panel overlay ("band-anchored
/// fork panel" — task 5).
///
/// Contract: at most ONE [OverlayEntry] may exist at a time. [open] with
/// the anchor id that is currently shown is a no-op (id-guard); opening a
/// different anchor swaps the single entry. [close] removes the entry and
/// resets the state, settling any pending in-panel tool approval as a
/// denial, without touching persisted fork data.
class ForkPanelOverlayController extends Notifier<ForkPanelOverlayState> {
  OverlayState? _overlay;
  OverlayEntry? _entry;

  /// Field bookkeeping (NOT state reads) — the teardown callback runs
  /// inside riverpod-3's container dispose where `state` access asserts.
  ForkAnchor? _openAnchor;

  @override
  ForkPanelOverlayState build() {
    ref.onDispose(_teardown);
    return const ForkPanelOverlayState();
  }

  /// Registers the [OverlayState] the panel inserts into. Assistant
  /// bubbles call this once their layer resolves; the shell overlay
  /// outlives individual messages, so the first attach wins.
  void attach(OverlayState overlay) => _overlay ??= overlay;

  /// Opens (or swaps) the anchored panel. [bandRect] is the measured
  /// highlight-band (or fallback chip) rect in root coordinates; null
  /// falls back to the geometry solver's default pose.
  void open(ForkAnchor anchor, {Rect? bandRect}) {
    final current = _openAnchor;
    if (current != null && current.id == anchor.id && _entry != null) {
      return;
    }
    if (current != null) {
      _settlePendingApproval(current);
    }
    close();
    final overlay = _overlay;
    if (overlay == null) {
      return;
    }
    _openAnchor = anchor;
    state = ForkPanelOverlayState(anchor: anchor, bandRect: bandRect);
    _entry = OverlayEntry(
      builder: (entryContext) => _ForkPanelOverlayHost(
        anchor: anchor,
        bandRect: bandRect,
        onClose: close,
      ),
    );
    overlay.insert(_entry!);
  }

  void close() {
    final anchor = _openAnchor;
    if (anchor != null) {
      _settlePendingApproval(anchor);
    }
    final OverlayEntry? entry = _entry;
    _openAnchor = null;
    _entry = null;
    // The entry may already be gone (overlay dispose racing a teardown, or
    // a close() that follows an external removeCollection) — removal must
    // tolerate that instead of asserting.
    if (entry != null && entry.mounted) {
      entry.remove();
    }
    if (state.isOpen) {
      state = const ForkPanelOverlayState();
    }
  }

  void _teardown() {
    // Riverpod 3: this runs INSIDE the container dispose — no provider
    // reads and no state writes are legal here. A panel open across a
    // container teardown loses its settle capability at controller level;
    // the fork notifier's own dispose mirror settles any completer.
    _openAnchor = null;
    final OverlayEntry? entry = _entry;
    _entry = null;
    _overlay = null;
    if (entry != null && entry.mounted) {
      entry.remove();
    }
  }

  /// Best-effort: a panel closing over a pending tool approval DENIES it so
  /// the awaiting fork exchange settles (no dangling completer, no pending
  /// leak into the main feed — nothing touches chatNotifier's own approval
  /// stream). Provider-container teardown may make this read impossible;
  /// that is tolerated.
  void _settlePendingApproval(ForkAnchor? anchor) {
    if (anchor == null) return;
    try {
      ref
          .read(forkChatNotifierProvider(anchor.forkConversationId).notifier)
          .settlePendingApproval();
    } catch (_) {}
  }
}

final forkPanelOverlayProvider =
    NotifierProvider<ForkPanelOverlayController, ForkPanelOverlayState>(
      ForkPanelOverlayController.new,
    );

class _ForkPanelOverlayHost extends StatelessWidget {
  const _ForkPanelOverlayHost({
    required this.anchor,
    required this.bandRect,
    required this.onClose,
  });

  final ForkAnchor anchor;

  /// Measured band rect at open time (host coordinates); null → the
  /// geometry solver's fallback pose.
  final Rect? bandRect;
  final VoidCallback onClose;

  /// The safe area in the ROOT overlay surface's coordinate space:
  /// `viewPadding` survives any SafeArea consumption between the chat
  /// content and the root, so the per-edge max against `padding` yields the
  /// true display insets for both raw and consumed contexts.
  static EdgeInsets _effectiveSafePadding(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    if (media == null) return EdgeInsets.zero;
    final data = MediaQuery.of(context);
    return EdgeInsets.fromLTRB(
      math.max(data.padding.left, data.viewPadding.left),
      math.max(data.padding.top, data.viewPadding.top),
      math.max(data.padding.right, data.viewPadding.right),
      math.max(data.padding.bottom, data.viewPadding.bottom),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaData = MediaQuery.maybeOf(context);
    final hostSize = mediaData?.size ?? MediaQuery.sizeOf(context);
    final safePadding = _effectiveSafePadding(context);
    final measuredBand =
        bandRect ??
        ForkPanelGeometry.fallbackBandRect(
          hostSize: hostSize,
          safePadding: safePadding,
        );
    final extent = ForkPanelGeometry.panelExtent(
      hostSize: hostSize,
      safePadding: safePadding,
    );
    final topLeft = ForkPanelGeometry.solve(
      bandRect: measuredBand,
      hostSize: hostSize,
      safePadding: safePadding,
      panelSize: Size(extent.width, extent.height),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: topLeft.dx,
          top: topLeft.dy,
          width: extent.width,
          height: extent.height,
          child: Container(
            key: kForkPanelContainerKey,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outline),
            ),
            child: ForkChatPanel(
              anchor: anchor,
              onClose: onClose,
            ),
          ),
        ),
      ],
    );
  }
}

/// Composer-facing auto-close hop (UX 6a): the main composer's focus bridge
/// and send path invoke the returned closure instead of reaching into the
/// overlay controller, so composer widgets stay provider-dumb. Closing is a
/// no-op while the panel is hidden and never touches the fork transcript.
final forkPanelAutoCloseProvider = Provider<void Function()>((ref) {
  return () => ref.read(forkPanelOverlayProvider.notifier).close();
});

/// Listens on a [FocusNode] and folds the fork panel away whenever that
/// node gains focus (UX 6a: main-composer focus closes the anchored fork
/// chat). Mounted once around the chat screen's body; the close itself is
/// a plain provider hop via [forkPanelAutoCloseProvider], so this widget
/// knows nothing about the panel's internals. Order guarantee: the listener
/// runs synchronously in the focus event, BEFORE any keyboard/viewport
/// animation the focus gain schedules, so the panel is gone before hit-
/// testing regions change under it.
class ForkPanelAutoCloseBridge extends ConsumerStatefulWidget {
  const ForkPanelAutoCloseBridge({
    super.key,
    required this.focusNode,
    required this.child,
  });

  final FocusNode focusNode;
  final Widget child;

  @override
  ConsumerState<ForkPanelAutoCloseBridge> createState() =>
      _ForkPanelAutoCloseBridgeState();
}

class _ForkPanelAutoCloseBridgeState
    extends ConsumerState<ForkPanelAutoCloseBridge> {
  void _handleFocusChanged() {
    if (widget.focusNode.hasFocus) {
      ref.read(forkPanelAutoCloseProvider)();
    }
  }

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(ForkPanelAutoCloseBridge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      oldWidget.focusNode.removeListener(_handleFocusChanged);
      widget.focusNode.addListener(_handleFocusChanged);
    }
  }

  @override
  void dispose() {
    // removeListener is documented to tolerate disposed focus nodes, so no
    // mounted guard is needed here.
    widget.focusNode.removeListener(_handleFocusChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
