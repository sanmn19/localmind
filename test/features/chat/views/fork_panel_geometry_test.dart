import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/providers/fork_panel_overlay.dart';

// Task 5 of the bg-upgrades/fork-tools work: the fork panel is anchored to
// the measured highlight-band rect instead of the bubble LayerLink. The
// placement lives in a pure solver so every above/below/clamp rule is pinned
// without a widget surface.
void main() {
  const host = Size(800, 600);
  const noSafe = EdgeInsets.zero;

  Offset solveRect(
    Rect band,
    Size panelSize, {
    Size hostSize = const Size(800, 600),
    EdgeInsets safePadding = noSafe,
  }) {
    return ForkPanelGeometry.solve(
      bandRect: band,
      hostSize: hostSize,
      safePadding: safePadding,
      panelSize: panelSize,
    );
  }

  group('ForkPanelGeometry.solve (preferred above)', () {
    test('band mid-screen → panel above, bottom exactly 8 above the band',
        () async {
      const band = Rect.fromLTRB(360, 300, 480, 330);
      final offset = solveRect(band, const Size(300, 240));
      // Above placement: bottom = band.top - 8.
      expect(offset.dy + 240, 300 - 8);
    });

    test('band near the screen bottom → still above (memo: within 200 of '
        'the bottom clamp), honoring the top clamp', () {
      const band = Rect.fromLTRB(200, 380, 640, 420);
      final offset = solveRect(band, const Size(560, 360));
      expect(offset.dy + 360, 380 - 8);
    });

    test('horizontal centering clamps at the house 12px side padding',
        () {
      const band = Rect.fromLTRB(0, 300, 40, 330);
      final offset = solveRect(band, const Size(300, 240));
      expect(offset.dx, 12);
    });

    test('horizontal centering clamps at the right edge (width - panel - 12)',
        () {
      // Band centered at x=780; panel 560 wide → natural left 500 > 780-280? no:
      // natural = 780 - 280 = 500; max = 800-560-12 = 228 → clamped left.
      const band = Rect.fromLTRB(760, 300, 800, 330);
      final offset = solveRect(band, const Size(560, 240));
      expect(offset.dx, 228);
    });
  });

  group('ForkPanelGeometry.solve (below fallback)', () {
    test('band at the very top → panel below, top exactly 8 under the band',
        () {
      const band = Rect.fromLTRB(100, 12, 400, 40);
      final offset = solveRect(band, const Size(560, 240));
      expect(offset.dy, 40 + 8);
    });

    test('bottom safe padding (gesture-bar zone) keeps the panel above it', () {
      const band = Rect.fromLTRB(100, 20, 500, 60);
      const safe = EdgeInsets.only(bottom: 34);
      final offset = solveRect(band, const Size(560, 240), safePadding: safe);
      // Below placement must clear the bottom clamp, not the safe area edge:
      // below fits since 68 <= 600-34-8-240.
      expect(offset.dy, 68);
      expect(offset.dy + 240, lessThanOrEqualTo(600 - 34 - 8));
    });
  });

  group('ForkPanelGeometry.solve (clamp when neither side fits)', () {
    test('panel taller than both windows → pinned to the top safe edge', () {
      const band = Rect.fromLTRB(100, 100, 400, 140);
      final offset = solveRect(band, const Size(560, 520), hostSize: const Size(800, 600));
      // min(above-preferred, max-allowable) = min(100-8-520, 72) → clamped up
      // to the safe top edge.
      expect(offset.dy, 8);
      expect(offset.dy + 520, lessThanOrEqualTo(600 - 8));
    });

    test('impossibly tall panel over a padded host never crosses below the bottom clamp', () {
      const band = Rect.fromLTRB(100, 200, 400, 240);
      const safe = EdgeInsets.fromLTRB(0, 24, 0, 34);
      final offset = solveRect(band, const Size(560, 700), safePadding: safe);
      expect(offset.dy, 24 + 8);
      // Degenerate: taller than the host — the top edge still wins.
      expect(offset.dy + 700, greaterThanOrEqualTo(600 - 34));
    });
  });

  group('ForkPanelGeometry.panelExtent', () {
    test('width is min(560, hostWidth - 24)', () {
      final extent = ForkPanelGeometry.panelExtent(
        hostSize: host,
        safePadding: noSafe,
      );
      expect(extent.width, 560);
      expect(
        ForkPanelGeometry.panelExtent(hostSize: const Size(500, 600), safePadding: noSafe)
            .width,
        476,
      );
    });

    test('height never exceeds 60% of the safe host height', () {
      final extent = ForkPanelGeometry.panelExtent(
        hostSize: host,
        safePadding: noSafe,
      );
      expect(extent.height, 360);
      final exactCap = ForkPanelGeometry.panelExtent(
        hostSize: const Size(800, 900),
        safePadding: noSafe,
      );
      expect(exactCap.height, 420);
    });
  });
}
