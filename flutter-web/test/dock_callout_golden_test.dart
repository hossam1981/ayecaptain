// Golden capture of the map-anchored dock callout (_DockCallout/_GlassTail in main.dart,
// exposed for testing via debugDockCallout/debugGlassTail — see main.dart). The live browser
// automation in this environment was unreliable for interactive verification this session
// (taps not registering despite a healthy render loop), so this test exists to visually confirm
// the optical-glass material — transparency, backdrop blur of a fake "map" behind it, the
// sweep-gradient border, diagonal reflection, and specular highlights — without depending on
// browser input simulation at all.
//
// Run: flutter test --platform=chrome --update-goldens test/dock_callout_golden_test.dart
// PNGs land in test/goldens/ — inspect them directly; Flutter's deterministic test font means
// "Boat ramp" renders as placeholder glyph blocks, not real text, but every other layer here
// (gradients, blur, CustomPainter strokes) is real rendering, not text.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bayside_flutter/main.dart';

// A busy, colorful stand-in for the map tiles behind the card — if the backdrop blur +
// transparency are working, this should be visible-but-blurred through the card body.
Widget _fakeMap() => Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [Color(0xFFE8ECD8), Color(0xFFBCD7E6), Color(0xFFF2C75C)]),
      ),
      child: CustomPaint(painter: _CheckerPainter()),
    );

class _CheckerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const cell = 24.0;
    final paint = Paint()..color = const Color(0x33114477);
    for (double y = 0; y < size.height; y += cell) {
      for (double x = 0; x < size.width; x += cell) {
        if (((x ~/ cell) + (y ~/ cell)) % 2 == 0) {
          canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CheckerPainter old) => false;
}

Future<void> _pump(WidgetTester tester, Widget child, {double width = 320, double height = 260}) async {
  // devicePixelRatio 1.0 so width/height are logical pixels directly (matches the project's
  // established test pattern in hourly_table_responsive_test.dart) — at 2.0 a physicalSize of
  // 320 renders as only 160 logical px, silently squeezing the fixed-240lp card narrower than
  // its real-app width and invalidating the test (caught via a spurious internal wrap/overflow
  // in the Route-here button at 200% text scale that only reproduced at the wrong width).
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    // The RepaintBoundary wraps the fake map AND the card together, not just the card alone —
    // BackdropFilter only blurs what's painted earlier within the SAME captured layer subtree,
    // so the map has to be inside this boundary for the capture to show the blur-through effect
    // (confirmed: wrapping only the card captured it against a flat, unblurred background).
    child: RepaintBoundary(
      key: const ValueKey('capture'),
      child: Stack(children: [
        Positioned.fill(child: _fakeMap()),
        Center(child: child),
      ]),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _screenshot(WidgetTester tester, String name) async {
  await expectLater(find.byKey(const ValueKey('capture')), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  // The real app always wraps _DockCallout in Positioned(width: _dockPopupW) inside _DockPin's
  // Stack — the card itself doesn't self-impose a width (that's how it stays "fixed ~240lp,
  // content-driven height" rather than hardcoding its own size). debugDockCallout() returns
  // the bare widget, so every test here replicates that same width wrapper with a SizedBox —
  // omitting it collapses the Row's Expanded title/subtitle column to an unbounded-width
  // layout error, not a real app bug (caught and fixed while writing this test).
  testWidgets('boat-ramp callout renders without overflow, fixed width', (tester) async {
    await _pump(tester, SizedBox(width: 240, child: debugDockCallout(kind: DockKind.slipway, name: 'Boat ramp')));
    expect(tester.takeException(), isNull);
    await _screenshot(tester, 'dock_callout_slipway');
  });

  testWidgets('fuel-dock callout with a long name stays fixed-width, ellipsizes', (tester) async {
    await _pump(tester, SizedBox(width: 240,
        child: debugDockCallout(kind: DockKind.fuel, name: 'Sunoco Marina Fuel Dock & Supply')));
    expect(tester.takeException(), isNull);
    await _screenshot(tester, 'dock_callout_fuel_long_name');
  });

  testWidgets('marina callout (icon fallback) renders without overflow', (tester) async {
    await _pump(tester, SizedBox(width: 240, child: debugDockCallout(kind: DockKind.marina, name: 'Keansburg Marina')));
    expect(tester.takeException(), isNull);
    await _screenshot(tester, 'dock_callout_marina');
  });

  testWidgets('callout at 200% text scale still fits the fixed width, no overflow', (tester) async {
    await _pump(
      tester,
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: SizedBox(width: 240, child: debugDockCallout(kind: DockKind.slipway, name: 'Boat ramp')),
      ),
      // In the real app the card's Positioned() sets width only, no height — content grows
      // freely vertically (that's the "content-driven height" part of the spec). A short,
      // fixed test-surface height here would clip it artificially where the live app never
      // would, so this leaves generous room rather than reproducing a height bound that
      // doesn't actually exist in production.
      height: 1000,
    );
    expect(tester.takeException(), isNull);
    await _screenshot(tester, 'dock_callout_200pct_scale');
  });

  testWidgets('glass tail, pointing down (card above pin)', (tester) async {
    await _pump(tester, SizedBox(width: 18, height: 9, child: debugGlassTail(pointingUp: false)),
        width: 60, height: 40);
    expect(tester.takeException(), isNull);
    await _screenshot(tester, 'dock_tail_down');
  });

  testWidgets('glass tail, pointing up (card below pin)', (tester) async {
    await _pump(tester, SizedBox(width: 18, height: 9, child: debugGlassTail(pointingUp: true)),
        width: 60, height: 40);
    expect(tester.takeException(), isNull);
    await _screenshot(tester, 'dock_tail_up');
  });
}
