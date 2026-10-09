import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/fork_anchor.dart';

const ValueKey<String> kForkPanelContainerKey =
    ValueKey<String>('fork_panel_container');

/// State of the anchored fork panel overlay: hidden, or shown with the
/// [ForkAnchor] the panel must present plus the bubble [LayerLink] it is
/// pinned to.
class ForkPanelOverlayState {
  const ForkPanelOverlayState({this.anchor, this.layerLink});

  final ForkAnchor? anchor;
  final LayerLink? layerLink;

  bool get isOpen => anchor != null;
}

/// Drives the single anchored fork panel overlay (task-4 structural half;
/// the in-panel chat UI itself lands with task 5).
///
/// Contract: at most ONE [OverlayEntry] may exist at a time. [open] with
/// the anchor id that is currently shown is a no-op (id-guard); opening a
/// different anchor swaps the single entry. [close] removes the entry and
/// resets the state without touching persisted fork data.
class ForkPanelOverlayController extends Notifier<ForkPanelOverlayState> {
  OverlayState? _overlay;
  OverlayEntry? _entry;

  @override
  ForkPanelOverlayState build() {
    ref.onDispose(_teardown);
    return const ForkPanelOverlayState();
  }

  /// Registers the [OverlayState] the panel inserts into. Assistant
  /// bubbles call this once their layer resolves; the shell overlay
  /// outlives individual messages, so the first attach wins.
  void attach(OverlayState overlay) => _overlay ??= overlay;

  void open(ForkAnchor anchor, LayerLink layerLink) {
    if (state.isOpen &&
        state.anchor!.id == anchor.id &&
        _entry != null) {
      return;
    }
    close();
    final overlay = _overlay;
    if (overlay == null) {
      return;
    }
    state = ForkPanelOverlayState(anchor: anchor, layerLink: layerLink);
    _entry = OverlayEntry(
      builder: (entryContext) => _ForkPanelOverlayHost(
        anchor: anchor,
        layerLink: layerLink,
        constraints: _panelConstraints(entryContext),
        onClose: close,
      ),
    );
    overlay.insert(_entry!);
  }

  void close() {
    _entry?.remove();
    _entry = null;
    if (state.isOpen) {
      state = const ForkPanelOverlayState();
    }
  }

  void _teardown() {
    _entry = null;
    _overlay = null;
  }

  static ({double maxWidth, double maxHeight}) _panelConstraints(
    BuildContext context,
  ) {
    final viewport = MediaQuery.sizeOf(context);
    return (
      maxWidth: math.min(560.0, viewport.width - 24),
      maxHeight: viewport.height * 0.6,
    );
  }
}

final forkPanelOverlayProvider =
    NotifierProvider<ForkPanelOverlayController, ForkPanelOverlayState>(
      ForkPanelOverlayController.new,
    );

class _ForkPanelOverlayHost extends StatelessWidget {
  const _ForkPanelOverlayHost({
    required this.anchor,
    required this.layerLink,
    required this.constraints,
    required this.onClose,
  });

  final ForkAnchor anchor;
  final LayerLink layerLink;
  final ({double maxWidth, double maxHeight}) constraints;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxWidth = constraints.maxWidth;
    final maxHeight = constraints.maxHeight;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: layerLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: const Offset(6, 12),
          child: SizedBox.expand(
            child: Align(
              alignment: Alignment.topRight,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxWidth,
                  maxHeight: maxHeight,
                ),
                child: Container(
                  key: kForkPanelContainerKey,
                  width: math.min(420.0, maxWidth),
                  height: math.min(240.0, maxHeight),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.colorScheme.outline),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
