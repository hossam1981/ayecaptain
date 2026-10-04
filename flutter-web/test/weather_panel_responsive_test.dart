// Verifies the weather-metrics grid, best-window banner, day tabs, and tide chart — the panels
// from the "typography and spacing" pass — across the same width × text-scale matrix used for
// HourlyTable (see hourly_table_responsive_test.dart), plus the specific failure modes reported
// against the old layout:
//   - metrics crammed into an unaligned Wrap, "Period" orphaned onto its own trailing line
//   - the best-window banner (a true pill, Row mainAxisSize:min) clipping text at the right
//     edge instead of wrapping
//   - day tabs with no edge padding, reading as cut off rather than intentionally scrollable
//   - tide chart canvas text not responding to system text scaling at all (TextPainter-drawn
//     text doesn't inherit MediaQuery scaling the way a Text widget does for free)
//
// Each case pumps the widget at an exact logical width and TextScaler via
// tester.view.physicalSize (see hourly_table_responsive_test.dart for why a plain SizedBox
// can't do this — the root tree is otherwise tightly constrained to the 800x600 test default
// regardless of what a child SizedBox asks for) and asserts no exception — the RenderFlex
// overflow / CustomPainter failure mode this was rebuilt to fix throws during layout/paint,
// caught by tester.takeException() rather than needing a visual diff. Each case also writes a
// golden PNG (via matchesGoldenFile, not dart:io — see that same file for why) for visual
// inspection, though the test font renders solid placeholder blocks, not real glyphs.
//
// Run: flutter test --platform=chrome --update-goldens test/weather_panel_responsive_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bayside_flutter/main.dart';

final _theme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xFF0F2A44),
  textTheme: const TextTheme(
    titleMedium: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15, letterSpacing: .2),
    titleSmall: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
    bodyLarge: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
    bodyMedium: TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 16),
    labelLarge: TextStyle(color: Color(0xFFBBD6EC), fontWeight: FontWeight.w600, fontSize: 14, letterSpacing: .3),
    labelMedium: TextStyle(color: Color(0xFFBBD6EC), fontWeight: FontWeight.w700, fontSize: 13),
    labelSmall: TextStyle(color: Color(0xFFBBD6EC), fontWeight: FontWeight.w600, fontSize: 11),
  ),
);

Future<void> _pump(WidgetTester tester, Widget child, {required double width, required double textScale, double height = 1400}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MediaQuery(
    data: MediaQueryData(size: Size(width, height), textScaler: TextScaler.linear(textScale)),
    child: Theme(
      data: _theme,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Material(
          color: const Color(0xFF0A1826),
          child: SizedBox(
            width: width,
            child: RepaintBoundary(key: const ValueKey('capture'), child: child),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _goldenAndCheck(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull, reason: 'exception while rendering $name');
  await expectLater(find.byKey(const ValueKey('capture')), matchesGoldenFile('goldens/$name.png'));
}

const _widths = [320.0, 375.0, 430.0];
const _scales = [1.0, 1.5, 2.0];

void main() {
  group('MetricsGrid', () {
    // 7 tiles (Wind/Gust/Sunset/Water/Wave/Period/Rain) — the real _weatherBlock count when
    // precipitation is present, the case that most readily orphans a trailing item.
    Widget buildTiles() => const MetricsGrid(tiles: [
      MetricTile(icon: null, label: 'Wind', value: '14 kn ESE'),
      MetricTile(icon: null, label: 'Gust', value: '19 kn'),
      MetricTile(icon: null, label: 'Sunset', value: '6:35 PM'),
      MetricTile(icon: null, label: 'Water', value: '68°F'),
      MetricTile(icon: null, label: 'Wave', value: '2.1 ft'),
      MetricTile(icon: null, label: 'Period', value: '5 s'),
      MetricTile(icon: null, label: 'Rain', value: '40%'),
    ]);

    for (final width in _widths) {
      for (final scale in _scales) {
        testWidgets('${width.toInt()}lp x ${(scale * 100).toInt()}%', (tester) async {
          await _pump(tester, buildTiles(), width: width, textScale: scale, height: 600);
          await _goldenAndCheck(tester, 'metrics_w${width.toInt()}_s${(scale * 100).toInt()}');
        });
      }
    }
  });

  group('BestWindowPill', () {
    // A longer day name + both bounds + level label — the exact string shape that clipped at
    // the pill's right edge before this was rebuilt as a wrapping banner.
    final win = BestWindow(
      start: DateTime(2026, 1, 4, 12, 0),
      end: DateTime(2026, 1, 4, 20, 0),
      level: 'g',
    );

    for (final width in _widths) {
      for (final scale in _scales) {
        testWidgets('${width.toInt()}lp x ${(scale * 100).toInt()}%', (tester) async {
          await _pump(tester, BestWindowPill(win: win), width: width, textScale: scale, height: 200);
          await _goldenAndCheck(tester, 'bestwindow_w${width.toInt()}_s${(scale * 100).toInt()}');
        });
      }
    }
  });

  group('DayTabs', () {
    final daily = List.generate(7, (i) => DailyForecast(date: DateTime.now().add(Duration(days: i))));

    for (final width in _widths) {
      for (final scale in _scales) {
        testWidgets('${width.toInt()}lp x ${(scale * 100).toInt()}%', (tester) async {
          await _pump(tester, DayTabs(daily: daily, selected: 2, onSelect: (_) {}),
              width: width, textScale: scale, height: 200);
          await _goldenAndCheck(tester, 'daytabs_w${width.toInt()}_s${(scale * 100).toInt()}');
        });
      }
    }
  });

  group('TidesSheet', () {
    // Alternating H/L roughly every 6.2h spanning -12h to +36h around "now", so both the
    // default 24h window and the "Now" marker land inside real data (cosineTideCurve needs
    // >=2 points to produce a non-empty curve — too few points would just hit the loading
    // placeholder and skip the actual painter logic this is meant to verify).
    final now = DateTime.now();
    final tides = List.generate(8, (i) {
      final t = now.subtract(const Duration(hours: 12)).add(Duration(minutes: (i * 372)));
      return TidePoint(t: t, v: i.isEven ? 5.2 : 0.8, type: i.isEven ? 'H' : 'L');
    });
    final station = TideStation(id: 'test', name: 'Waackaack Creek, NJ', lat: 40.4483, lng: -74.1433);

    for (final width in _widths) {
      for (final scale in _scales) {
        testWidgets('${width.toInt()}lp x ${(scale * 100).toInt()}%', (tester) async {
          // In the real app TidesSheet sits inside a SingleChildScrollView (_BottomSheetState),
          // so it's free to grow tall and scroll — a fixed test height is a TIGHT constraint
          // (see hourly_table_responsive_test.dart on why a plain SizedBox can't loosen that),
          // so it has to be generous enough that content at 200% scale never needs to exceed
          // it, or the test would fail on a constraint this isolated harness imposes but the
          // real embedding never does.
          await _pump(
            tester,
            TidesSheet(station: station, tides: tides, sunrise: now.subtract(const Duration(hours: 5)),
                sunset: now.add(const Duration(hours: 7))),
            width: width, textScale: scale, height: 2200,
          );
          await _goldenAndCheck(tester, 'tides_w${width.toInt()}_s${(scale * 100).toInt()}');
        });
      }
    }
  });
}
