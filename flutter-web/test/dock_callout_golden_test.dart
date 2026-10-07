// Golden capture of MarineGlassCallout (lib/widgets/marine_glass_callout.dart), the dock-popup
// card. Live browser automation was unreliable for interactive verification this session, so
// this test renders the widget directly and captures real screenshots — this is also what
// caught two of the three ui.Gradient.linear calls in that file missing colorStops (compiles
// fine, throws ArgumentError on first paint — see CLAUDE.md's third recurring Dart bug class).
//
// Run: flutter test --platform=chrome --update-goldens test/dock_callout_golden_test.dart
// PNGs land in test/goldens/ — inspect them directly; Flutter's deterministic test font means
// title/subtitle/button text render as placeholder glyph blocks, not real text, but every
// other layer here (gradients, blur, CustomPainter strokes) is real rendering, not text.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bayside_flutter/widgets/marine_glass_callout.dart';

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

Future<void> _pump(WidgetTester tester, Widget child, {double width = 340, double height = 260}) async {
  // devicePixelRatio 1.0 so width/height are logical pixels directly (matches the project's
  // established test pattern in hourly_table_responsive_test.dart).
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    // The RepaintBoundary wraps the fake map AND the card together, not just the card alone —
    // BackdropFilter only blurs what's painted earlier within the SAME captured layer subtree.
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
  testWidgets('boat-ramp callout renders without overflow, default width', (tester) async {
    await _pump(tester, MarineGlassCallout(title: 'Boat ramp', subtitle: 'Boat ramp / slipway', onRoute: () {}));
    expect(tester.takeException(), isNull);
    await _screenshot(tester, 'marine_callout_default');
  });

  testWidgets('long name ellipsizes instead of overflowing', (tester) async {
    await _pump(tester, MarineGlassCallout(
      title: 'Sunoco Marina Fuel Dock & Supply', subtitle: 'Fuel dock', onRoute: () {}));
    expect(tester.takeException(), isNull);
    await _screenshot(tester, 'marine_callout_long_name');
  });

  testWidgets('tipFraction near 0 (card clamped to the right of the pin)', (tester) async {
    await _pump(tester, MarineGlassCallout(
      title: 'Boat ramp', subtitle: 'Boat ramp / slipway', onRoute: () {}, tipFraction: 0.05));
    expect(tester.takeException(), isNull);
    await _screenshot(tester, 'marine_callout_tip_left');
  });

  testWidgets('tipFraction near 1 (card clamped to the left of the pin)', (tester) async {
    await _pump(tester, MarineGlassCallout(
      title: 'Boat ramp', subtitle: 'Boat ramp / slipway', onRoute: () {}, tipFraction: 0.95));
    expect(tester.takeException(), isNull);
    await _screenshot(tester, 'marine_callout_tip_right');
  });

  testWidgets('narrow screen (320lp) still fits via the widget\'s own width clamp', (tester) async {
    await _pump(
      tester,
      MarineGlassCallout(title: 'Boat ramp', subtitle: 'Boat ramp / slipway', onRoute: () {}),
      width: 320,
    );
    expect(tester.takeException(), isNull);
    await _screenshot(tester, 'marine_callout_320w');
  });

  testWidgets('200% text scale still fits, no overflow', (tester) async {
    await _pump(
      tester,
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: MarineGlassCallout(title: 'Boat ramp', subtitle: 'Boat ramp / slipway', onRoute: () {}),
      ),
      width: 340,
      height: 320,
    );
    expect(tester.takeException(), isNull);
    await _screenshot(tester, 'marine_callout_200pct_scale');
  });

  testWidgets('pointingUp: tip at top, body below (flip-below case)', (tester) async {
    await _pump(tester, MarineGlassCallout(
      title: 'Boat ramp', subtitle: 'Boat ramp / slipway', onRoute: () {}, pointingUp: true));
    expect(tester.takeException(), isNull);
    await _screenshot(tester, 'marine_callout_pointing_up');
  });

  testWidgets('Route-here button content is centered as a block', (tester) async {
    await _pump(tester, MarineGlassCallout(title: 'Boat ramp', subtitle: 'Boat ramp / slipway', onRoute: () {}),
        width: 400);
    expect(tester.takeException(), isNull);
    await _screenshot(tester, 'marine_callout_wide_400');
  });
}
