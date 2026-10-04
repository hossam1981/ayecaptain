// Verifies HourlyTable (flutter-web/lib/main.dart) across the width × text-scale matrix that
// motivated its rebuild: fixed SizedBox-width cells (46/40/70/42px) were clipping "Rough" to
// "Roug"/"h", wrapping "10 AM" unevenly, and running wind direction into the gust value —
// worse again once system text scaling grew those glyphs past the guessed widths.
//
// Each combination pumps HourlyTable at an exact logical width and TextScaler, then:
//   1. Asserts no exception was thrown during layout/paint (this is how Flutter surfaces a
//      RenderFlex overflow — as a FlutterError captured by tester.takeException(), not a
//      silent visual clip) — scatters assertions covers RenderFlex/overflow but not every
//      failure mode, so each case also drives a screenshot for the other failure modes
//      (wrapping, clipping, run-together text) that don't throw.
//   2. Captures a real PNG via RepaintBoundary.toImage(), written to OUT_DIR so they can be
//      inspected directly rather than taking the pass/fail assertion's word for it.
//
// Run: flutter test --platform=chrome --update-goldens test/hourly_table_responsive_test.dart
// (--platform=chrome because main.dart imports package:web, which the default VM test
// platform can't compile; --update-goldens because these are captured for visual inspection,
// not compared against a checked-in baseline. PNGs land in test/goldens/.)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bayside_flutter/main.dart';

final _profile = BoatProfile(name: 'Test Boat', wind: 10, gust: 14, wave: 2);

// HourlyTable filters `hourly` down to DateTime.now()'s local calendar day (or +dayIdx days),
// so a fixed historical date here would get filtered to empty every row — which is exactly
// what happened the first time this test ran (see git history / session notes): all 12
// width×scale "passes" were actually screenshots of the "no data" fallback text, not the
// table. Anchoring to tomorrow with a fixed dayIdx:1 (rather than today) sidesteps the other
// failure mode — dayIdx:0's startHour is the *current* wall-clock hour, which would filter out
// early-morning rows whenever the suite happens to run in the afternoon.
final _targetDay = DateTime.now().add(const Duration(days: 1));
DateTime _hourOn(int hour) => DateTime(_targetDay.year, _targetDay.month, _targetDay.day, hour);

// Deliberately includes: a long condition label (19 kn wind vs a 10 kn limit scores 'r' ->
// "Rough"), two-digit wind (19) and gust (23) values, a short label ("Calm"), and a rain
// percentage chip — the actual content classes called out in the request, not placeholders.
final _rows = [
  HourlyPoint(t: _hourOn(5), tempF: 56, windKt: 4, gustKt: 7,
      windDirDeg: 270, weatherCode: 0, precipPct: 0),
  HourlyPoint(t: _hourOn(9), tempF: 60, windKt: 7, gustKt: 11,
      windDirDeg: 292, weatherCode: 2, precipPct: 2),
  HourlyPoint(t: _hourOn(10), tempF: 63, windKt: 19, gustKt: 23,
      windDirDeg: 292, weatherCode: 61, precipPct: 40),
  HourlyPoint(t: _hourOn(13), tempF: 66, windKt: 13, gustKt: 18,
      windDirDeg: 315, weatherCode: 3, precipPct: 0),
];

Future<void> _pump(WidgetTester tester, {required double width, required double textScale}) async {
  // tester.pumpWidget lays out the root tree against the test binding's surface size (default
  // 800x600), which reaches every descendant as a TIGHT constraint — a child SizedBox cannot
  // narrow that, because BoxConstraints.constrain() clamps a requested size back to the
  // incoming tight bounds. The surface itself has to be resized, or every "narrow" width below
  // 800 silently renders at 800 instead (confirmed: before this fix, all 12 captures across
  // 320/375/390/430 were byte-identical 800x600 PNGs).
  tester.view.physicalSize = Size(width, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MediaQuery(
    data: MediaQueryData(size: Size(width, 2000), textScaler: TextScaler.linear(textScale)),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: const Color(0xFF0A1826),
        child: SizedBox(
          width: width,
          child: RepaintBoundary(
            key: const ValueKey('capture'),
            child: HourlyTable(hourly: _rows, dayIdx: 1, profile: _profile),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _screenshot(WidgetTester tester, String name) async {
  await expectLater(find.byKey(const ValueKey('capture')), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  const widths = [320.0, 375.0, 390.0, 430.0];
  const scales = [1.0, 1.5, 2.0];

  for (final width in widths) {
    for (final scale in scales) {
      testWidgets('HourlyTable at ${width.toInt()}lp × ${(scale * 100).toInt()}% text scale',
          (tester) async {
        await _pump(tester, width: width, textScale: scale);
        // The overflow/clipping failure mode this was rebuilt to fix throws during layout —
        // takeException() is how a widget test observes that instead of a red-and-yellow
        // stripe baked into a screenshot.
        expect(tester.takeException(), isNull,
            reason: 'RenderFlex overflow or other layout exception at '
                '${width.toInt()}lp / ${(scale * 100).toInt()}%');
        await _screenshot(tester, 'w${width.toInt()}_s${(scale * 100).toInt()}');
      });
    }
  }

  // Narrow-breakpoint behavior itself: the spec requires wind/gust to move to a second line
  // below a width threshold, not just "not crash" at every width.
  testWidgets('wind/gust block stacks onto its own line below the narrow breakpoint',
      (tester) async {
    await _pump(tester, width: 300, textScale: 1.0);
    expect(tester.takeException(), isNull);
    // The wind/gust labels render as TextSpans inside Text.rich — find.textContaining only
    // scans plain Text.data by default, so findRichText:true is required or these find 0.
    expect(find.textContaining('Wind', findRichText: true), findsWidgets);
    expect(find.textContaining('Gust', findRichText: true), findsWidgets);
  });

  testWidgets('wide layout keeps Time/Condition/Icon+Temp on one row via Table',
      (tester) async {
    await _pump(tester, width: 430, textScale: 1.0);
    expect(tester.takeException(), isNull);
    expect(find.byType(Table), findsOneWidget);
  });
}
