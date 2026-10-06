// Bayside — Flutter Web
//
// v0.3: closes the biggest visible gaps that the PWA on `main` shipped:
//   - Screen Wake Lock during Start Ride (Android throttles GPS when the screen dims).
//   - "Start ride" (Uber-style) — big green button turns red Stop, engages nav mode.
//   - Real map tilt (~45°) during active nav via a Flutter Transform / perspective matrix.
//   - Course-up rotation: map rotates so the boat's heading is always up.
//   - Smart routes: water-grid land avoidance using the same pre-baked NOAA land polygons
//     (data/land-njny.json) shared with the PWA — auto-detour around land.
//
// The GPS-heading fallback, wake trail, weather HUD, basemap switcher, tap-to-add-waypoints,
// route ETA — all carry over unchanged from v0.2.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, HapticFeedback;
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web/web.dart' as web;

import 'nav_3d_view.dart';

// From flutter-web/.env via --dart-define-from-file=.env. Not typed in the boat profile.
const _envCartoKey = String.fromEnvironment('CARTO_KEY');
const _envMapStyleUrl = String.fromEnvironment('MAPLIBRE_STYLE_URL');

void main() => runApp(const BaysideApp());

// Shared spacing scale for every panel built against ayecaptain-glass-design — 4/8/12/16/24
// logical pixels, so gaps between related panels read as deliberate multiples of one unit
// rather than each picking its own number. Apply to future panels too, not just the ones this
// pass touched.
class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
}

// Secondary/label text across the weather + tide panels used several near-identical low-
// contrast blues (#8FB6D6, #9CC1DE, #79AEDA, #5F86A8, plus opacity-reduced variants of those)
// picked ad hoc per call site. One shared, deliberately lighter color closes the contrast gap
// against the dark glass background and gives every "secondary" label the same visual weight.
const _secondaryText = Color(0xFFBBD6EC);

class BaysideApp extends StatelessWidget {
  const BaysideApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Bayside — Flutter preview',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0F2A44),
          colorScheme: const ColorScheme.dark(primary: Color(0xFF2E6F9E), secondary: Color(0xFFF2A93B)),
          // Shared type roles for the weather + tide panels (ayecaptain-glass-design /
          // "Responsive row/column layout" in CLAUDE.md) — reach for these via
          // Theme.of(context).textTheme instead of a new ad hoc inline TextStyle. Chart
          // annotations drawn on a Canvas (CustomPainter text has no Theme access) pull their
          // base sizes from _ChartText below, kept in step with this scale by hand.
          textTheme: const TextTheme(
            // Section headings ("Best time to boat", tide station name).
            titleMedium: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15, letterSpacing: .2),
            // Banner / selected-tab text.
            titleSmall: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
            // Metric values, primary readable numbers — 16px body per spec.
            bodyLarge: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
            bodyMedium: TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 16),
            // Metric labels — 14px per spec, bumped-contrast secondary color.
            labelLarge: TextStyle(color: _secondaryText, fontWeight: FontWeight.w600, fontSize: 14, letterSpacing: .3),
            // Day-tab unselected text, hi/lo card sub-labels.
            labelMedium: TextStyle(color: _secondaryText, fontWeight: FontWeight.w700, fontSize: 13),
            // Fine print (footer, coordinates) — smallest role, still ≥11px and full-opacity
            // for contrast rather than the old 9-10px/67%-opacity combination.
            labelSmall: TextStyle(color: _secondaryText, fontWeight: FontWeight.w600, fontSize: 11),
          ),
        ),
        home: const MapScreen(),
      );
}

// ==================================================================================================
// basemaps
// ==================================================================================================

enum Basemap { map, chart, sat, dark }
const _basemapNames = {Basemap.map:'Map', Basemap.chart:'Chart', Basemap.sat:'Sat', Basemap.dark:'Dark'};
const _esriStreetUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}';
const _esriImageryUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
const _esriDarkBaseUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}';
const _esriDarkRefUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}';
String _cartoUrl(String style, String key) =>
  'https://{s}.basemaps.cartocdn.com/rastertiles/$style/{z}/{x}/{y}.png?key=$key';
const _cartoSubdomains = ['a', 'b', 'c', 'd'];

// PWA index.html:507-533 — an optional CARTO key gives the cleanest street/place labels on
// Map and Dark; without one it falls back to key-free Esri tiles (World_Street_Map for Map,
// a layered Dark_Gray_Base+Reference pair for Dark — never a broken/watermarked Carto tile).
// Chart reuses the same base as Map (the NOAA ENC overlay is what makes it "Chart", added by
// the caller) — it was wrongly pointed at a different OSM tile entirely.
List<TileLayer> _baseLayers(Basemap b, String cartoKey) {
  final hasKey = cartoKey.trim().isNotEmpty;
  switch (b) {
    case Basemap.map:
    case Basemap.chart:
      return [TileLayer(
        urlTemplate: hasKey ? _cartoUrl('voyager', cartoKey) : _esriStreetUrl,
        subdomains: hasKey ? _cartoSubdomains : const [],
        userAgentPackageName: 'net.bayside.flutter')];
    case Basemap.sat:
      return [TileLayer(urlTemplate: _esriImageryUrl, userAgentPackageName: 'net.bayside.flutter')];
    case Basemap.dark:
      if (hasKey) {
        return [TileLayer(urlTemplate: _cartoUrl('dark_all', cartoKey),
          subdomains: _cartoSubdomains, userAgentPackageName: 'net.bayside.flutter')];
      }
      return [
        TileLayer(urlTemplate: _esriDarkBaseUrl, userAgentPackageName: 'net.bayside.flutter'),
        TileLayer(urlTemplate: _esriDarkRefUrl, userAgentPackageName: 'net.bayside.flutter'),
      ];
  }
}
const _noaaChartUrl = 'https://gis.charttools.noaa.gov/arcgis/rest/services/MarineChart_Services/NOAACharts/MapServer/tile/{z}/{y}/{x}';
// PWA's overlayLabels() (index.html:519-521) — road + place-name labels laid over Sat, since
// satellite imagery alone (unlike the street/dark bases) has no labels baked in.
const _esriRoadsUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Transportation/MapServer/tile/{z}/{y}/{x}';
const _esriPlacesUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}';

// ==================================================================================================
// weather
// ==================================================================================================

class Weather {
  final double? tempF, windKt, gustKt;
  final int? windDirDeg, weatherCode;
  // Batch A.5 additions (matches PWA #now grid + tideStrip)
  final double? waveFt, wavePeriodS, waterTempF, precipPct;
  final DateTime? sunset, sunrise, tomorrowSunrise, tomorrowSunset;
  const Weather({this.tempF, this.windKt, this.gustKt, this.windDirDeg, this.weatherCode,
    this.waveFt, this.wavePeriodS, this.waterTempF, this.precipPct, this.sunset, this.sunrise,
    this.tomorrowSunrise, this.tomorrowSunset});
}

Future<Weather?> fetchWeather(LatLng at) async {
  // three endpoints in parallel: current wx, daily sun times, marine wave/water
  final wxUrl = Uri.parse('https://api.open-meteo.com/v1/forecast?latitude=${at.latitude}&longitude=${at.longitude}'
      '&temperature_unit=fahrenheit&wind_speed_unit=kn&timezone=auto'
      '&current=temperature_2m,wind_speed_10m,wind_gusts_10m,wind_direction_10m,weather_code,precipitation'
      '&daily=sunrise,sunset&forecast_days=2');
  final mrUrl = Uri.parse('https://marine-api.open-meteo.com/v1/marine?latitude=${at.latitude}&longitude=${at.longitude}'
      '&length_unit=imperial&current=wave_height,wave_period,sea_surface_temperature');
  try {
    final rs = await Future.wait([
      http.get(wxUrl).timeout(const Duration(seconds: 8)).catchError((_) => http.Response('', 599)),
      http.get(mrUrl).timeout(const Duration(seconds: 8)).catchError((_) => http.Response('', 599)),
    ]);
    if (rs[0].statusCode != 200) return null;
    final wj = jsonDecode(rs[0].body) as Map<String, dynamic>;
    final c = wj['current'] as Map<String, dynamic>?;
    if (c == null) return null;
    // daily first row → today's sunrise/sunset
    DateTime? sr, ss, nextSr, nextSs;
    final d = wj['daily'] as Map<String, dynamic>?;
    if (d != null) {
      final sT = (d['sunrise'] as List?)?.cast<String>();
      final ssT = (d['sunset'] as List?)?.cast<String>();
      if (sT != null && sT.isNotEmpty) sr = DateTime.tryParse(sT[0]);
      if (ssT != null && ssT.isNotEmpty) ss = DateTime.tryParse(ssT[0]);
      if (sT != null && sT.length > 1) nextSr = DateTime.tryParse(sT[1]);
      if (ssT != null && ssT.length > 1) nextSs = DateTime.tryParse(ssT[1]);
    }
    // marine (optional — silent fall through if it fails)
    double? waveFt, wavePer, waterF;
    if (rs[1].statusCode == 200) {
      try {
        final mc = (jsonDecode(rs[1].body) as Map<String, dynamic>)['current'] as Map<String, dynamic>?;
        waveFt = (mc?['wave_height'] as num?)?.toDouble();
        wavePer = (mc?['wave_period'] as num?)?.toDouble();
        final wc = (mc?['sea_surface_temperature'] as num?)?.toDouble();
        // marine API returns °C even when the forecast one is in °F — convert
        if (wc != null) waterF = wc * 9 / 5 + 32;
      } catch (_) {}
    }
    return Weather(
      tempF: (c['temperature_2m'] as num?)?.toDouble(),
      windKt: (c['wind_speed_10m'] as num?)?.toDouble(),
      gustKt: (c['wind_gusts_10m'] as num?)?.toDouble(),
      windDirDeg: (c['wind_direction_10m'] as num?)?.toInt(),
      weatherCode: (c['weather_code'] as num?)?.toInt(),
      precipPct: (c['precipitation'] as num?)?.toDouble(),
      waveFt: waveFt,
      wavePeriodS: wavePer,
      waterTempF: waterF,
      sunrise: sr,
      sunset: ss,
      tomorrowSunrise: nextSr,
      tomorrowSunset: nextSs,
    );
  } catch (_) { return null; }
}

// Hourly forecast for the "Best time to boat" table + best-window pill (Batch A.5).
// Returns up to 72 hours of `HourlyPoint` — filtering to daylight rows happens in the widget.
class HourlyPoint {
  final DateTime t;
  final double? tempF, windKt, gustKt, windDirDeg, precipPct;
  final int? weatherCode;
  const HourlyPoint({required this.t, this.tempF, this.windKt, this.gustKt,
    this.windDirDeg, this.precipPct, this.weatherCode});
}

Future<List<HourlyPoint>> fetchHourlyForecast(LatLng at) async {
  try {
    final url = Uri.parse('https://api.open-meteo.com/v1/forecast?latitude=${at.latitude}&longitude=${at.longitude}'
        '&temperature_unit=fahrenheit&wind_speed_unit=kn&timezone=auto'
        '&hourly=temperature_2m,wind_speed_10m,wind_gusts_10m,wind_direction_10m,weather_code,precipitation_probability'
        // PWA index.html:633 fetches 7 days in its one combined call; this port's
        // fetchDailyForecast already matches that, but this hourly call was left at 3 —
        // meaning the 7-day tabs above HourlyTable had real data for the first 3 days and
        // hit the "no data" fallback for the rest. Match the spec.
        '&forecast_days=7');
    final r = await http.get(url).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return [];
    final h = (jsonDecode(r.body) as Map<String, dynamic>)['hourly'] as Map<String, dynamic>?;
    if (h == null) return [];
    final times = ((h['time'] as List?) ?? []).cast<String>();
    num? getAt(String k, int i) {
      final v = (h[k] as List?);
      if (v == null || i >= v.length || v[i] == null) return null;
      return v[i] as num;
    }
    final out = <HourlyPoint>[];
    for (int i = 0; i < times.length; i++) {
      final t = DateTime.tryParse(times[i]);
      if (t == null) continue;
      out.add(HourlyPoint(
        t: t,
        tempF: getAt('temperature_2m', i)?.toDouble(),
        windKt: getAt('wind_speed_10m', i)?.toDouble(),
        gustKt: getAt('wind_gusts_10m', i)?.toDouble(),
        windDirDeg: getAt('wind_direction_10m', i)?.toDouble(),
        precipPct: getAt('precipitation_probability', i)?.toDouble(),
        weatherCode: getAt('weather_code', i)?.toInt(),
      ));
    }
    return out;
  } catch (_) { return []; }
}

// Scan the next 24 hourly points, find the first contiguous ≥3-hour block where score()
// returns 'g' (calm) or 'a' (marginal). Returns null when nothing suitable is found.
class BestWindow {
  final DateTime start, end;
  final String level;   // 'g' or 'a'
  const BestWindow({required this.start, required this.end, required this.level});
}

BestWindow? bestWindow(List<HourlyPoint> hourly, BoatProfile p) {
  if (hourly.isEmpty) return null;
  final now = DateTime.now();
  // start from the first hour >= now
  final start = hourly.indexWhere((h) => !h.t.isBefore(DateTime(now.year, now.month, now.day, now.hour)));
  if (start < 0) return null;
  final end = math.min(start + 24, hourly.length);
  int? runStart;
  String runLevel = 'g';
  BestWindow? out;
  for (int i = start; i < end; i++) {
    final h = hourly[i];
    final s = score(h.windKt, h.gustKt, null, p);   // no wave in hourly for now
    if (s == 'g' || s == 'a') {
      runStart ??= i;
      if (s == 'a') runLevel = 'a';   // downgrade if any hour is marginal
    } else {
      if (runStart != null && (i - runStart) >= 3) {
        out = BestWindow(start: hourly[runStart].t, end: hourly[i].t, level: runLevel);
        break;
      }
      runStart = null; runLevel = 'g';
    }
  }
  if (out == null && runStart != null && (end - runStart) >= 3) {
    out = BestWindow(start: hourly[runStart].t, end: hourly[end - 1].t, level: runLevel);
  }
  return out;
}

// ==================================================================================================
// boat profile — the numbers everything else grades against
// ==================================================================================================

enum BoatType { jet, bowrider, center, cruiser, sail }
const _typeNames = {BoatType.jet:'Jet boat / PWC', BoatType.bowrider:'Bowrider', BoatType.center:'Center console', BoatType.cruiser:'Cruiser', BoatType.sail:'Sail'};
// per-type sensible defaults: [wind, gust, wave(ft), cruise(kn)]
const _typeDefaults = {
  BoatType.jet:      [12.0, 18.0, 1.5, 25.0],
  BoatType.bowrider: [13.0, 19.0, 1.8, 24.0],
  BoatType.center:   [16.0, 22.0, 2.5, 25.0],
  BoatType.cruiser:  [18.0, 25.0, 3.0, 18.0],
  BoatType.sail:     [22.0, 28.0, 4.0, 6.0],
};

class BoatProfile {
  String name;
  double? lengthFt;
  BoatType type;
  double cruise, wind, gust, wave, burn, tank;
  double? draftFt;   // PWA index.html:425 — not yet used by any grading logic, just carried/persisted
  BoatProfile({this.name = '', this.lengthFt, this.type = BoatType.bowrider,
    this.cruise = 24.0, this.wind = 13.0, this.gust = 19.0, this.wave = 1.8,
    this.burn = 0.0, this.tank = 0.0, this.draftFt});
  Map<String, dynamic> toJson() => {
    'name': name, 'lengthFt': lengthFt, 'type': type.name,
    'cruise': cruise, 'wind': wind, 'gust': gust, 'wave': wave, 'burn': burn, 'tank': tank,
    'draftFt': draftFt,
  };
  static BoatProfile fromJson(Map<String, dynamic> j) => BoatProfile(
    name: (j['name'] as String?) ?? '',
    lengthFt: (j['lengthFt'] as num?)?.toDouble(),
    type: BoatType.values.firstWhere((t) => t.name == j['type'], orElse: () => BoatType.bowrider),
    cruise: (j['cruise'] as num?)?.toDouble() ?? 24.0,
    wind: (j['wind'] as num?)?.toDouble() ?? 13.0,
    gust: (j['gust'] as num?)?.toDouble() ?? 19.0,
    wave: (j['wave'] as num?)?.toDouble() ?? 1.8,
    burn: (j['burn'] as num?)?.toDouble() ?? 0.0,
    tank: (j['tank'] as num?)?.toDouble() ?? 0.0,
    draftFt: (j['draftFt'] as num?)?.toDouble(),
  );
  static Future<BoatProfile> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final s = sp.getString('boatProfile');
      if (s == null) return BoatProfile();
      return fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) { return BoatProfile(); }
  }
  // PWA index.html:500 — `if (!store.get('boat')) setTimeout(openProfile, 1500)` checks
  // whether the localStorage key exists at all, not whether any particular field is filled
  // in. The auto-open check here used to test `name.isEmpty && lengthFt == null`, which
  // wrongly re-opened the modal on every load for anyone who saved a profile without typing
  // a boat name or length (e.g. only adjusted comfort limits/cruise speed) — the save itself
  // worked, the app just didn't recognize it as saved. This checks key existence instead,
  // matching the PWA exactly.
  static Future<bool> hasSaved() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.containsKey('boatProfile');
    } catch (_) { return false; }
  }
  Future<void> save() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('boatProfile', jsonEncode(toJson()));
    } catch (_) {}
  }
  void applyTypeDefaults(BoatType t) {
    final d = _typeDefaults[t]!;
    type = t; wind = d[0]; gust = d[1]; wave = d[2]; cruise = d[3];
  }
}

// Grade a forecast against profile limits: 'g' calm, 'a' marginal (>75% of any limit), 'r' rough (over)
String score(double? wind, double? gust, double? wave, BoatProfile p) {
  if ((wind != null && wind > p.wind) || (gust != null && gust > p.gust) || (wave != null && wave > p.wave)) return 'r';
  if ((wind != null && wind > p.wind * .75) || (gust != null && gust > p.gust * .75) || (wave != null && wave > p.wave * .75)) return 'a';
  return 'g';
}

const _gradeColors = {'g': Color(0xFF22C55E), 'a': Color(0xFFF2A93B), 'r': Color(0xFFD93A2B)};
Color _gColor(String g) => _gradeColors[g] ?? _gradeColors['g']!;
int _gLevel(String g) => g == 'r' ? 2 : (g == 'a' ? 1 : 0);
Color _gInterpolate(int la, int lb, double t) {
  final level = la + (lb - la) * t;
  final rounded = level.round().clamp(0, 2);
  return _gColor(['g','a','r'][rounded]);
}

class WxSample { final String grade; final DateTime t; WxSample(this.grade, this.t); }

// Per-waypoint forecast fetch (Open-Meteo current + marine wave), scored against the boat profile
Future<String?> fetchWaypointGrade(LatLng at, BoatProfile p) async {
  try {
    final wxUrl = Uri.parse('https://api.open-meteo.com/v1/forecast?latitude=${at.latitude}&longitude=${at.longitude}'
        '&wind_speed_unit=kn&current=wind_speed_10m,wind_gusts_10m,weather_code,precipitation');
    final wx = await http.get(wxUrl).timeout(const Duration(seconds: 6));
    if (wx.statusCode != 200) return null;
    final c = (jsonDecode(wx.body) as Map<String, dynamic>)['current'] as Map<String, dynamic>?;
    if (c == null) return null;
    double? wave;
    try {
      final mrUrl = Uri.parse('https://marine-api.open-meteo.com/v1/marine?latitude=${at.latitude}&longitude=${at.longitude}&length_unit=imperial&current=wave_height');
      final m = await http.get(mrUrl).timeout(const Duration(seconds: 6));
      if (m.statusCode == 200) {
        final mc = (jsonDecode(m.body) as Map<String, dynamic>)['current'] as Map<String, dynamic>?;
        wave = (mc?['wave_height'] as num?)?.toDouble();
      }
    } catch (_) {}
    return score((c['wind_speed_10m'] as num?)?.toDouble(),
        (c['wind_gusts_10m'] as num?)?.toDouble(), wave, p);
  } catch (_) { return null; }
}

String _gkey(LatLng p) => '${p.latitude.toStringAsFixed(2)},${p.longitude.toStringAsFixed(2)}';

// ==================================================================================================
// NWS active alerts (small craft advisory, storm warnings, etc.)
// ==================================================================================================

class NwsAlert {
  final String event, headline, severity, description;
  final DateTime? ends;
  NwsAlert({required this.event, required this.headline, required this.severity, required this.description, this.ends});
  bool get isSevere => severity == 'Severe' || severity == 'Extreme';
}

Future<NwsAlert?> fetchNwsAlert(LatLng at) async {
  try {
    final url = Uri.parse('https://api.weather.gov/alerts/active?point=${at.latitude.toStringAsFixed(4)},${at.longitude.toStringAsFixed(4)}');
    final r = await http.get(url, headers: {'Accept': 'application/geo+json'}).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return null;
    final feats = ((jsonDecode(r.body) as Map<String, dynamic>)['features'] as List?) ?? [];
    if (feats.isEmpty) return null;
    feats.sort((a, b) {
      final sa = ((a['properties'] as Map)['severity'] as String?) ?? 'Unknown';
      final sb = ((b['properties'] as Map)['severity'] as String?) ?? 'Unknown';
      final ra = (sa == 'Extreme') ? 0 : (sa == 'Severe') ? 1 : (sa == 'Moderate') ? 2 : 3;
      final rb = (sb == 'Extreme') ? 0 : (sb == 'Severe') ? 1 : (sb == 'Moderate') ? 2 : 3;
      return ra - rb;
    });
    final p = (feats.first as Map<String, dynamic>)['properties'] as Map<String, dynamic>;
    return NwsAlert(
      event: (p['event'] as String?) ?? 'Weather advisory',
      headline: (p['headline'] as String?) ?? '',
      severity: (p['severity'] as String?) ?? 'Unknown',
      description: (p['description'] as String?) ?? '',
      ends: DateTime.tryParse((p['ends'] as String?) ?? ''),
    );
  } catch (_) { return null; }
}

// ==================================================================================================
// tides — NOAA CO-OPS: find nearest station + fetch high/low predictions for today
// ==================================================================================================

class TideStation {
  final String id, name;
  final double lat, lng;
  TideStation({required this.id, required this.name, required this.lat, required this.lng});
}
class TidePoint {
  final DateTime t;
  final double v;   // feet
  final String type;   // 'H' or 'L'
  TidePoint({required this.t, required this.v, required this.type});
}

List<TideStation>? _tideStations;
Future<List<TideStation>> _loadTideStations() async {
  if (_tideStations != null) return _tideStations!;
  try {
    final r = await http.get(Uri.parse('https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=tidepredictions&units=english')).timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) { _tideStations = []; return _tideStations!; }
    final list = ((jsonDecode(r.body) as Map<String, dynamic>)['stations'] as List?) ?? [];
    _tideStations = list.map((s) => TideStation(
      id: (s['id'] ?? '').toString(),
      name: '${s['name'] ?? ''}${(s['state'] ?? '').toString().isNotEmpty ? ', ${s['state']}' : ''}',
      lat: (s['lat'] as num?)?.toDouble() ?? 0,
      lng: (s['lng'] as num?)?.toDouble() ?? 0,
    )).toList();
    return _tideStations!;
  } catch (_) { _tideStations = []; return _tideStations!; }
}

TideStation? _nearestTide(LatLng at, List<TideStation> stations) {
  TideStation? best;
  double bd = double.infinity;
  for (final s in stations) {
    final d = _haversineM(at, LatLng(s.lat, s.lng));
    if (d < bd) { bd = d; best = s; }
  }
  return best;
}

Future<List<TidePoint>> fetchTides(TideStation s) async {
  final now = DateTime.now();
  final beginY = '${now.year}${now.month.toString().padLeft(2,'0')}${now.day.toString().padLeft(2,'0')}';
  final endDT = now.add(const Duration(days: 2));
  final endY = '${endDT.year}${endDT.month.toString().padLeft(2,'0')}${endDT.day.toString().padLeft(2,'0')}';
  try {
    final url = Uri.parse('https://api.tidesandcurrents.noaa.gov/api/prod/datagetter'
      '?station=${s.id}&product=predictions&datum=MLLW&units=english&time_zone=lst_ldt&format=json&interval=hilo'
      '&begin_date=$beginY&end_date=$endY');
    final r = await http.get(url).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return [];
    final preds = ((jsonDecode(r.body) as Map<String, dynamic>)['predictions'] as List?) ?? [];
    return preds.map((p) {
      final tStr = (p['t'] as String).replaceFirst(' ', 'T');
      return TidePoint(
        t: DateTime.tryParse(tStr) ?? now,
        v: double.tryParse((p['v'] as String?) ?? '0') ?? 0,
        type: (p['type'] as String?) ?? '',
      );
    }).toList();
  } catch (_) { return []; }
}

// Cosine-eased tide-curve interpolation — port of the PWA cosineCurve() at index.html:857-863.
// Fills a smooth curve between consecutive hi/lo pairs by sampling every 30 minutes with
// f = (1 - cos(π · Δt/Δ)) / 2. Feeds the SVG-like tide painter in TidesSheet.
class _TideSample {
  final DateTime t;
  final double v;
  const _TideSample(this.t, this.v);
}
List<_TideSample> cosineTideCurve(List<TidePoint> hilo) {
  if (hilo.length < 2) return [];
  final out = <_TideSample>[];
  const step = Duration(minutes: 30);
  for (int i = 0; i < hilo.length - 1; i++) {
    final a = hilo[i], b = hilo[i + 1];
    final total = b.t.difference(a.t).inMilliseconds;
    if (total <= 0) continue;
    var t = a.t;
    while (t.isBefore(b.t)) {
      final dt = t.difference(a.t).inMilliseconds / total;
      final f = (1 - math.cos(math.pi * dt)) / 2;
      out.add(_TideSample(t, a.v + (b.v - a.v) * f));
      t = t.add(step);
    }
  }
  if (hilo.isNotEmpty) out.add(_TideSample(hilo.last.t, hilo.last.v));
  return out;
}

// ==================================================================================================
// 7-day forecast (Open-Meteo daily)
// ==================================================================================================

class DailyForecast {
  final DateTime date;
  final double? tMaxF, tMinF, windMaxKt, gustMaxKt;
  final int? weatherCode;
  final double? precipMm;
  DailyForecast({required this.date, this.tMaxF, this.tMinF, this.windMaxKt, this.gustMaxKt, this.weatherCode, this.precipMm});
}

Future<List<DailyForecast>> fetchDailyForecast(LatLng at) async {
  try {
    final url = Uri.parse('https://api.open-meteo.com/v1/forecast?latitude=${at.latitude}&longitude=${at.longitude}'
        '&temperature_unit=fahrenheit&wind_speed_unit=kn&timezone=auto'
        '&daily=temperature_2m_max,temperature_2m_min,wind_speed_10m_max,wind_gusts_10m_max,precipitation_sum,weather_code'
        '&forecast_days=7');
    final r = await http.get(url).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return [];
    final d = (jsonDecode(r.body) as Map<String, dynamic>)['daily'] as Map<String, dynamic>?;
    if (d == null) return [];
    final times = ((d['time'] as List?) ?? []).cast<String>();
    num? getAt(String k, int i) {
      final v = (d[k] as List?);
      if (v == null || i >= v.length || v[i] == null) return null;
      return v[i] as num;
    }
    final out = <DailyForecast>[];
    for (int i = 0; i < times.length; i++) {
      out.add(DailyForecast(
        date: DateTime.tryParse(times[i]) ?? DateTime.now(),
        tMaxF: getAt('temperature_2m_max', i)?.toDouble(),
        tMinF: getAt('temperature_2m_min', i)?.toDouble(),
        windMaxKt: getAt('wind_speed_10m_max', i)?.toDouble(),
        gustMaxKt: getAt('wind_gusts_10m_max', i)?.toDouble(),
        weatherCode: getAt('weather_code', i)?.toInt(),
        precipMm: getAt('precipitation_sum', i)?.toDouble(),
      ));
    }
    return out;
  } catch (_) { return []; }
}

String _wxIcon(int? code) {
  if (code == null) return '';
  if (code == 0) return '☀️';
  if (code <= 2) return '🌤️';
  if (code == 3) return '☁️';
  if (code == 45 || code == 48) return '🌫️';
  if (code <= 57) return '🌦️';
  if (code <= 67) return '🌧️';
  if (code <= 77) return '🌨️';
  if (code <= 82) return '🌧️';
  return '⛈️';
}

// Real icon assets cover every condition except fog and night — fog has no asset in this set
// (falls back to the 🌫️ emoji), and night keeps its own existing moon photo rather than being
// folded into this glossy-icon set (different style, not part of what was redesigned here).
Widget _wxIconWidget(int? code, {required double size, bool isNight = false}) {
  String? asset;
  if (isNight) {
    asset = 'assets/icons/wx_moon_full.png';
  } else if (code == 0) {
    asset = 'assets/icons/wx_clear.png';
  } else if (code != null && code <= 2) {
    asset = 'assets/icons/wx_partly_cloudy.png';
  } else if (code == 3) {
    asset = 'assets/icons/wx_cloudy.png';
  } else if (code != null && ((code >= 51 && code <= 67) || (code >= 80 && code <= 82))) {
    asset = 'assets/icons/wx_rain.png';
  } else if (code != null && code >= 71 && code <= 77) {
    asset = 'assets/icons/wx_snow.png';
  } else if (code != null && code > 82) {
    // Everything above 82 that isn't already matched above is thunder (WMO 95-99); fog
    // (45/48) and drizzle/rain/showers (51-82) are both below this and already handled.
    asset = 'assets/icons/wx_thunder.png';
  }
  if (asset != null) return Image.asset(asset, width: size, height: size, fit: BoxFit.contain);
  return Text(isNight ? '🌙' : _wxIcon(code), style: TextStyle(fontSize: size * .82));
}

// ==================================================================================================
// Batch C — sun/moon edge marker. Port of the PWA's `solarPos` + `sunEdge` (index.html:1144-1197):
// a real ecliptic-coordinate solar-position solver, pinned to the viewport edge along its true
// compass bearing, fading through dusk. No third-party astronomy package needed.
// ==================================================================================================

class SolarPos {
  final double azDeg;   // compass bearing 0-360
  final double elDeg;   // altitude above horizon, negative = below
  final double eclipticLonDeg;   // geocentric ecliptic longitude — feeds the moon-phase calc
  const SolarPos(this.azDeg, this.elDeg, this.eclipticLonDeg);
}

SolarPos solarPos(double lat, double lon, DateTime date) {
  const rad = math.pi / 180, deg = 180 / math.pi;
  final utc = date.toUtc();
  final n = utc.millisecondsSinceEpoch / 86400000 + 2440587.5 - 2451545.0;   // days since J2000
  final l = (280.460 + 0.9856474 * n) % 360;
  final g0 = ((357.528 + 0.9856003 * n) % 360) * rad;
  final lam = (l + 1.915 * math.sin(g0) + 0.020 * math.sin(2 * g0)) * rad;
  final eps = (23.439 - 0.0000004 * n) * rad;
  final ra = math.atan2(math.cos(eps) * math.sin(lam), math.cos(lam));
  final dec = math.asin(math.sin(eps) * math.sin(lam));
  final gmst = (((18.697374558 + 24.06570982441908 * n) % 24) + 24) % 24;
  final lst = ((gmst * 15 + lon) % 360) * rad;
  final ha = lst - ra, la = lat * rad;
  final el = math.asin(math.sin(la) * math.sin(dec) + math.cos(la) * math.cos(dec) * math.cos(ha)) * deg;
  var az = math.atan2(math.sin(ha), math.cos(ha) * math.sin(la) - math.tan(dec) * math.cos(la)) * deg + 180;
  az = (az % 360 + 360) % 360;
  final eclipticLonDeg = ((lam * deg) % 360 + 360) % 360;
  return SolarPos(az, el, eclipticLonDeg);
}

// Standard low-precision lunar position (mean orbital elements, ~0.3° accuracy) — structurally
// mirrors solarPos above (same LST/hour-angle/az/el formulas) so the two share one convention.
// Illumination fraction comes from the geocentric elongation between the Moon's and Sun's
// ecliptic longitudes — accurate enough to pick a crescent/gibbous/full glyph.
class MoonPos {
  final double azDeg, elDeg, illum;
  const MoonPos(this.azDeg, this.elDeg, this.illum);
}

MoonPos moonPos(double lat, double lon, DateTime date, double sunEclipticLonDeg) {
  const rad = math.pi / 180, deg = 180 / math.pi;
  final utc = date.toUtc();
  final n = utc.millisecondsSinceEpoch / 86400000 + 2440587.5 - 2451545.0;
  final lMoon = (218.316 + 13.176396 * n) % 360;
  final mMoon = ((134.963 + 13.064993 * n) % 360) * rad;
  final f = ((93.272 + 13.229350 * n) % 360) * rad;
  final lam = (lMoon + 6.289 * math.sin(mMoon)) * rad;
  final bet = 5.128 * math.sin(f) * rad;
  final eps = (23.439 - 0.0000004 * n) * rad;
  final ra = math.atan2(math.sin(lam) * math.cos(eps) - math.tan(bet) * math.sin(eps), math.cos(lam));
  final dec = math.asin(math.sin(bet) * math.cos(eps) + math.cos(bet) * math.sin(eps) * math.sin(lam));
  final gmst = (((18.697374558 + 24.06570982441908 * n) % 24) + 24) % 24;
  final lst = ((gmst * 15 + lon) % 360) * rad;
  final ha = lst - ra, la = lat * rad;
  final el = math.asin(math.sin(la) * math.sin(dec) + math.cos(la) * math.cos(dec) * math.cos(ha)) * deg;
  var az = math.atan2(math.sin(ha), math.cos(ha) * math.sin(la) - math.tan(dec) * math.cos(la)) * deg + 180;
  az = (az % 360 + 360) % 360;
  final elongDeg = ((lam * deg - sunEclipticLonDeg) % 360 + 360) % 360;
  final illum = (1 - math.cos(elongDeg * rad)) / 2;
  return MoonPos(az, el, illum);
}

// Reuses the same dusk-fade curve as the sun (no PWA reference — the moon marker is a
// deliberate enhancement beyond the PWA, per the user's explicit call).
double moonOpacity(double elDeg) => sunOpacity(elDeg);

// Clamp the sun's compass bearing to a point on the viewport's edge (42 px margin), same
// ray-cast as the PWA's `sunEdge` (index.html:1157-1163).
Offset sunEdgePoint(double azDeg, Size size) {
  const m = 42.0;
  final cx = size.width / 2, cy = size.height / 2;
  final a = azDeg * math.pi / 180;
  final dx = math.sin(a), dy = -math.cos(a);
  double s = double.infinity;
  if (dx > 1e-6) s = math.min(s, (size.width - m - cx) / dx);
  else if (dx < -1e-6) s = math.min(s, (m - cx) / dx);
  if (dy > 1e-6) s = math.min(s, (size.height - m - cy) / dy);
  else if (dy < -1e-6) s = math.min(s, (m - cy) / dy);
  return Offset(cx + dx * s, cy + dy * s);
}

// Opacity fade through dusk — identical thresholds to the PWA's `updateSun` (index.html:1173).
double sunOpacity(double elDeg) {
  if (elDeg > 8) return 1;
  if (elDeg > 0) return 0.5 + elDeg / 16;
  if (elDeg > -6) return 0.3 * (elDeg + 6) / 6;
  return 0;
}

// ==================================================================================================
// Batch B.5 — chart overlays: docks & fuel (OSM), nav aids (OSM), tidal currents (NOAA)
// ==================================================================================================

const _overpassMirrors = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
];

// Rough conversion from statute miles → geographic bounding box (~1° lat ≈ 69 mi).
// At mid-latitudes this is close enough for a fetch radius.
({double south, double west, double north, double east}) _bboxMi(LatLng at, double mi) {
  final dLat = mi / 69.0;
  final dLng = mi / (69.0 * math.cos(at.latitude * math.pi / 180));
  return (south: at.latitude - dLat, west: at.longitude - dLng,
          north: at.latitude + dLat, east: at.longitude + dLng);
}

Future<String?> _overpassQuery(String query) async {
  // PWA (index.html:1622): `fetch(url, {method:'POST', body: q})` — the raw query STRING as
  // the body (browser defaults to text/plain). Passing a Map here instead form-encodes it as
  // `data=<query>` under application/x-www-form-urlencoded, which Overpass can't parse as a
  // valid query — its error response lacks CORS headers, and the browser reports that as a
  // blanket "blocked by CORS policy" failure that masked the real cause. Send the query as a
  // raw String body to match the PWA exactly.
  for (final url in _overpassMirrors) {
    try {
      // Client timeout kept well above the query's own [timeout:12] so the two don't race —
      // the server should always finish (or itself time out) before we give up on it.
      final r = await http.post(Uri.parse(url), body: query).timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) return r.body;
    } catch (_) {}
  }
  return null;
}

// ---------- docks & fuel (marinas, ramps, fuel docks) ----------

enum DockKind { marina, slipway, fuel }

class Dock {
  final String name;
  final DockKind kind;
  final LatLng ll;
  Dock({required this.name, required this.kind, required this.ll});
  Map<String, dynamic> toJson() => {'name': name, 'kind': kind.name, 'lat': ll.latitude, 'lng': ll.longitude};
  static Dock fromJson(Map<String, dynamic> j) => Dock(
    name: (j['name'] as String?) ?? '',
    kind: DockKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => DockKind.marina),
    ll: LatLng((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
  );
}

// Bundled NJ/NY marina & boat-ramp dataset (assets/docks-njny.json) — a one-time offline
// extract from OpenStreetMap's regional data files (Geofabrik), not a live API call. Added
// because the live Overpass API fetchDocks() used to depend on exclusively is currently
// broken — confirmed via multiple independent tests (direct requests, a backend proxy with a
// proper identifying header, and Overpass's own official web tool all failing the same way) —
// and NOAA's equivalent chart-facility data has essentially zero coverage for this region
// (checked: 0 points in a wide NJ/NY bounding box, ~1,150 nationwide total). This bundled
// extract alone has 2,147 marina/slipway points for NJ+NY. Loads once, cached in memory for
// the app's lifetime — instant, zero network dependency, can't show "couldn't reach data".
List<Dock>? _bundledDocksCache;
Future<List<Dock>> _loadBundledDocks() async {
  if (_bundledDocksCache != null) return _bundledDocksCache!;
  try {
    final raw = await rootBundle.loadString('assets/docks-njny.json');
    final list = jsonDecode(raw) as List;
    _bundledDocksCache = list.map((e) {
      final m = e as Map<String, dynamic>;
      final kind = DockKind.values.firstWhere((k) => k.name == m['kind'], orElse: () => DockKind.marina);
      final rawName = (m['name'] as String?)?.trim();
      final name = (rawName != null && rawName.isNotEmpty) ? rawName : _defaultDockName(kind);
      return Dock(name: name, kind: kind, ll: LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()));
    }).toList();
  } catch (_) {
    _bundledDocksCache = [];
  }
  return _bundledDocksCache!;
}

// Returns null on a genuine fetch/parse failure (so the caller can show a retry prompt),
// vs an empty list for a legitimate "no docks within 20 mi" result.
Future<List<Dock>?> fetchDocks(LatLng at) async {
  final bundled = await _loadBundledDocks();
  final nearby = bundled.where((d) => _haversineM(at, d.ll) <= 20 * 1609.34).toList();
  if (nearby.isNotEmpty) return nearby;
  // Nothing in the bundled NJ/NY extract nearby — either a genuine "no docks within 20mi" in
  // that region, or a location outside it entirely (the bundled data only covers NJ/NY). Try
  // the original live Overpass path as a bonus for the latter case, rather than silently
  // treating every out-of-region location as having zero docks. Currently unreliable (see
  // above) — that's the known, pre-existing limitation this bundled data was added to avoid
  // for the in-region case, which is now the common one for this app's users.
  return _fetchDocksLive(at);
}

Future<List<Dock>?> _fetchDocksLive(LatLng at) async {
  // 7-day cache keyed on the rough tile (0.5°) so nearby fixes hit the same cache.
  final key = 'docks_${at.latitude.toStringAsFixed(1)}_${at.longitude.toStringAsFixed(1)}';
  try {
    final sp = await SharedPreferences.getInstance();
    final cached = sp.getString(key);
    if (cached != null) {
      final j = jsonDecode(cached) as Map<String, dynamic>;
      final ts = DateTime.fromMillisecondsSinceEpoch(j['t'] as int);
      if (DateTime.now().difference(ts).inDays < 7) {
        return (j['docks'] as List).map((e) => Dock.fromJson(e as Map<String, dynamic>)).toList();
      }
    }
  } catch (_) {}
  final b = _bboxMi(at, 20);
  final q = '''
[out:json][timeout:12];
(
  node["leisure"="marina"](${b.south},${b.west},${b.north},${b.east});
  node["leisure"="slipway"](${b.south},${b.west},${b.north},${b.east});
  node["seamark:type"="fuel"](${b.south},${b.west},${b.north},${b.east});
  way["leisure"="marina"](${b.south},${b.west},${b.north},${b.east});
);
out center 60;''';
  final body = await _overpassQuery(q);
  if (body == null) return null;
  final out = <Dock>[];
  try {
    final j = jsonDecode(body) as Map<String, dynamic>;
    final els = (j['elements'] as List?) ?? [];
    for (final e in els) {
      final m = e as Map<String, dynamic>;
      final tags = (m['tags'] as Map?) ?? {};
      double? lat = (m['lat'] as num?)?.toDouble();
      double? lng = (m['lon'] as num?)?.toDouble();
      if (lat == null && m['center'] is Map) {
        lat = ((m['center'] as Map)['lat'] as num?)?.toDouble();
        lng = ((m['center'] as Map)['lon'] as num?)?.toDouble();
      }
      if (lat == null || lng == null) continue;
      DockKind k = DockKind.marina;
      if (tags['seamark:type'] == 'fuel') k = DockKind.fuel;
      else if (tags['leisure'] == 'slipway') k = DockKind.slipway;
      out.add(Dock(name: (tags['name'] as String?) ?? _defaultDockName(k), kind: k, ll: LatLng(lat, lng)));
    }
  } catch (_) {}
  try {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(key, jsonEncode({'t': DateTime.now().millisecondsSinceEpoch,
      'docks': out.map((d) => d.toJson()).toList()}));
  } catch (_) {}
  return out;
}
String _defaultDockName(DockKind k) => k == DockKind.fuel ? 'Fuel dock' : (k == DockKind.slipway ? 'Boat ramp' : 'Marina');

// ---------- nav aids (channel buoys + beacons) ----------

class NavAid {
  final String name;
  final String category;   // "red" / "green" / "amber"
  final LatLng ll;
  NavAid({required this.name, required this.category, required this.ll});
  Map<String, dynamic> toJson() => {'name': name, 'cat': category, 'lat': ll.latitude, 'lng': ll.longitude};
  static NavAid fromJson(Map<String, dynamic> j) => NavAid(
    name: (j['name'] as String?) ?? '',
    category: (j['cat'] as String?) ?? 'amber',
    ll: LatLng((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
  );
}

String _seamarkColor(Map tags) {
  // seamark:buoy_lateral:colour = red / green / red;green / green;red
  final k = tags['seamark:buoy_lateral:colour'] ?? tags['seamark:beacon_lateral:colour'] ?? tags['seamark:light:colour'];
  if (k == null) return 'amber';
  final s = k.toString().toLowerCase();
  if (s.contains('red')) return 'red';
  if (s.contains('green')) return 'green';
  return 'amber';
}

// Returns null on a genuine fetch/parse failure (so the caller can show a retry prompt),
// vs an empty list for a legitimate "no nav aids within 20 mi" result.
Future<List<NavAid>?> fetchNavAids(LatLng at) async {
  final key = 'navaids_${at.latitude.toStringAsFixed(1)}_${at.longitude.toStringAsFixed(1)}';
  try {
    final sp = await SharedPreferences.getInstance();
    final cached = sp.getString(key);
    if (cached != null) {
      final j = jsonDecode(cached) as Map<String, dynamic>;
      final ts = DateTime.fromMillisecondsSinceEpoch(j['t'] as int);
      if (DateTime.now().difference(ts).inDays < 30) {
        return (j['aids'] as List).map((e) => NavAid.fromJson(e as Map<String, dynamic>)).toList();
      }
    }
  } catch (_) {}
  final b = _bboxMi(at, 20);
  final q = '''
[out:json][timeout:12];
(
  node["seamark:type"="buoy_lateral"](${b.south},${b.west},${b.north},${b.east});
  node["seamark:type"="beacon_lateral"](${b.south},${b.west},${b.north},${b.east});
);
out 120;''';
  final body = await _overpassQuery(q);
  if (body == null) return null;
  final out = <NavAid>[];
  try {
    final j = jsonDecode(body) as Map<String, dynamic>;
    final els = (j['elements'] as List?) ?? [];
    for (final e in els) {
      final m = e as Map<String, dynamic>;
      final lat = (m['lat'] as num?)?.toDouble();
      final lng = (m['lon'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final tags = (m['tags'] as Map?) ?? {};
      out.add(NavAid(
        name: (tags['seamark:name'] as String?) ?? (tags['name'] as String?) ?? 'Buoy',
        category: _seamarkColor(tags),
        ll: LatLng(lat, lng),
      ));
    }
  } catch (_) {}
  try {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(key, jsonEncode({'t': DateTime.now().millisecondsSinceEpoch,
      'aids': out.map((a) => a.toJson()).toList()}));
  } catch (_) {}
  return out;
}

// ---------- tidal currents (NOAA current-predictions) ----------

class TidalCurrent {
  final LatLng ll;
  final double velocityKt;   // signed: + = flood, - = ebb
  final double directionDeg; // set direction (0-360)
  final String stationName;
  const TidalCurrent({required this.ll, required this.velocityKt, required this.directionDeg, required this.stationName});
}

// Nearest current station: NOAA CO-OPS metadata + current-predictions endpoint.
Future<TidalCurrent?> fetchTidalCurrent(LatLng at) async {
  try {
    // 1) find nearest current-predictions station within 40 mi
    final metaUrl = Uri.parse('https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=currentpredictions');
    final r = await http.get(metaUrl).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final stations = (j['stations'] as List?) ?? [];
    Map<String, dynamic>? best;
    double bestD = 40 * 1609.34;
    for (final s in stations) {
      final m = s as Map<String, dynamic>;
      final lat = (m['lat'] as num?)?.toDouble();
      final lng = (m['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final d = _haversineM(at, LatLng(lat, lng));
      if (d < bestD) { bestD = d; best = m; }
    }
    if (best == null) return null;
    final id = best['id']?.toString();
    if (id == null) return null;
    // 2) query current predictions for now
    final now = DateTime.now().toUtc();
    final begin = now.subtract(const Duration(minutes: 30));
    String fmt(DateTime t) => '${t.year}${t.month.toString().padLeft(2,'0')}${t.day.toString().padLeft(2,'0')} ${t.hour.toString().padLeft(2,'0')}:${t.minute.toString().padLeft(2,'0')}';
    final predUrl = Uri.parse('https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=currents_predictions&interval=6&units=english&time_zone=gmt&format=json'
        '&station=$id&begin_date=${fmt(begin)}&end_date=${fmt(now.add(const Duration(hours: 1)))}&bin=1');
    final p = await http.get(predUrl).timeout(const Duration(seconds: 8));
    if (p.statusCode != 200) return null;
    final pj = jsonDecode(p.body) as Map<String, dynamic>;
    final preds = (pj['current_predictions']?['cp'] as List?) ?? [];
    if (preds.isEmpty) return null;
    // pick the sample closest to now
    Map<String, dynamic>? closest;
    Duration bestDt = const Duration(hours: 999);
    for (final s in preds) {
      final m = s as Map<String, dynamic>;
      final t = DateTime.tryParse((m['Time'] as String?) ?? '');
      if (t == null) continue;
      final dt = t.difference(now).abs();
      if (dt < bestDt) { bestDt = dt; closest = m; }
    }
    if (closest == null) return null;
    final v = (closest['Velocity_Major'] as num?)?.toDouble();
    final dir = (closest['meanFloodDir'] as num?)?.toDouble() ?? (closest['Bin'] as num?)?.toDouble();
    if (v == null || dir == null) return null;
    // signed velocity: NOAA reports negative for ebb via Velocity_Major
    return TidalCurrent(
      ll: LatLng((best['lat'] as num).toDouble(), (best['lng'] as num).toDouble()),
      velocityKt: v,
      directionDeg: v >= 0 ? dir : (dir + 180) % 360,
      stationName: (best['name'] as String?) ?? 'Current',
    );
  } catch (_) { return null; }
}

// ==================================================================================================
// pre-baked land data — same asset the PWA uses, dropped into flutter-web/assets/
// ==================================================================================================

class LandData {
  final List<List<LatLng>> ways;
  final List<List<double>> polyBBox; // [w, s, e, n] per way
  final List<double> globalBBox;      // [w, s, e, n]
  LandData({required this.ways, required this.polyBBox, required this.globalBBox});
}

LandData? _land;
Future<void> _loadLand() async {
  if (_land != null) return;
  try {
    final txt = await rootBundle.loadString('assets/land-njny.json');
    final j = jsonDecode(txt) as Map<String, dynamic>;
    final bbox = (j['bbox'] as List).map((e) => (e as num).toDouble()).toList();
    final rawWays = j['ways'] as List;
    final ways = <List<LatLng>>[];
    final poly = <List<double>>[];
    for (final w in rawWays) {
      final pts = <LatLng>[];
      double mnLa=90, mxLa=-90, mnLo=180, mxLo=-180;
      for (final p in (w as List)) {
        final m = p as Map<String, dynamic>;
        final lat = (m['lat'] as num).toDouble();
        final lng = (m['lng'] as num).toDouble();
        pts.add(LatLng(lat, lng));
        if (lat < mnLa) mnLa = lat; if (lat > mxLa) mxLa = lat;
        if (lng < mnLo) mnLo = lng; if (lng > mxLo) mxLo = lng;
      }
      if (pts.length >= 2) {
        ways.add(pts);
        poly.add([mnLo, mnLa, mxLo, mxLa]);
      }
    }
    _land = LandData(ways: ways, polyBBox: poly, globalBBox: bbox);
  } catch (_) { /* asset missing or corrupt — falls back to plain straight lines */ }
}

// ==================================================================================================
// smart routes — water-grid + Dijkstra land avoidance (mirrors the PWA's gridRoute)
// ==================================================================================================

bool _segIntersect(LatLng a, LatLng b, LatLng c, LatLng d) {
  final d1x = b.longitude - a.longitude, d1y = b.latitude - a.latitude;
  final d2x = d.longitude - c.longitude, d2y = d.latitude - c.latitude;
  final den = d1x * d2y - d1y * d2x;
  if (den.abs() < 1e-12) return false;
  final t = ((c.longitude - a.longitude) * d2y - (c.latitude - a.latitude) * d2x) / den;
  final u = ((c.longitude - a.longitude) * d1y - (c.latitude - a.latitude) * d1x) / den;
  const eps = 1e-9;
  return !(t < eps || t > 1 - eps || u < eps || u > 1 - eps);
}

bool _pointInRing(LatLng p, List<LatLng> ring) {
  bool inside = false;
  for (int i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i].longitude, yi = ring[i].latitude;
    final xj = ring[j].longitude, yj = ring[j].latitude;
    if (((yi > p.latitude) != (yj > p.latitude)) &&
        (p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi)) {
      inside = !inside;
    }
  }
  return inside;
}

bool _pointOnLand(LatLng p, List<List<LatLng>> ways) {
  for (final w in ways) if (_pointInRing(p, w)) return true;
  return false;
}

bool _edgeCrossesLand(LatLng a, LatLng b, List<List<LatLng>> segs, List<List<LatLng>> ways) {
  for (final s in segs) if (_segIntersect(a, b, s[0], s[1])) return true;
  const samples = 8, margin = 0.12;
  for (int k = 0; k < samples; k++) {
    final t = margin + (1 - 2 * margin) * (k / (samples - 1));
    final q = LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
    if (_pointOnLand(q, ways)) return true;
  }
  return false;
}

double _haversineM(LatLng a, LatLng b) {
  const R = 6371000.0;
  final la1 = a.latitude * math.pi / 180;
  final la2 = b.latitude * math.pi / 180;
  final dla = (b.latitude - a.latitude) * math.pi / 180;
  final dlo = (b.longitude - a.longitude) * math.pi / 180;
  final s = math.pow(math.sin(dla / 2), 2) + math.cos(la1) * math.cos(la2) * math.pow(math.sin(dlo / 2), 2);
  return 2 * R * math.asin(math.sqrt(s.toDouble()));
}

/// Grid-based water routing between two points. Returns the straight line if no land is in the way,
/// otherwise a bent path around land, or null if it couldn't verify a clear detour.
List<LatLng>? smartRoute(LatLng from, LatLng to, LandData? land) {
  if (land == null) return [from, to];
  // filter ways to leg bbox
  const pad = 0.05;
  final s = math.min(from.latitude, to.latitude) - pad;
  final n = math.max(from.latitude, to.latitude) + pad;
  final w = math.min(from.longitude, to.longitude) - pad;
  final e = math.max(from.longitude, to.longitude) + pad;
  final ways = <List<LatLng>>[];
  for (int i = 0; i < land.ways.length; i++) {
    final b = land.polyBBox[i];
    if (b[2] < w || b[0] > e || b[3] < s || b[1] > n) continue;
    ways.add(land.ways[i]);
  }
  if (ways.isEmpty) return [from, to];
  final segs = <List<LatLng>>[];
  for (final way in ways) {
    for (int i = 0; i < way.length - 1; i++) segs.add([way[i], way[i + 1]]);
  }
  if (!_edgeCrossesLand(from, to, segs, ways)) return [from, to];

  // adaptive grid corridor
  final latR = from.latitude * math.pi / 180;
  const mPerLat = 111320.0;
  final mPerLng = 111320.0 * math.cos(latR);
  final ex = (to.longitude - from.longitude) * mPerLng;
  final ey = (to.latitude - from.latitude) * mPerLat;
  final legLen = math.max(1.0, math.sqrt(ex * ex + ey * ey));
  final ux = ex / legLen, uy = ey / legLen, px = -uy, py = ux;
  double clamp(double v, double lo, double hi) => math.max(lo, math.min(hi, v));
  final spacing = clamp(legLen / 60, 150, 300);
  final corridor = clamp(legLen * 0.3, 1400, 3000);
  final margin = math.max(900.0, spacing * 4);

  final nodes = <LatLng>[from, to];
  for (double a = -margin; a <= legLen + margin; a += spacing) {
    for (double c = -corridor; c <= corridor; c += spacing) {
      final x = a * ux + c * px, y = a * uy + c * py;
      final ll = LatLng(from.latitude + y / mPerLat, from.longitude + x / mPerLng);
      if (!_pointOnLand(ll, ways)) nodes.add(ll);
    }
  }
  if (nodes.length > 2200) return null;   // too dense to grid in real time — signal unverified
  final n2 = nodes.length;
  final linkR = spacing * 1.8;
  final adj = List.generate(n2, (_) => <MapEntry<int, double>>[]);
  void connect(int i, int j) {
    if (_edgeCrossesLand(nodes[i], nodes[j], segs, ways)) return;
    final d = _haversineM(nodes[i], nodes[j]);
    adj[i].add(MapEntry(j, d));
    adj[j].add(MapEntry(i, d));
  }
  for (final ep in [0, 1]) {
    for (int j = 2; j < n2; j++) if (_haversineM(nodes[ep], nodes[j]) <= spacing * 4) connect(ep, j);
  }
  connect(0, 1);
  for (int i = 2; i < n2; i++) {
    for (int j = i + 1; j < n2; j++) if (_haversineM(nodes[i], nodes[j]) <= linkR) connect(i, j);
  }
  // Dijkstra
  final dist = List<double>.filled(n2, double.infinity);
  final prev = List<int>.filled(n2, -1);
  final done = List<bool>.filled(n2, false);
  dist[0] = 0;
  for (int it = 0; it < n2; it++) {
    int u = -1; double best = double.infinity;
    for (int k = 0; k < n2; k++) if (!done[k] && dist[k] < best) { best = dist[k]; u = k; }
    if (u == -1) break;
    done[u] = true;
    for (final ev in adj[u]) {
      if (dist[u] + ev.value < dist[ev.key]) { dist[ev.key] = dist[u] + ev.value; prev[ev.key] = u; }
    }
  }
  if (!dist[1].isFinite) return null;
  final path = <LatLng>[];
  int cur = 1;
  while (cur != -1) { path.insert(0, nodes[cur]); cur = prev[cur]; }
  // string-pull
  bool changed = true;
  while (changed && path.length > 2) {
    changed = false;
    for (int i = 1; i < path.length - 1; i++) {
      if (!_edgeCrossesLand(path[i - 1], path[i + 1], segs, ways)) {
        path.removeAt(i); changed = true; break;
      }
    }
  }
  return path;
}

// ==================================================================================================
// main screen
// ==================================================================================================

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  final MapController _controller = MapController();
  StreamSubscription<Position>? _gpsSub;

  Basemap _base = Basemap.map;
  // Optional. Comes from flutter-web/.env (CARTO_KEY / MAPLIBRE_STYLE_URL), not the boat form.
  // Empty CARTO_KEY falls back to Esri tiles. Empty MAPLIBRE_STYLE_URL keeps the flat map.
  final String _cartoKey = _envCartoKey;
  final String _mapStyleUrl = _envMapStyleUrl;
  LatLng? _me;
  double _heading = 0;
  double _speedKt = 0;
  double? _accuracyM;
  bool _follow = true;
  bool _picking = false;
  // Default OFF — matches the PWA exactly (index.html:1391: "Off by default: legs are plain
  // straight lines, exactly as the app worked before"). An earlier Flutter-only rationale for
  // defaulting this on predates the "copy the PWA identically" rule; corrected here.
  bool _smart = false;
  bool _navigating = false;
  int _legIdx = 0;       // index into _waypoints of the current target leg (for nav bar + auto-advance)
  final List<_TrailPoint> _trail = [];
  final List<LatLng> _waypoints = [];
  List<LatLng>? _routedPath;   // cached smart-route (null = straight line)
  bool _routeUnverified = false;

  BoatProfile _profile = BoatProfile();
  final Map<String, WxSample> _wxAt = {};    // per-gkey grade cache, ~20 min TTL
  final Set<String> _wxPending = {};

  Weather? _weather;
  Timer? _wxTimer;
  String _statusText = 'Not tracking';

  // Batch B: chart plotter richness state
  NwsAlert? _alert;
  String? _dismissedBoatWarningSeverity;
  TideStation? _tideStation;
  List<TidePoint> _tides = [];
  List<DailyForecast> _daily = [];
  List<HourlyPoint> _hourly = [];   // Batch A.5: drives "Best time to boat" table + best window pill

  LatLng? _mobPoint;
  LatLng? _anchorPoint;
  double _anchorRadiusFt = 100;
  bool _anchorBreached = false;
  bool _fuelRingOn = false;

  // Batch B.5 overlays
  bool _docksOn = false;
  bool _navAidsOn = false;
  List<Dock> _docks = [];
  List<NavAid> _navAids = [];
  TidalCurrent? _tidalCurrent;

  // The one currently-open dock callout. Shown via Overlay.insert(), NOT nested inside the
  // tapped pin's own small Marker box — Flutter gates hit-testing to a widget's OWN declared
  // size before it ever recurses into children (RenderBox.hitTest()'s `size.contains(position)`
  // check), so content painted outside a parent's bounds via Stack(clipBehavior: Clip.none) is
  // visible but NOT tappable. That was the bug in the first version of this: the card rendered
  // fine, but "Route here" never responded because it painted outside the pin's 28x28 marker
  // box. An Overlay entry has no such box — it's positioned directly in screen coordinates, so
  // taps land correctly everywhere the card actually paints.
  LatLng? _openDock;
  OverlayEntry? _dockOverlayEntry;

  void _openDockPopup(Dock d, Offset anchorTopLeft, Size anchorSize) {
    _removeDockOverlay();
    final screenH = MediaQuery.sizeOf(context).height;
    final screenW = MediaQuery.sizeOf(context).width;
    final anchorCenterX = anchorTopLeft.dx + anchorSize.width / 2;
    final above = anchorTopLeft.dy - _dockPopupGap - _dockPopupEstH >= _dockPopupMargin;
    final left = anchorCenterX - _dockPopupW / 2;
    final right = anchorCenterX + _dockPopupW / 2;
    double dx = 0;
    if (left < _dockPopupMargin) {
      dx = _dockPopupMargin - left;
    } else if (right > screenW - _dockPopupMargin) {
      dx = (screenW - _dockPopupMargin) - right;
    }
    const tailW = 18.0, tailH = 9.0;
    setState(() => _openDock = d.ll);
    _dockOverlayEntry = OverlayEntry(builder: (overlayContext) {
      return Stack(children: [
        // A full-screen, invisible tap-catcher BEHIND the card/tail so tapping anywhere else
        // on the map closes the callout — mirrors _handleMapPoint's "tap elsewhere" dismissal,
        // needed here too since the overlay now sits above the FlutterMap's own tap handling.
        Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _closeDockPopup)),
        // Pointer tail — centered on the pin itself, not shifted by the card's own dx nudge.
        Positioned(
          left: anchorCenterX - tailW / 2, width: tailW, height: tailH,
          bottom: above ? screenH - anchorTopLeft.dy : null,
          top: above ? null : anchorTopLeft.dy + anchorSize.height,
          child: _GlassTail(pointingUp: !above),
        ),
        Positioned(
          left: anchorCenterX - _dockPopupW / 2 + dx, width: _dockPopupW,
          bottom: above ? screenH - anchorTopLeft.dy + tailH : null,
          top: above ? null : anchorTopLeft.dy + anchorSize.height + tailH,
          child: _DockCallout(kind: d.kind, name: d.name,
            onRouteHere: () { _closeDockPopup(); _routeToPoint(d.ll); }),
        ),
      ]);
    });
    Overlay.of(context).insert(_dockOverlayEntry!);
  }

  void _removeDockOverlay() { _dockOverlayEntry?.remove(); _dockOverlayEntry = null; }

  void _closeDockPopup() {
    if (_openDock == null) return;
    setState(() => _openDock = null);
    _removeDockOverlay();
  }
  // Loading/error feedback — matches the PWA's "Loading nearby docks…" /
  // "Couldn't reach dock data — tap to retry" (index.html:1662, 1683).
  bool _docksLoading = false, _docksError = false;
  bool _navAidsLoading = false, _navAidsError = false;

  // Batch B.6 tide unit preference — 'ft' or 'm', persisted like the PWA's tideUnit key.
  String _tideUnit = 'ft';

  // Bottom-sheet expanded state — lifted from _BottomSheet so a full-screen tap-catcher can
  // collapse it. Matches the PWA behaviour where any waypoint-drop or picking mode closes
  // the sheet (index.html:1413, 1606).
  bool _sheetExpanded = false;

  // Batch C: sun edge marker. PWA re-computes on a 60s interval (index.html:1196) plus on
  // resize; MediaQuery already covers resize since build() re-runs, so the timer only needs
  // to cover the clock ticking forward.
  bool _suntipOpen = false;
  Timer? _sunTimer;

  static const _homeCenter = LatLng(40.457, -74.15);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadLand();
    _loadLastPos().then((p) {
      final at = p ?? _homeCenter;
      _refreshWeather(at);
      _refreshAlerts(at);
      _refreshDaily(at);
      _refreshHourly(at);
      _refreshTides(at);
      _refreshTidalCurrent(at);
      if (p != null && mounted) {
        // Nudge the map to the last-known area so the user sees home water on load.
        // FlutterMap's controller isn't valid until the widget builds, so schedule for after.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try { _controller.move(p, 12); } catch (_) {}
        });
      }
    });
    BoatProfile.load().then((p) {
      if (!mounted) return;
      setState(() => _profile = p);
      // PWA index.html:500 — after 1.5 s on first launch (no saved profile at all), open the
      // modal. Checks whether a profile was ever saved, not whether specific fields are
      // filled in — see BoatProfile.hasSaved().
      BoatProfile.hasSaved().then((saved) {
        if (saved || !mounted) return;
        Future.delayed(const Duration(milliseconds: 1500), () async {
          if (!mounted) return;
          if (!(await BoatProfile.hasSaved()) && mounted) _openBoatProfile();
        });
      });
    });
    // Restore last-chosen tide unit (ft/m).
    SharedPreferences.getInstance().then((sp) {
      final u = sp.getString('tideUnit');
      if (u != null && (u == 'ft' || u == 'm') && mounted) setState(() => _tideUnit = u);
    });
    _wxTimer = Timer.periodic(const Duration(minutes: 20), (_) {
      final at = _me ?? _homeCenter;
      _refreshWeather(at);
      _refreshAlerts(at);
      _refreshDaily(at);
      _refreshHourly(at);
      _refreshTides(at);
      _refreshTidalCurrent(at);
      if (_docksOn) _refreshDocks(at);
      if (_navAidsOn) _refreshNavAids(at);
      _wxAt.clear();   // let stale grades fall through and refresh
      _gradeRouteWaypoints();
    });
    // Sun edge marker recompute — PWA re-ticks every 60s (index.html:1196).
    _sunTimer = Timer.periodic(const Duration(minutes: 1), (_) { if (mounted) setState(() {}); });
    // PWA index.html:1976-1978 — capture the browser's install prompt instead of letting it
    // show its own generic mini-infobar, then trigger it from our own button once the user
    // taps it. Chrome/Edge only; never fires on iOS Safari or once already installed.
    //
    // The actual 'beforeinstallprompt' capture + preventDefault() lives in web/index.html's
    // own early inline script now, not here — Flutter's JS/engine boot can take several
    // seconds, long enough for Chrome to fire this one-shot event before this initState() got
    // a listener attached, silently losing it (this is why the button worked on early, lighter
    // builds and stopped as the app grew heavier). The HTML script runs at initial page parse,
    // well before flutter_bootstrap.js even starts loading, and stores the event on
    // `window.__baysideDeferredPrompt` + fires a 'bayside-install-available' DOM event. Dart
    // just reads that global — once right here (covers the common case: already captured
    // before Flutter finished booting) and again on the bridge event (covers the rarer case
    // where it fires after Flutter has already booted).
    _installPromptEvent = _readDeferredInstallPrompt();
    _installListener = ((web.Event e) {
      if (mounted) setState(() => _installPromptEvent = _readDeferredInstallPrompt());
    }).toJS;
    web.window.addEventListener('bayside-install-available', _installListener);
  }

  JSFunction? _installListener;
  web.Event? _installPromptEvent;
  // dart:js_interop_unsafe (the supported way to reach a JS global with no static Dart type)
  // — returns null if 'beforeinstallprompt' hasn't fired (not an install-eligible browser,
  // already installed, or just not yet).
  web.Event? _readDeferredInstallPrompt() {
    final v = web.window.getProperty<JSAny?>('__baysideDeferredPrompt'.toJS);
    if (v.isUndefinedOrNull) return null;
    return v as web.Event;
  }
  // PWA index.html:1978 — deferred.prompt(); await deferred.userChoice; then hide the button.
  // beforeinstallprompt's `prompt()`/`userChoice` aren't part of the standard typed web.Event,
  // so call them dynamically via dart:js_interop_unsafe (the supported way to reach vendor-
  // only JS APIs). Not awaiting userChoice — the browser's own native dialog takes over once
  // prompt() fires, so our button can just hide immediately rather than guess the exact
  // generic Promise<T> interop shape for a value nothing here needs to read.
  void _installApp() {
    final e = _installPromptEvent;
    if (e == null) return;
    e.callMethod<JSAny?>('prompt'.toJS);
    web.window.setProperty('__baysideDeferredPrompt'.toJS, null);
    setState(() => _installPromptEvent = null);
  }

  Future<void> _refreshAlerts(LatLng at) async {
    final a = await fetchNwsAlert(at);
    if (mounted) setState(() => _alert = a);
  }
  Future<void> _refreshDaily(LatLng at) async {
    final d = await fetchDailyForecast(at);
    if (mounted && d.isNotEmpty) setState(() => _daily = d);
  }
  Future<void> _refreshHourly(LatLng at) async {
    final h = await fetchHourlyForecast(at);
    if (mounted && h.isNotEmpty) setState(() => _hourly = h);
  }
  Future<void> _refreshDocks(LatLng at) async {
    if (mounted) setState(() { _docksLoading = true; _docksError = false; });
    final d = await fetchDocks(at);
    if (!mounted) return;
    setState(() {
      _docksLoading = false;
      if (d == null) { _docksError = true; } else { _docks = d; _docksError = false; }
    });
  }
  Future<void> _refreshNavAids(LatLng at) async {
    if (mounted) setState(() { _navAidsLoading = true; _navAidsError = false; });
    final a = await fetchNavAids(at);
    if (!mounted) return;
    setState(() {
      _navAidsLoading = false;
      if (a == null) { _navAidsError = true; } else { _navAids = a; _navAidsError = false; }
    });
  }
  Future<void> _refreshTidalCurrent(LatLng at) async {
    final c = await fetchTidalCurrent(at);
    if (mounted) setState(() => _tidalCurrent = c);
  }

  // Batch A.5: `store.lastPos` parity — remember the last GPS fix so the next launch centres
  // the map on home water even before the user grants location.
  Future<LatLng?> _loadLastPos() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final s = sp.getString('lastPos');
      if (s == null) return null;
      final j = jsonDecode(s) as Map<String, dynamic>;
      final lat = (j['lat'] as num?)?.toDouble();
      final lng = (j['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) return null;
      return LatLng(lat, lng);
    } catch (_) { return null; }
  }
  Future<void> _saveLastPos(LatLng p) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('lastPos', jsonEncode({'lat': p.latitude, 'lng': p.longitude}));
    } catch (_) {}
  }
  Future<void> _refreshTides(LatLng at) async {
    final stations = await _loadTideStations();
    if (stations.isEmpty) return;
    final s = _nearestTide(at, stations);
    if (s == null) return;
    final t = await fetchTides(s);
    if (mounted) setState(() { _tideStation = s; _tides = t; });
  }

  String _gradeAt(LatLng p) {
    final e = _wxAt[_gkey(p)];
    if (e != null && DateTime.now().difference(e.t).inMinutes < 20) return e.grade;
    // fall back to the boat's current grade (weather HUD) if we haven't yet fetched a per-waypoint grade
    final w = _weather;
    if (w == null) return 'g';
    return score(w.windKt, w.gustKt, null, _profile);
  }

  // Break the route line into ~14 short segments per waypoint hop and colour each by the grade at
  // the anchor waypoints, interpolating between them — same trick the PWA uses in renderRoute
  // (index.html:1520-1538). Each segment draws a dark halo UNDERLAY first, then the graded
  // colour on top — "so the colour reads over any basemap" per the PWA's own comment. Flutter
  // was previously missing the halo entirely and used the wrong dash cadence ([10,8] instead
  // of the PWA's [3,10]).
  List<Polyline> _gradedRouteSegments(List<LatLng> pts) {
    final out = <Polyline>[];
    const N = 14;
    for (int i = 0; i < pts.length - 1; i++) {
      final a = pts[i], b = pts[i + 1];
      final la = _gLevel(_gradeAt(a));
      final lb = _gLevel(_gradeAt(b));
      final wt = i == _legIdx ? 5.0 : 4.0;   // PWA: legI===legIdx ? 5 : 4 (index.html:1527)
      for (int k = 0; k < N; k++) {
        final t0 = k / N, t1 = (k + 1) / N;
        final p0 = LatLng(a.latitude + (b.latitude - a.latitude) * t0, a.longitude + (b.longitude - a.longitude) * t0);
        final p1 = LatLng(a.latitude + (b.latitude - a.latitude) * t1, a.longitude + (b.longitude - a.longitude) * t1);
        // dark halo first — index.html:1533-1534
        out.add(Polyline(points: [p0, p1], color: const Color(0x730B2740), strokeWidth: wt + 2.4,
            pattern: StrokePattern.dashed(segments: const [3, 10])));
        // graded colour on top — index.html:1535-1536
        out.add(Polyline(points: [p0, p1], color: _gInterpolate(la, lb, (t0 + t1) / 2).withOpacity(.85), strokeWidth: wt,
            pattern: StrokePattern.dashed(segments: const [3, 10])));
      }
    }
    return out;
  }

  Future<void> _gradeRouteWaypoints() async {
    for (final wp in _waypoints) {
      final k = _gkey(wp);
      if (_wxPending.contains(k)) continue;
      final e = _wxAt[k];
      if (e != null && DateTime.now().difference(e.t).inMinutes < 20) continue;
      _wxPending.add(k);
      final g = await fetchWaypointGrade(wp, _profile);
      _wxPending.remove(k);
      if (g == null) continue;
      _wxAt[k] = WxSample(g, DateTime.now());
      if (mounted) setState(() {});
    }
  }

  // Reacquire the wake lock when the tab regains foreground visibility while navigating.
  // Browsers release Screen Wake Lock automatically when a tab is hidden (switching apps,
  // locking the phone); Flutter's AppLifecycleState.resumed maps to the PWA's
  // `document.visibilitychange` -> 'visible' handler that the plan calls for.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _navigating) {
      WakelockPlus.enable();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gpsSub?.cancel();
    _wxTimer?.cancel();
    _sunTimer?.cancel();
    if (_installListener != null) web.window.removeEventListener('bayside-install-available', _installListener);
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _refreshWeather(LatLng at) async {
    final w = await fetchWeather(at);
    if (mounted && w != null) setState(() => _weather = w);
  }

  Future<void> _startGps() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        setState(() => _statusText = 'Location denied');
        return;
      }
      _gpsSub?.cancel();
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 3),
      ).listen(_onFix, onError: (_) => mounted ? setState(() => _statusText = 'GPS error') : null);
      setState(() => _statusText = 'Searching for GPS…');
    } catch (_) {
      setState(() => _statusText = 'GPS unavailable');
    }
  }

  void _onFix(Position p) {
    final wasNav3D = _navigating && _mapStyleUrl.isNotEmpty && _mobPoint == null && _anchorPoint == null;
    final here = LatLng(p.latitude, p.longitude);
    double h = _heading;
    if (p.heading > 0) {
      h = p.heading;
    } else if (_me != null) {
      final d = _haversineM(_me!, here);
      if (d > 3) h = _bearingDeg(_me!, here);
    }
    double s = _speedKt;
    final gpsSpd = p.speed;
    if (gpsSpd.isFinite && gpsSpd >= 0) {
      s = gpsSpd * 1.943844;
    } else if (_trail.isNotEmpty && _me != null) {
      final prev = _trail.last;
      final dtSec = (DateTime.now().millisecondsSinceEpoch - prev.tMs) / 1000.0;
      final dm = _haversineM(_me!, here);
      if (dtSec > 0.3 && dtSec < 6 && dm > 3) s = (dm / dtSec) * 1.943844;
    }
    setState(() {
      _me = here;
      _heading = h;
      _speedKt = s;
      _accuracyM = p.accuracy;
      _statusText = 'GPS ±${p.accuracy.round()} m';
      _trail.add(_TrailPoint(here, DateTime.now().millisecondsSinceEpoch));
      final cutoff = DateTime.now().millisecondsSinceEpoch - 10 * 60 * 1000;
      _trail.removeWhere((t) => t.tMs < cutoff);
    });
    _saveLastPos(here);   // remember for next launch so we open on home water
    // re-route on movement (smart routes cache keyed on last leg endpoints, but simplest: recompute)
    _recomputeRoute();
    // auto-advance waypoints while actively navigating — 100 m radius is generous enough for a
    // moving boat not to overshoot a tight fence
    if (_navigating && _waypoints.isNotEmpty && _legIdx < _waypoints.length) {
      final d = _haversineM(here, _waypoints[_legIdx]);
      if (d < 100) {
        if (_legIdx < _waypoints.length - 1) {
          _legIdx++;
        } else {
          _stopRide();   // arrived at final point
        }
      }
    }
    // anchor watch: if a point is set and drift > radius, mark as breached (would vibrate on native)
    if (_anchorPoint != null) {
      final drift = _haversineM(here, _anchorPoint!);
      final radiusM = _anchorRadiusFt * 0.3048;
      final breached = drift > radiusM;
      if (breached != _anchorBreached) setState(() => _anchorBreached = breached);
    }
    // follow the boat (and course-up rotate in nav mode)
    // FlutterMap is removed from the tree while the MapLibre nav view is shown.
    // Its controller must only be used when its map is attached.
    if (_follow && !wasNav3D && !(_navigating && _mapStyleUrl.isNotEmpty && _mobPoint == null && _anchorPoint == null)) {
      _controller.move(here, math.max(_controller.camera.zoom, _navigating ? 16 : 14));
      if (_navigating) _controller.rotate(-h);   // rotate so heading is up
    }
  }

  // ---------- MOB / anchor / fuel ring ----------
  void _toggleMob() {
    final dropping = _mobPoint == null;
    setState(() {
      if (_mobPoint != null) { _mobPoint = null; return; }
      _mobPoint = _me ?? _homeCenter;
    });
    // PWA: navigator.vibrate([300,120,300,120,300]) on drop (index.html:1907). Web Vibration
    // API doesn't take patterns through Flutter's HapticFeedback, so fire three impacts on
    // the same cadence.
    if (dropping) _tripleVibrate();
  }
  Future<void> _tripleVibrate() async {
    HapticFeedback.mediumImpact();
    await Future.delayed(const Duration(milliseconds: 420));
    HapticFeedback.mediumImpact();
    await Future.delayed(const Duration(milliseconds: 420));
    HapticFeedback.mediumImpact();
  }
  void _toggleAnchor() {
    setState(() {
      if (_anchorPoint != null) { _anchorPoint = null; _anchorBreached = false; return; }
      _anchorPoint = _me ?? _homeCenter;
      _anchorRadiusFt = 100;
    });
  }
  void _bumpAnchor(double deltaFt) => setState(() {
    _anchorRadiusFt = math.max(25, _anchorRadiusFt + deltaFt);
  });
  void _toggleFuelRing() {
    if (_profile.burn <= 0 || _profile.tank <= 0) { _openBoatProfile(); return; }
    setState(() => _fuelRingOn = !_fuelRingOn);
  }
  double? _fuelRingRadiusM() {
    if (!_fuelRingOn || _profile.burn <= 0 || _profile.tank <= 0) return null;
    // half-range at cruise with 25% reserve — matches the PWA's drawFuelRing
    final usable = _profile.tank * 0.75;
    final rangeNm = (usable / _profile.burn) * _profile.cruise;
    return (rangeNm / 2) * 1852;   // half-range circle in metres
  }

  // If the current weather is over any of the boat's profile limits (or ≥75% of them), return a
  // (text, severity) pair. Severity 'over' → red banner, 'near' → amber. Matches the PWA
  // `#boatwarn` default red (index.html:224) with `.a` amber class for the near case.
  ({String text, String severity})? _boatWarning() {
    final w = _weather;
    if (w == null) return null;
    final over = <String>[], near = <String>[];
    void chk(double? v, double lim, String Function(double) lbl) {
      if (v == null || lim <= 0) return;
      if (v > lim) over.add(lbl(v));
      else if (v > lim * 0.75) near.add(lbl(v));
    }
    chk(w.windKt, _profile.wind, (v) => 'wind ${v.round()} kn');
    chk(w.gustKt, _profile.gust, (v) => 'gusts ${v.round()} kn');
    chk(w.waveFt, _profile.wave, (v) => 'waves ${v.toStringAsFixed(1)} ft');
    final who = _profile.name.isEmpty ? 'your boat' : _profile.name;
    if (over.isNotEmpty) return (text: 'Too rough for $who right now: ${over.join(", ")}', severity: 'over');
    if (near.isNotEmpty) return (text: "Near $who's limit: ${near.join(", ")}", severity: 'near');
    return null;
  }

  Future<void> _openForecast() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ForecastSheet(daily: _daily),
    );
  }

  void _setTideUnit(String u) async {
    setState(() => _tideUnit = u);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('tideUnit', u);
    } catch (_) {}
  }

  // Placeholder for GPX import/export — real handler lands in Batch D.
  void _gpxPlaceholder() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('GPX import/export lands in Batch D'),
      duration: Duration(seconds: 2),
    ));
  }

  Future<void> _openMoreTools() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (sctx, setSheetState) {
        // The modal is a separate overlay route — setState() on _MapScreenState (fired inside
        // _refreshDocks/_refreshNavAids while the fetch is in flight) does NOT automatically
        // rebuild this popover. Await the refresh here and call setSheetState again once it
        // resolves so "Loading…" / the retry prompt actually show up while this sheet is open.
        Future<void> doDocks(bool v) async {
          setSheetState(() {});
          setState(() => _docksOn = v);
          if (v) { await _refreshDocks(_me ?? _homeCenter); setSheetState(() {}); }
        }
        Future<void> doNavAids(bool v) async {
          setSheetState(() {});
          setState(() => _navAidsOn = v);
          if (v) { await _refreshNavAids(_me ?? _homeCenter); setSheetState(() {}); }
        }
        return MoreToolsSheet(
          docksOn: _docksOn,
          navAidsOn: _navAidsOn,
          anchorOn: _anchorPoint != null,
          fuelOn: _fuelRingOn,
          smartOn: _smart,
          docksSub: _docksLoading ? 'Loading nearby docks…'
            : _docksError ? "Couldn't reach dock data — tap to retry" : null,
          navAidsSub: _navAidsLoading ? 'Loading nearby buoys…'
            : _navAidsError ? "Couldn't reach buoy data — tap to retry" : null,
          docksError: _docksError, navAidsError: _navAidsError,
          onRetryDocks: () => doDocks(true),
          onRetryNavAids: () => doNavAids(true),
          onToggleDocks: doDocks,
          onToggleNavAids: doNavAids,
          onToggleAnchor: (_) { Navigator.of(ctx).pop(); _toggleAnchor(); },
          onToggleFuel: (_) { Navigator.of(ctx).pop(); _toggleFuelRing(); },
          onToggleSmart: (_) { Navigator.of(ctx).pop(); setState(() => _smart = !_smart); _recomputeRoute(); },
          onOpenForecast: () { Navigator.of(ctx).pop(); _openForecast(); },
        );
      }),
    );
  }

  void _handleMapTap(TapPosition _, LatLng ll) => _handleMapPoint(ll);

  void _handleMapPoint(LatLng ll) {
    if (!_picking) {
      // PWA: any interaction with the map area closes the expanded sheet
      // (index.html:1413 clears on picking mode, :1606 clears on route drop). A tap elsewhere
      // on the map should likewise dismiss an open dock callout.
      if (_sheetExpanded) setState(() => _sheetExpanded = false);
      _closeDockPopup();
      return;
    }
    setState(() { _waypoints.add(ll); _sheetExpanded = false; });
    _recomputeRoute();
    _gradeRouteWaypoints();   // fetch a per-point forecast in the background so segments colour up
  }

  // "Route here" from a Dock callout: replace the current route with a single leg to that dock.
  void _routeToPoint(LatLng at) {
    setState(() {
      _waypoints
        ..clear()
        ..add(at);
      _legIdx = 0;
      _picking = false;
    });
    _recomputeRoute();
    _gradeRouteWaypoints();
  }

  Future<void> _recomputeRoute() async {
    if (!_smart || _waypoints.isEmpty) {
      setState(() { _routedPath = null; _routeUnverified = false; });
      return;
    }
    if (_land == null) await _loadLand();
    final start = _me ?? _homeCenter;
    final path = <LatLng>[start];
    bool unverified = false;
    LatLng prev = start;
    for (final wp in _waypoints) {
      final leg = smartRoute(prev, wp, _land);
      if (leg == null) { path.add(wp); unverified = true; } else { path.addAll(leg.skip(1)); }
      prev = wp;
    }
    if (mounted) setState(() { _routedPath = path; _routeUnverified = unverified; });
  }

  double _routeNm() {
    // _me ?? _homeCenter — matches _recomputeRoute()'s own fallback (line 1566) and the ghost
    // boat marker, so distance/ETA read correctly even before GPS locks on, instead of silently
    // dropping the start point and reporting 0.
    final pts = _routedPath ?? [
      _me ?? _homeCenter,
      ..._waypoints,
    ];
    if (pts.length < 2) return 0;
    double m = 0;
    for (int i = 1; i < pts.length; i++) m += _haversineM(pts[i - 1], pts[i]);
    return m / 1852.0;
  }

  int _etaMin() {
    final nm = _routeNm();
    if (nm <= 0) return 0;
    final cruise = _speedKt > 1.5 ? _speedKt : _profile.cruise;
    return (nm / cruise * 60).round();
  }

  double _fuelGal() {
    if (_profile.burn <= 0) return 0;
    return (_etaMin() / 60.0) * _profile.burn;
  }

  // ---------- Start Ride ----------
  Future<void> _startRide() async {
    if (_waypoints.isEmpty) return;
    setState(() { _navigating = true; _follow = true; _picking = false; _legIdx = 0; });
    try { await WakelockPlus.enable(); } catch (_) {}
    if (_me != null && (_mapStyleUrl.isEmpty || _mobPoint != null || _anchorPoint != null)) {
      _controller.move(_me!, math.max(_controller.camera.zoom, 16));
    }
  }

  Future<void> _openBoatProfile() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => BoatProfileSheet(
        initial: _profile,
        onSave: (p) async {
          await p.save();
          if (mounted) setState(() { _profile = p; _wxAt.clear(); });
          _gradeRouteWaypoints();   // re-grade against the new limits
        },
      ),
    );
  }
  Future<void> _stopRide() async {
    final wasNav3D = _navigating && _mapStyleUrl.isNotEmpty && _mobPoint == null && _anchorPoint == null;
    setState(() => _navigating = false);
    if (wasNav3D) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _navigating) return;
        _controller.move(_me ?? _homeCenter, 16);
        _controller.rotate(0);
      });
    } else {
      _controller.rotate(0);   // back to north-up
    }
    try { await WakelockPlus.disable(); } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final boatWarning = _boatWarning();
    // Dismissal applies to this warning episode. A clear period or a change in
    // severity makes the next warning visible again.
    if (boatWarning == null || boatWarning.severity != _dismissedBoatWarningSeverity) {
      _dismissedBoatWarningSeverity = null;
    }
    // Same _me ?? _homeCenter fallback as _routeNm() — without it the drawn line silently
    // dropped its starting point whenever GPS hadn't locked on yet, so it only ever connected
    // waypoint-to-waypoint and never boat-to-first-waypoint.
    final routeLine = _routedPath ?? <LatLng>[
      _me ?? _homeCenter,
      ..._waypoints,
    ];
    final tiltMatrix = Matrix4.identity()
      ..setEntry(3, 2, 0.001)
      ..rotateX(_navigating ? 0.785398 : 0.0);   // 45 deg
    // Nav-only real-3D view (see plan, 2026-09-26): only engages with a style URL configured,
    // and never while MOB/anchor-watch is active — those safety overlays aren't ported to
    // Nav3DView in this pass, so stay on the regular (working) view rather than hide them.
    final useNav3D = _navigating && _mapStyleUrl.isNotEmpty && _mobPoint == null && _anchorPoint == null;
    final route3DSegments = <Nav3DRouteSegment>[];
    if (useNav3D && routeLine.length >= 2) {
      final graded = _gradedRouteSegments(routeLine);
      // The first polyline of each pair is a halo; the second carries the
      // warning grade. Preserve the existing grade calculation in 3D.
      for (var i = 1; i < graded.length; i += 2) {
        final p = graded[i];
        route3DSegments.add(Nav3DRouteSegment(
          p.points.first, p.points.last,
          _routeUnverified ? const Color(0xAA8A94A3) : p.color,
          p.strokeWidth,
        ));
      }
    }
    return Scaffold(
      body: SafeArea(
        child: Stack(children: [
          if (useNav3D)
            Nav3DView(
              key: ValueKey('nav3d-${_base.name}-$_mapStyleUrl'),
              styleUrl: _mapStyleUrl,
              basemap: _base.name,
              onMapTap: _handleMapPoint,
              boatPosition: _me ?? _homeCenter,
              headingDeg: _heading,
              follow: _follow,
              routeSegments: route3DSegments,
              waypoints: _waypoints,
            )
          else
          // The map itself, wrapped in a Transform that tilts to ~45° during active nav (matches the
          // PWA's `body.nav-active #map { transform: perspective... rotateX(45deg) }` trick — Flutter
          // widgets support the same perspective/rotate math via Matrix4).
          AnimatedContainer(
            duration: const Duration(milliseconds: 700),
            curve: Curves.easeInOut,
            transformAlignment: const Alignment(0, 0.2),
            transform: tiltMatrix,
            child: Stack(children: [
              FlutterMap(
              mapController: _controller,
              options: MapOptions(
                initialCenter: _homeCenter,
                initialZoom: 11,
                minZoom: 3,
                maxZoom: 19,
                onTap: _handleMapTap,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
              ),
              children: [
                ..._baseLayers(_base, _cartoKey),
                // Sat has no baked-in labels (unlike the street/dark bases) — PWA always
                // shows roads + place names over it (index.html:519-521, 544).
                if (_base == Basemap.sat) ...[
                  TileLayer(urlTemplate: _esriRoadsUrl, userAgentPackageName: 'net.bayside.flutter'),
                  TileLayer(urlTemplate: _esriPlacesUrl, userAgentPackageName: 'net.bayside.flutter'),
                ],
                // NOAA ENC MarineChart — Chart mode only. The PWA (and Savvy Navvy, checked
                // for reference) both overlay this on Sat/Dark too at reduced opacity, but
                // the user explicitly wants a deliberate deviation here: NOAA exclusive to
                // Chart, so Sat/Dark stay plain imagery/dark tiles with no chart clutter.
                // zoomOffset:-2 matches the PWA's L.tileLayer(..., {zoomOffset:-2, ...}) —
                // NOAA's tile service uses a coarser zoom scheme than the map's displayed
                // zoom, so tiles must be requested 2 levels lower or the server 404s on
                // every single tile (confirmed live: user's console showed 404s at z=12
                // while the map displayed at z=14 — exactly the missing offset).
                if (_base == Basemap.chart)
                  TileLayer(urlTemplate: _noaaChartUrl, userAgentPackageName: 'net.bayside.flutter',
                    zoomOffset: -2, minZoom: 2, maxNativeZoom: 18, maxZoom: 19,
                    tileDisplay: const TileDisplay.instantaneous(opacity: 1.0)),
                if (_trail.length > 1)
                  PolylineLayer(polylines: [
                    Polyline(points: _trail.map((t) => t.p).toList(), color: const Color(0xAAFFFFFF), strokeWidth: 4),
                  ]),
                if (routeLine.length >= 2)
                  PolylineLayer(polylines: _routeUnverified
                    ? [Polyline(points: routeLine, color: const Color(0xAA8a94a3), strokeWidth: 4,
                        pattern: StrokePattern.dashed(segments: const [10, 8]))]
                    : _gradedRouteSegments(routeLine),
                  ),
                // fuel range ring (half-tank at cruise) + anchor watch circle
                CircleLayer(circles: [
                  if (_me != null && _fuelRingRadiusM() != null)
                    CircleMarker(
                      point: _me!,
                      radius: _fuelRingRadiusM()!,
                      useRadiusInMeter: true,
                      color: const Color(0x1AF2A93B),
                      borderColor: const Color(0xAAF2A93B),
                      borderStrokeWidth: 2,
                    ),
                  if (_anchorPoint != null)
                    // Fill only here — PWA's anchor circle border is DASHED
                    // (dashArray:'6 8', index.html:1934), which CircleMarker can't draw;
                    // the dashed ring itself is a separate PolylineLayer just below.
                    CircleMarker(
                      point: _anchorPoint!,
                      radius: _anchorRadiusFt * 0.3048,
                      useRadiusInMeter: true,
                      color: _anchorBreached ? const Color(0x33D93A2B) : const Color(0x0F0F2A44),
                      borderStrokeWidth: 0,
                    ),
                ]),
                // Dashed anchor-watch ring — PWA: L.circle(..., {color:'#0F2A44', weight:2,
                // dashArray:'6 8', fillOpacity:.06}) (index.html:1934). CircleMarker has no
                // dash support, so the outline is drawn as a many-point dashed Polyline circle.
                if (_anchorPoint != null)
                  PolylineLayer(polylines: [
                    Polyline(
                      points: _circlePoints(_anchorPoint!, _anchorRadiusFt * 0.3048),
                      color: _anchorBreached ? const Color(0xFFD93A2B) : const Color(0xFF0F2A44),
                      strokeWidth: 2,
                      pattern: StrokePattern.dashed(segments: const [6, 8]),
                    ),
                  ]),
                // MOB dashed line back from boat to the pin
                if (_mobPoint != null && _me != null)
                  PolylineLayer(polylines: [
                    Polyline(points: [_me!, _mobPoint!], color: const Color(0xFFD93A2B), strokeWidth: 3,
                        pattern: StrokePattern.dashed(segments: const [6, 6])),
                  ]),
                MarkerLayer(markers: [
                  if (_docksOn) for (final d in _docks)
                    Marker(
                      point: d.ll,
                      width: 28, height: 28,
                      child: _DockPin(
                        kind: d.kind, name: d.name,
                        isOpen: _openDock == d.ll,
                        onOpen: (topLeft, size) => _openDockPopup(d, topLeft, size),
                        onClose: _closeDockPopup,
                      ),
                    ),
                  if (_navAidsOn) for (final a in _navAids)
                    Marker(
                      point: a.ll,
                      width: 20, height: 24,
                      child: _NavAidPin(category: a.category, name: a.name),
                    ),
                  if (_tidalCurrent != null)
                    Marker(
                      point: _tidalCurrent!.ll,
                      width: 44, height: 44,
                      child: _TidalCurrentArrow(sample: _tidalCurrent!),
                    ),
                  for (int i = 0; i < _waypoints.length; i++)
                    Marker(
                      point: _waypoints[i],
                      // Box sized to the LARGER (destination, 34x46) pin; the PWA anchors each
                      // teardrop at its own bottom tip (iconAnchor:[w/2,h], index.html:1573).
                      // flutter_map's own `alignment` param is inverted from what the name
                      // suggests: per its actual offset formula (marker_layer.dart), passing
                      // Alignment.bottomCenter here places the box's TOP edge at the geo point
                      // (box drawn downward FROM the point) — the opposite of "pin tip at the
                      // point". Alignment.topCenter is what puts the box's BOTTOM (and so the
                      // pin's tip, via the inner Align below) exactly at the point. Confirmed by
                      // measuring a live drop: with bottomCenter the tip rendered ~31px below
                      // the actual tap location.
                      width: 34, height: 46,
                      alignment: Alignment.topCenter,
                      child: Align(alignment: Alignment.bottomCenter,
                        child: _WaypointPin(isDest: i == _waypoints.length - 1,
                          grade: _gradeAt(_waypoints[i]))),
                    ),
                  if (_mobPoint != null) ...[
                    // Smoke drifts with live wind, layered beneath the pulsing buoy so the
                    // buoy reads clearly on top — matches the PWA's z-index ordering
                    // (mobSmoke 905 < mobBuoy/mobMarker ~900-903 is actually the other way in
                    // the PWA; visually the buoy stays legible either way since smoke is
                    // translucent).
                    Marker(
                      point: _mobPoint!,
                      width: 80, height: 80,
                      child: _MobSmoke(windKt: _weather?.windKt ?? 4,
                        windDirDeg: (_weather?.windDirDeg ?? 0).toDouble()),
                    ),
                    if (_me != null)
                      Marker(
                        point: LatLng(
                          _me!.latitude + (_mobPoint!.latitude - _me!.latitude) * 0.88,
                          _me!.longitude + (_mobPoint!.longitude - _me!.longitude) * 0.88),
                        width: 24, height: 24,
                        child: _MobArrow(bearingDeg: _bearingDeg(_me!, _mobPoint!)),
                      ),
                    Marker(
                      point: _mobPoint!,
                      width: 90, height: 90,
                      child: const _MobPin(),
                    ),
                  ],
                  if (_anchorPoint != null)
                    Marker(
                      point: _anchorPoint!,
                      width: 20, height: 20,
                      child: const Icon(Icons.anchor, color: Color(0xFF2E6F9E), size: 20),
                    ),
                  if (_me != null) ...[
                    Marker(
                      point: _me!,
                      width: 60, height: 110,
                      child: BoatMarker(headingDeg: _heading, active: _navigating),
                    ),
                    // Wake spray — churning particles astern while underway. Anchored at the
                    // SAME LatLng as the boat and rotated by the SAME heading, so it moves/pans
                    // with the boat and doesn't need any screen-projection math. Painted AFTER
                    // (on top of) the boat marker, matching the PWA's #fx canvas sitting above
                    // the Leaflet marker layer (index.html:1026-1051).
                    Marker(
                      point: _me!,
                      width: 260, height: 260,
                      child: _WakeSpray(headingDeg: _heading, speedKt: _speedKt),
                    ),
                  ]
                  else
                    // Ghost boat at the map centre so users can see where the boat *would* be
                    // once GPS is granted — mirrors the PWA "search" state HUD.
                    Marker(
                      point: _homeCenter,
                      width: 60, height: 110,
                      child: const BoatMarker(headingDeg: 0, ghost: true),
                    ),
                ]),
              ],
              ),
              // Weather-animation canvas — wind, rain, snow, lightning, driven by live wx.
              // Sits above the map inside the same tilt Transform so it feels like weather over
              // the water rather than the screen.
              Positioned.fill(child: IgnorePointer(child: FxCanvas(
                windKt: _weather?.windKt ?? 0,
                gustKt: _weather?.gustKt ?? 0,
                windDirDeg: (_weather?.windDirDeg ?? 0).toDouble(),
                precipPct: _weather?.precipPct ?? 0,
                boatSpeedKt: _speedKt,
                weatherCode: _weather?.weatherCode ?? 0,
                lightBasemap: _base == Basemap.map || _base == Basemap.chart,
              ))),
            ]),
          ),
          // Sun/moon edge marker — PWA #sun is z-index 588 (index.html:257), LOWER than the
          // sheet's 610 and the route-bar-ish chrome's ~600. That means the PWA deliberately
          // lets the sheet/HUD COVER the sun marker whenever they overlap — it's meant to sit
          // above the map but below the persistent UI, not always-on-top. An earlier commit
          // moved this marker to paint dead-last (always on top of everything) to fix it being
          // invisible when hidden behind chrome — that was the wrong read: hidden-behind-chrome
          // is the PWA's own correct behaviour, not a bug. Reverted: placed here, above the
          // map/FX layer, below the HUD/rail/sheet — matching the real z-order.
          Positioned.fill(child: _SunEdgeMarker(
            at: _me ?? _homeCenter,
            sunrise: _weather?.sunrise, sunset: _weather?.sunset,
            open: _suntipOpen,
            onToggle: () => setState(() => _suntipOpen = !_suntipOpen),
          )),
          // HUD (never tilts — always flat). On wide screens (≥ 820 px) pin the column to the
          // left with a 390 px cap so it doesn't stretch to the right rail — matches the PWA
          // #sheet desktop width at index.html:273.
          Positioned(top: 12, left: 12,
            right: MediaQuery.sizeOf(context).width >= 820 ? null : 12,
            width: MediaQuery.sizeOf(context).width >= 820 ? 390 : null,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _TopHud(
              speedKt: _speedKt, status: _statusText, accuracyM: _accuracyM,
              base: _base, onBaseChange: (b) => setState(() => _base = b),
            ),
            if (_alert != null) ...[
              const SizedBox(height: 8),
              _AlertBanner(alert: _alert!, onDismiss: () => setState(() => _alert = null)),
            ],
            if (boatWarning != null && _dismissedBoatWarningSeverity == null) ...[
              const SizedBox(height: 8),
              _BoatWarningBanner(
                text: boatWarning.text, severity: boatWarning.severity,
                onDismiss: () => setState(() => _dismissedBoatWarningSeverity = boatWarning.severity),
              ),
            ],
            // MOB and active-navigation summaries used to float here as separate top-HUD
            // cards (_MobHud/_NavBar) — both now live in _NavShell below, as states of the
            // same region instead of independent widgets. Anchor watch is a different
            // feature, not part of that merge, and stays here untouched.
            if (_anchorPoint != null && _me != null) ...[
              const SizedBox(height: 8),
              _AnchorHud(from: _me!, to: _anchorPoint!, radiusFt: _anchorRadiusFt, breached: _anchorBreached,
                onPlus: () => _bumpAnchor(25), onMinus: () => _bumpAnchor(-25), onStop: _toggleAnchor),
            ],
          ])),
          // Tap-catcher — a transparent full-screen layer that closes the sheet when the user
          // taps outside it. Rendered ONLY while the sheet is expanded AND we're not in
          // waypoint-picking mode (Goto). When picking, taps must go through to the map so
          // the pin drops in one gesture — the map's onTap already handles collapse-on-drop.
          if (_sheetExpanded && !_picking)
            Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _sheetExpanded = false))),
          Positioned(right: 12, bottom: 140, child: _RightRail(
            follow: _follow, picking: _picking, gpsOn: _gpsSub != null,
            mobOn: _mobPoint != null,
            onFollow: () => setState(() {
              _follow = !_follow;
              if (_follow && _me != null && !useNav3D) _controller.move(_me!, math.max(_controller.camera.zoom, 14));
            }),
            // PWA index.html:1413 — turning picking on closes the sheet so the map is unobstructed.
            onGoto: () => setState(() { _picking = !_picking; if (_picking) _sheetExpanded = false; }),
            onLocate: _startGps,
            onMob: _toggleMob,
            onMoreTools: _openMoreTools,
            onBoatProfile: _openBoatProfile,
          )),
          // PWA desktop CSS (index.html:273): `#sheet{left:12px;right:auto;width:390px;...}`.
          // _NavShell is its own sibling widget above _BottomSheet (own shape/decoration,
          // a gap between them), not nested inside the sheet's Container/decoration — same
          // separate-element relationship index.html keeps between #routebar and #sheet,
          // even though _NavShell itself now covers more than #routebar alone did.
          Positioned(left: 12, bottom: 12,
            right: MediaQuery.sizeOf(context).width >= 820 ? null : 12,
            width: MediaQuery.sizeOf(context).width >= 820 ? 390 : null,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _NavShell(
                // MOB takes priority over navigating, which takes priority over plain
                // planning. Deliberately NOT gated on _me != null — _startRide()/_toggleMob()
                // both take effect without GPS, so the mode switch (and the Stop/End Route/
                // Stop Guidance button appearing) must too; only the distance/bearing shown
                // fall back to home-center below when there's no real fix yet.
                mode: _mobPoint != null
                  ? _NavMode.mob
                  : (_navigating && _waypoints.isNotEmpty && _legIdx < _waypoints.length
                      ? _NavMode.navigating
                      : _NavMode.planning),
                me: _me ?? _homeCenter,
                routeNm: _routeNm(), etaMin: _etaMin(), fuelGal: _fuelGal(),
                waypointCount: _waypoints.length, picking: _picking,
                unverified: _routeUnverified,
                onClearRoute: () async { setState(() { _waypoints.clear(); _picking = false; _routedPath = null; _legIdx = 0; }); await _stopRide(); },
                onUndoRoute: () { if (_waypoints.isEmpty) return; setState(() { _waypoints.removeLast(); if (_legIdx >= _waypoints.length) _legIdx = math.max(0, _waypoints.length - 1); }); _recomputeRoute(); },
                onStart: _startRide,
                onGpx: _gpxPlaceholder,
                navTarget: _legIdx < _waypoints.length ? _waypoints[_legIdx] : null,
                legIdx: _legIdx, totalWps: _waypoints.length, speedKt: _speedKt,
                onEndRoute: _stopRide,
                mobPoint: _mobPoint, onStopGuidance: _toggleMob,
              ),
              if (_picking || _waypoints.isNotEmpty) const SizedBox(height: 10),
              _BottomSheet(
                weather: _weather,
                window: bestWindow(_hourly, _profile),
                hourly: _hourly, daily: _daily, profile: _profile,
                tideStation: _tideStation, tides: _tides, tideUnit: _tideUnit,
                onTideUnitChanged: _setTideUnit,
                expanded: _sheetExpanded,
                onExpandedChanged: (v) => setState(() => _sheetExpanded = v),
                showInstallPrompt: _installPromptEvent != null,
                onInstall: _installApp,
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ==================================================================================================
// widgets
// ==================================================================================================

// Weather-animation canvas. Full-viewport overlay above the map, ignoring pointer events.
// Two depth layers each for wind streaks and rain (near = closer/faster/brighter, far =
// slower/dimmer) read as real atmospheric parallax instead of one flat particle speed; a
// periodic gust envelope (mirrors the PWA's rich-mode gust surge, index.html:1061-1065)
// makes wind speed pulse instead of sitting at a constant rate; rain spawns small splash
// rings scattered across the surface (not tied to a horizon line — this view is top-down,
// unlike the PWA's tilted map, so "where rain lands" has no single waterline here); snow
// and lightning are net-new (the PWA's own "thunder" was a flat screen flash with no bolt
// and no sound — index.html:1098,1109). Wake spray is a separate widget (_WakeSpray, above).
class FxCanvas extends StatefulWidget {
  final double windKt, gustKt, windDirDeg, precipPct, boatSpeedKt;
  final int weatherCode;   // Open-Meteo WMO code — drives snow/thunder gating
  final bool lightBasemap;   // Map/Chart = true (dark streaks), Sat/Dark = false (white streaks)
  const FxCanvas({super.key, required this.windKt, required this.gustKt, required this.windDirDeg,
    required this.precipPct, required this.boatSpeedKt, this.weatherCode = 0, this.lightBasemap = true});
  @override
  State<FxCanvas> createState() => _FxCanvasState();
}
class _FxCanvasState extends State<FxCanvas> with SingleTickerProviderStateMixin {
  late final _tick = createTicker(_step);
  final math.Random _rng = math.Random();
  final List<_WindStreak> _streaksFar = [], _streaksNear = [];
  final List<_RainDrop> _dropsFar = [], _dropsNear = [];
  final List<_SnowFlake> _flakes = [];
  final List<_Splash> _splashes = [];
  final List<_Bolt> _bolts = [];
  double _flash = 0;
  double _gustPhase = 0, _gustEnv = 0, _gustCooldown = 2;
  double _nextStrike = 4;
  int _lastMs = 0;
  Size _size = Size.zero;
  web.AudioContext? _audioCtx;

  // PWA's own raining()/snowing() thresholds (index.html:999-1000) — kept identical so the
  // Flutter FX layer triggers on the same conditions the weather HUD/condition text does.
  bool get _raining => widget.precipPct > 0 ||
      (widget.weatherCode >= 51 && widget.weatherCode <= 67) ||
      (widget.weatherCode >= 80 && widget.weatherCode <= 82) ||
      widget.weatherCode >= 95;
  bool get _snowing => widget.weatherCode >= 71 && widget.weatherCode <= 77;
  bool get _thunderstorm => widget.weatherCode >= 95;

  @override
  void initState() {
    super.initState();
    _nextStrike = 3 + _rng.nextDouble() * 4;
    _tick.start();
  }
  @override
  void dispose() {
    _tick.dispose();
    try { _audioCtx?.close(); } catch (_) {}
    super.dispose();
  }

  // Effective wind = base + a gust boost that rises and decays instead of a flat blend —
  // only engages when the gust is actually meaningfully above the sustained speed, same
  // gate the PWA uses (index.html:1063: `wx.gust > wx.wind+1`).
  double get _effWind {
    final gust = math.max(0.0, math.sin(_gustPhase)) * _gustEnv;
    return widget.windKt + (widget.gustKt - widget.windKt) * gust;
  }
  void _stepGust(double dt) {
    _gustCooldown -= dt;
    if (_gustCooldown <= 0 && widget.gustKt > widget.windKt + 1) {
      _gustCooldown = 3.5 + _rng.nextDouble() * 4;
      _gustPhase = 0;
      _gustEnv = 1;
    }
    _gustPhase += dt * 1.1;
    _gustEnv *= math.pow(0.22, dt).toDouble();
  }

  // Wind vector — screen x/y for a "wind is BLOWING TOWARD" motion. Meteorology gives dir
  // wind comes FROM, so motion travels toward dir+180. [mult] separates the depth layers.
  _Vec _windVec(double mult) {
    final rad = (widget.windDirDeg + 180) * math.pi / 180;
    final eff = _effWind * mult * 6;
    return _Vec(math.sin(rad) * eff, -math.cos(rad) * eff);
  }

  int _targetStreaks(double mult) => math.min(90, (10 + _effWind * 2.4 * mult).round());
  int _targetDrops(double mult) {
    if (!_raining) return 0;
    final floor = widget.weatherCode >= 95 ? 70.0 : widget.weatherCode >= 63 ? 50.0 : widget.weatherCode >= 51 ? 20.0 : 0.0;
    final base = math.max(floor, widget.precipPct * 1.6);
    return math.min(140, (8 + base * mult).round());
  }

  void _step(Duration elapsed) {
    if (_size == Size.zero) { setState(() {}); return; }
    final now = elapsed.inMilliseconds;
    final dt = _lastMs == 0 ? 0.016 : math.min(0.05, (now - _lastMs) / 1000);
    _lastMs = now;

    _stepGust(dt);
    final farVec = _windVec(0.6), nearVec = _windVec(1.0);

    _syncStreaks(_streaksFar, _targetStreaks(0.55));
    _syncStreaks(_streaksNear, _targetStreaks(1.0));
    _advanceStreaks(_streaksFar, farVec, dt);
    _advanceStreaks(_streaksNear, nearVec, dt);

    _syncDrops(_dropsFar, _targetDrops(0.55), 240, 340);
    _syncDrops(_dropsNear, _targetDrops(1.0), 340, 480);
    _advanceDrops(_dropsFar, farVec, dt);
    _advanceDrops(_dropsNear, nearVec, dt);
    _stepSplashes(dt);

    _syncFlakes(_snowing ? 150 : 0);
    _advanceFlakes(nearVec, dt);

    _stepLightning(dt);

    setState(() {});
  }

  // ---- wind streaks ----
  void _syncStreaks(List<_WindStreak> list, int target) {
    while (list.length < target) list.add(_spawnStreak());
    while (list.length > target) list.removeLast();
  }
  void _advanceStreaks(List<_WindStreak> list, _Vec v, double dt) {
    for (final s in list) {
      s.x += v.x * dt; s.y += v.y * dt;
      if (s.x < -20 || s.x > _size.width + 20 || s.y < -20 || s.y > _size.height + 20) _resetStreak(s);
    }
  }
  _WindStreak _spawnStreak() {
    final s = _WindStreak(0, 0, 8 + _rng.nextDouble() * 20);
    _resetStreak(s);
    return s;
  }
  void _resetStreak(_WindStreak s) {
    s.x = _rng.nextDouble() * (_size.width + 40) - 20;
    s.y = _rng.nextDouble() * (_size.height + 40) - 20;
  }

  // ---- rain ----
  void _syncDrops(List<_RainDrop> list, int target, double speedMin, double speedMax) {
    while (list.length < target) list.add(_spawnDrop(speedMin, speedMax));
    while (list.length > target) list.removeLast();
  }
  void _advanceDrops(List<_RainDrop> list, _Vec v, double dt) {
    for (final d in list) {
      d.x += v.x * 0.15 * dt; d.y += d.speed * dt;
      if (d.y > _size.height + 4) { d.x = _rng.nextDouble() * _size.width; d.y = -8; }
    }
  }
  _RainDrop _spawnDrop(double speedMin, double speedMax) => _RainDrop(
    _rng.nextDouble() * _size.width, _rng.nextDouble() * _size.height,
    speedMin + _rng.nextDouble() * (speedMax - speedMin),
  );

  // Splash rings scattered across the water — density tracks rain intensity. Not tied to
  // individual drops or a waterline: this is a top-down chart, every pixel is water, so
  // "rain hitting the surface" is its own ambient particle system, not a per-drop impact.
  void _stepSplashes(double dt) {
    if (_raining) {
      final perSec = math.min(6.0, widget.precipPct / 10 + (_thunderstorm ? 2.5 : 0));
      if (_rng.nextDouble() < perSec * dt) {
        _splashes.add(_Splash(_rng.nextDouble() * _size.width, _rng.nextDouble() * _size.height, 1, 0.6));
      }
    }
    for (final s in _splashes) { s.r += 60 * dt; s.a -= dt * 2.2; }
    _splashes.removeWhere((s) => s.a <= 0);
  }

  // ---- snow ----
  void _syncFlakes(int target) {
    while (_flakes.length < target) _flakes.add(_spawnFlake());
    while (_flakes.length > target) _flakes.removeLast();
  }
  void _advanceFlakes(_Vec windNear, double dt) {
    for (final f in _flakes) {
      f.phase += dt * 0.9; f.twinkle += dt * 2.2;
      f.y += f.speed; f.x += math.sin(f.phase) * 0.5 + windNear.x * 0.05 * dt;
      if (f.y > _size.height) { f.y = -6; f.x = _rng.nextDouble() * _size.width; }
    }
  }
  _SnowFlake _spawnFlake() => _SnowFlake(
    _rng.nextDouble() * _size.width, _rng.nextDouble() * _size.height,
    1.1 + _rng.nextDouble() * 2.3, 0.6 + _rng.nextDouble() * 1.1,
    _rng.nextDouble() * 10, _rng.nextDouble() * 6,
  );

  // ---- lightning: a real branching bolt (midpoint displacement) + afterglow + rumble ----
  void _midpointBolt(double x1, double y1, double x2, double y2, double disp, int depth,
      List<_BoltSeg> segs, double branchProb) {
    if (depth <= 0 || disp < 4) { segs.add(_BoltSeg(x1, y1, x2, y2, 1)); return; }
    final mx = (x1 + x2) / 2 + (_rng.nextDouble() - 0.5) * disp;
    final my = (y1 + y2) / 2 + (_rng.nextDouble() - 0.5) * disp * 0.4;
    _midpointBolt(x1, y1, mx, my, disp * 0.55, depth - 1, segs, branchProb);
    _midpointBolt(mx, my, x2, y2, disp * 0.55, depth - 1, segs, branchProb);
    if (_rng.nextDouble() < branchProb && depth > 1) {
      final bx = x2 + (_rng.nextDouble() - 0.5) * disp * 2.2;
      final by = y2 + _rng.nextDouble() * disp * 2.2;
      _midpointBolt(mx, my, bx, by, disp * 0.45, depth - 2, segs, branchProb * 0.4);
      if (segs.isNotEmpty) segs.last.alphaMul = 0.55;
    }
  }
  void _strike() {
    final x1 = _size.width * (0.15 + _rng.nextDouble() * 0.7), y1 = -10.0;
    final x2 = x1 + (_rng.nextDouble() - 0.5) * _size.width * 0.18;
    final y2 = _size.height * (0.35 + _rng.nextDouble() * 0.3);
    final segs = <_BoltSeg>[];
    _midpointBolt(x1, y1, x2, y2, _size.width * 0.05, 6, segs, 0.35);
    _bolts.add(_Bolt(segs, 1));
    _flash = 1;
    _thunder();
  }
  void _stepLightning(double dt) {
    if (!_thunderstorm) { _bolts.clear(); _flash = 0; return; }
    _nextStrike -= dt;
    if (_nextStrike <= 0 && _size != Size.zero) { _strike(); _nextStrike = 3 + _rng.nextDouble() * 4; }
    for (final b in _bolts) { b.life -= dt * 7; }
    _bolts.removeWhere((b) => b.life <= 0);
    _flash = math.max(0.0, _flash - dt * 2.4);
  }

  // Synthesized rumble — a filtered noise burst whose lowpass sweeps down and whose start
  // is delayed relative to the flash, the way real thunder lags its lightning. Defensive
  // try/catch: browsers can refuse AudioContext before a user gesture, and that should
  // never surface as a crash in a boat-navigation app.
  void _thunder() {
    try {
      final ctx = _audioCtx ??= web.AudioContext();
      final delay = 0.25 + _rng.nextDouble() * 0.7;
      final dur = 1.6 + _rng.nextDouble() * 1.0;
      final sampleRate = ctx.sampleRate;
      final bufSize = (sampleRate * dur).floor();
      final buffer = ctx.createBuffer(1, bufSize, sampleRate);
      final data = buffer.getChannelData(0).toDart;
      for (var i = 0; i < data.length; i++) { data[i] = (_rng.nextDouble() * 2 - 1) * 0.6; }
      final src = ctx.createBufferSource()..buffer = buffer;
      final filt = ctx.createBiquadFilter()..type = 'lowpass';
      final now = ctx.currentTime;
      filt.frequency
        ..setValueAtTime(900, now + delay)
        ..exponentialRampToValueAtTime(70, now + delay + dur);
      final gain = ctx.createGain();
      gain.gain
        ..setValueAtTime(0.0001, now + delay)
        ..linearRampToValueAtTime(0.5, now + delay + 0.08)
        ..exponentialRampToValueAtTime(0.001, now + delay + dur);
      src.connect(filt);
      filt.connect(gain);
      gain.connect(ctx.destination);
      src.start(now + delay);
      src.stop(now + delay + dur + 0.05);
    } catch (_) {
      // No audio output available (autoplay policy, unsupported browser) — the bolt and
      // flash still read as a strike on their own.
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (ctx, cs) {
    final s = Size(cs.maxWidth, cs.maxHeight);
    if (s != _size) _size = s;
    return CustomPaint(painter: _FxPainter(
      streaksFar: _streaksFar, streaksNear: _streaksNear,
      dropsFar: _dropsFar, dropsNear: _dropsNear,
      flakes: _flakes, splashes: _splashes, bolts: _bolts, flash: _flash,
      windDirDeg: widget.windDirDeg, lightBasemap: widget.lightBasemap,
    ), size: s);
  });
}

class _Vec { final double x, y; const _Vec(this.x, this.y); }
class _WindStreak { double x, y, length; _WindStreak(this.x, this.y, this.length); }
class _RainDrop { double x, y, speed; _RainDrop(this.x, this.y, this.speed); }
class _SnowFlake {
  double x, y, r, speed, phase, twinkle;
  _SnowFlake(this.x, this.y, this.r, this.speed, this.phase, this.twinkle);
}
class _Splash { double x, y, r, a; _Splash(this.x, this.y, this.r, this.a); }
class _BoltSeg {
  double x1, y1, x2, y2, alphaMul;
  _BoltSeg(this.x1, this.y1, this.x2, this.y2, this.alphaMul);
}
class _Bolt { final List<_BoltSeg> segs; double life; _Bolt(this.segs, this.life); }

class _FxPainter extends CustomPainter {
  final List<_WindStreak> streaksFar, streaksNear;
  final List<_RainDrop> dropsFar, dropsNear;
  final List<_SnowFlake> flakes;
  final List<_Splash> splashes;
  final List<_Bolt> bolts;
  final double flash, windDirDeg;
  final bool lightBasemap;
  _FxPainter({required this.streaksFar, required this.streaksNear, required this.dropsFar,
    required this.dropsNear, required this.flakes, required this.splashes, required this.bolts,
    required this.flash, required this.windDirDeg, required this.lightBasemap});

  @override
  void paint(Canvas canvas, Size size) {
    // Direction the wind is BLOWING TOWARD (dir + 180) — shared by streaks and rain lean.
    final rad = (windDirDeg + 180) * math.pi / 180;
    final dx = math.sin(rad), dy = -math.cos(rad);
    // PWA index.html:1071: dark navy 50% on Map/Chart, white 70% on Sat/Dark — Flutter's
    // earlier white-only ~5-13% opacity was nearly invisible against a detailed basemap.
    final streakColor = lightBasemap ? const Color(0xFF0F2A44) : Colors.white;
    _paintStreaks(canvas, streaksFar, streakColor.withOpacity(.22), 1.0, dx, dy);
    _paintStreaks(canvas, streaksNear, streakColor.withOpacity(.42), 1.4, dx, dy);
    // Was capped at .36 max (barely visible) — PWA rain reaches up to .85 (index.html:1082).
    _paintRain(canvas, dropsFar, .32, 1.1, dx, dy);
    _paintRain(canvas, dropsNear, .58, 1.5, dx, dy);
    _paintSplashes(canvas);
    _paintSnow(canvas);
    _paintLightning(canvas, size);
  }

  void _paintStreaks(Canvas canvas, List<_WindStreak> list, Color color, double widthPx, double dx, double dy) {
    if (list.isEmpty) return;
    final paint = Paint()..color = color..strokeWidth = widthPx..strokeCap = StrokeCap.round;
    for (final s in list) {
      canvas.drawLine(Offset(s.x, s.y), Offset(s.x + dx * s.length, s.y + dy * s.length), paint);
    }
  }

  void _paintRain(Canvas canvas, List<_RainDrop> list, double alpha, double widthPx, double dx, double dy) {
    if (list.isEmpty) return;
    final paint = Paint()..strokeWidth = widthPx..strokeCap = StrokeCap.round
      ..color = const Color(0xFF78AADC).withOpacity(alpha);
    for (final d in list) {
      canvas.drawLine(Offset(d.x, d.y), Offset(d.x + dx * 4, d.y + 10), paint);
    }
  }

  void _paintSplashes(Canvas canvas) {
    if (splashes.isEmpty) return;
    for (final s in splashes) {
      final paint = Paint()
        ..style = PaintingStyle.stroke..strokeWidth = 1
        ..color = const Color(0xFFC8E1F5).withOpacity(s.a.clamp(0, 1).toDouble());
      canvas.drawOval(Rect.fromCenter(center: Offset(s.x, s.y), width: s.r * 2, height: s.r * 0.7), paint);
    }
  }

  void _paintSnow(Canvas canvas) {
    if (flakes.isEmpty) return;
    for (final f in flakes) {
      final tw = 0.65 + math.sin(f.twinkle) * 0.35;
      canvas.drawCircle(Offset(f.x, f.y), f.r,
        Paint()..color = Colors.white.withOpacity((0.55 + tw * 0.4).clamp(0, 1).toDouble()));
    }
  }

  void _paintLightning(Canvas canvas, Size size) {
    for (final b in bolts) {
      final a = b.life.clamp(0, 1).toDouble();
      for (final seg in b.segs) {
        final paint = Paint()
          ..color = const Color(0xFFFFF8E1).withOpacity((a * seg.alphaMul).clamp(0, 1).toDouble())
          ..strokeWidth = seg.alphaMul > 0.7 ? 2.4 : 1.3
          ..strokeCap = StrokeCap.round
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 * a);
        canvas.drawLine(Offset(seg.x1, seg.y1), Offset(seg.x2, seg.y2), paint);
      }
    }
    if (flash > 0) {
      canvas.drawRect(Offset.zero & size,
        Paint()..color = const Color(0xFFFFF8E1).withOpacity((flash * 0.45).clamp(0, 1).toDouble()));
    }
  }

  @override
  bool shouldRepaint(covariant _FxPainter old) => true;   // frame-driven repaint
}

// Batch C: sun edge marker + tap popover. Port of index.html #sun / #suntip (1130-1197).
// Switches between the sun glyph (day) and a phase-accurate moon glyph (night) using the
// same day/night threshold the PWA's weather header already uses for its icon swap
// (index.html:677: `night = solarPos(...).el < -0.83`). The moon marker itself is a
// deliberate enhancement beyond the PWA — the PWA's #sun simply disappears at night.
class _SunEdgeMarker extends StatelessWidget {
  final LatLng at;
  final DateTime? sunrise, sunset;
  final bool open;
  final VoidCallback onToggle;
  const _SunEdgeMarker({required this.at, this.sunrise, this.sunset, required this.open, required this.onToggle});
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, cs) {
      final size = Size(cs.maxWidth, cs.maxHeight);
      if (size.width <= 0 || size.height <= 0) return const SizedBox.shrink();
      final now = DateTime.now();
      final sun = solarPos(at.latitude, at.longitude, now);
      final isNight = sun.elDeg < -0.83;
      double clampD(double v, double lo, double hi) => hi < lo ? lo : v.clamp(lo, hi);

      if (!isNight) {
        final op = sunOpacity(sun.elDeg);
        if (op <= 0.02) return const SizedBox.shrink();
        final edge = sunEdgePoint(sun.azDeg, size);
        final low = sun.elDeg < 6;
        return Stack(children: [
          Positioned(
            left: edge.dx - 20, top: edge.dy - 20,
            child: GestureDetector(
              onTap: onToggle,
              // Always painted on top of the HUD/sheet (see the Stack ordering at the call
              // site) so a soft shadow plate reads as an intentional floating badge rather
              // than a glitch when it happens to land over banner text.
              child: Opacity(opacity: op,
                child: DecoratedBox(
                  decoration: const BoxDecoration(shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 10, spreadRadius: 1)]),
                  child: CustomPaint(size: const Size(40, 40), painter: _SunGlyphPainter(low: low)),
                )),
            ),
          ),
          if (open) Positioned(
            left: clampD(edge.dx - 90, 8, size.width - 238),
            top: clampD(edge.dy + 28, 8, size.height - 140),
            child: _SunTip(sunrise: sunrise, sunset: sunset,
              azDeg: sun.azDeg, elDeg: sun.elDeg, bodyLabel: 'sun', extra: null, onClose: onToggle),
          ),
        ]);
      }

      // Night — show the moon at its own real position, faded through the same dusk curve.
      final moon = moonPos(at.latitude, at.longitude, now, sun.eclipticLonDeg);
      final op = moonOpacity(moon.elDeg);
      if (op <= 0.02) return const SizedBox.shrink();
      final edge = sunEdgePoint(moon.azDeg, size);
      return Stack(children: [
        Positioned(
          left: edge.dx - 20, top: edge.dy - 20,
          child: GestureDetector(
            onTap: onToggle,
            child: Opacity(opacity: op,
              child: DecoratedBox(
                decoration: const BoxDecoration(shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 10, spreadRadius: 1)]),
                child: CustomPaint(size: const Size(40, 40), painter: _MoonGlyphPainter(illum: moon.illum)),
              )),
          ),
        ),
        if (open) Positioned(
          left: clampD(edge.dx - 90, 8, size.width - 238),
          top: clampD(edge.dy + 28, 8, size.height - 140),
          child: _SunTip(sunrise: sunrise, sunset: sunset,
            azDeg: moon.azDeg, elDeg: moon.elDeg, bodyLabel: 'moon',
            extra: '${(moon.illum * 100).round()}% illuminated', onClose: onToggle),
        ),
      ]);
    });
  }
}

// Grey disc with a dark terminator shadow whose offset encodes the illumination fraction —
// a standard schematic moon-phase glyph (full at illum≈1, thin crescent near illum≈0).
class _MoonGlyphPainter extends CustomPainter {
  final double illum;   // 0 (new) .. 1 (full)
  const _MoonGlyphPainter({required this.illum});
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 * 0.85;
    canvas.drawCircle(c, r, Paint()
      ..shader = RadialGradient(colors: [const Color(0xFFF4F3EE), const Color(0xFFD9D6CC), const Color(0xFFB9B6AC)])
          .createShader(Rect.fromCircle(center: c, radius: r)));
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF8A8778)..style = PaintingStyle.stroke..strokeWidth = 1.1);
    // shadow disc slides from fully covering (new moon) to fully off (full moon)
    final shadowOffset = r * 2 * (1 - illum);
    canvas.save();
    canvas.clipPath(ui.Path()..addOval(Rect.fromCircle(center: c, radius: r)));
    canvas.drawCircle(Offset(c.dx + shadowOffset - r, c.dy), r, Paint()..color = const Color(0xE60F2A44));
    canvas.restore();
  }
  @override
  bool shouldRepaint(covariant _MoonGlyphPainter old) => old.illum != illum;
}

// Layered 8-point star + radial-gradient disc — approximates the PWA's inline SUN_SVG
// (index.html:1132-1141) without needing a bundled asset.
class _SunGlyphPainter extends CustomPainter {
  final bool low;
  const _SunGlyphPainter({required this.low});
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    ui.Path star(double outer, double inner, double rot) {
      final p = ui.Path();
      for (int i = 0; i < 16; i++) {
        final rad = i.isEven ? outer : inner;
        final a = (rot + i * (360 / 16)) * math.pi / 180;
        final pt = Offset(c.dx + rad * math.sin(a), c.dy - rad * math.cos(a));
        i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
      }
      p.close();
      return p;
    }
    final tint = low ? const Color(0xFFE8A33C) : const Color(0xFFF7B10E);
    canvas.drawPath(star(r, r * 0.62, 0), Paint()..color = const Color(0x80FBBF1C));
    canvas.drawPath(star(r * 0.95, r * 0.6, 11.25), Paint()..color = tint);
    canvas.drawCircle(c, r * 0.47, Paint()
      ..shader = RadialGradient(colors: [const Color(0xFFFFF7DE), const Color(0xFFFFD34E), const Color(0xFFF0A00E)])
          .createShader(Rect.fromCircle(center: c, radius: r * 0.47)));
    canvas.drawCircle(c, r * 0.47, Paint()..color = const Color(0xFFE8951C)
      ..style = PaintingStyle.stroke..strokeWidth = 1.4);
    canvas.drawCircle(Offset(c.dx - r * 0.1, c.dy - r * 0.1), r * 0.19,
      Paint()..color = const Color(0xD9FFF7DE));
  }
  @override
  bool shouldRepaint(covariant _SunGlyphPainter old) => old.low != low;
}

class _SunTip extends StatelessWidget {
  final DateTime? sunrise, sunset;
  final double azDeg, elDeg;
  final String bodyLabel;   // 'sun' or 'moon' — used in the altitude/bearing caption
  final String? extra;      // extra line shown above the caption (e.g. moon illumination %)
  final VoidCallback onClose;
  const _SunTip({required this.sunrise, required this.sunset, required this.azDeg, required this.elDeg,
    this.bodyLabel = 'sun', this.extra, required this.onClose});
  @override
  Widget build(BuildContext context) {
    return Material(color: Colors.transparent,
      child: InkWell(onTap: onClose, borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 230,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: const Color(0xF00F2A44), borderRadius: BorderRadius.circular(12),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10)]),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (sunrise != null) _row('Sunrise', _fmtTime(sunrise!)),
            if (sunset != null) _row('Sunset', _fmtTime(sunset!)),
            if (sunrise != null && sunset != null) _row('Golden light',
              'to ~${_fmtTime(sunrise!.add(const Duration(minutes: 40)))} · from ~${_fmtTime(sunset!.subtract(const Duration(minutes: 40)))}'),
            if (extra != null) _row('Moon', extra!),
            const SizedBox(height: 4),
            Text('$bodyLabel altitude ${elDeg.round()}° · bearing ${azDeg.round()}°',
              style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 11)),
          ]),
        ),
      ),
    );
  }
  Widget _row(String label, String value) => Padding(padding: const EdgeInsets.only(bottom: 2),
    child: RichText(text: TextSpan(children: [
      TextSpan(text: '$label ', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12.5)),
      TextSpan(text: value, style: const TextStyle(color: Colors.white, fontSize: 12.5)),
    ])));
}

// PWA index.html:190-191,556-558: the boat marker box is 60x110, the boat art itself renders
// at 31x76 (matches the source PNG's true 106x260 aspect ratio — narrow and tall), and the SVG
// carries `filter:drop-shadow(0 2px 3px rgba(0,0,0,.45))` for contrast against any basemap.
// The prior Flutter port forced the same artwork into a 40x40 SQUARE box; under BoxFit.contain
// that shrank the actual rendered width down to ~16px — nearly invisible on the map. Both the
// size and the drop-shadow are matched here.
class BoatMarker extends StatelessWidget {
  final double headingDeg;
  final bool active;
  // Was: true dimmed the boat to 35% opacity as a "GPS not fixed" placeholder. Checked the PWA
  // (index.html: `const boat = L.marker([home.lat, home.lng], {icon:boatIcon,...})`) — it shows
  // the boat marker at FULL opacity from the start, at the home/default position, and only moves
  // it once a real fix arrives. There is no dimmed-placeholder state in the spec at all; this was
  // a Flutter-only invention that made the boat look faded/washed-out any time GPS hadn't locked
  // on yet, independent of and on top of the actual color-contrast issue. Kept the field (still
  // used to hide the RIB crossfade layer below) but no longer reduces opacity.
  final bool ghost;
  const BoatMarker({super.key, required this.headingDeg, this.active = false, this.ghost = false});
  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: headingDeg * math.pi / 180,
      child: SizedBox(
        width: 60, height: 110,
        child: Stack(alignment: Alignment.center, children: [
          // classic top-down skiff (always there, fades OUT during Start ride)
          AnimatedOpacity(
            opacity: active ? 0 : 1,
            duration: const Duration(milliseconds: 500),
            child: const _ShadowedBoatImage(asset: 'assets/icons/boat_small.png', width: 31, height: 76),
          ),
          // photo-real orange RIB (fades IN during Start ride) — matches the PWA's boat crossfade
          if (!ghost) AnimatedOpacity(
            opacity: active ? 1 : 0,
            duration: const Duration(milliseconds: 500),
            child: const _ShadowedBoatImage(asset: 'assets/icons/boat-3d_small.png', width: 31, height: 76),
          ),
        ]),
      ),
    );
  }
}

// Renders `asset` twice: once tinted solid black-45%-alpha and gaussian-blurred, offset 2px
// down, as a silhouette-shaped drop shadow — then the real image on top, undelayed. This is
// the direct Flutter equivalent of CSS `filter: drop-shadow(0 2px 3px rgba(0,0,0,.45))`, which
// (unlike a BoxShadow) follows the image's own alpha silhouette rather than its bounding box.
class _ShadowedBoatImage extends StatelessWidget {
  final String asset;
  final double width, height;
  const _ShadowedBoatImage({required this.asset, required this.width, required this.height});
  @override
  Widget build(BuildContext context) => Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
    Positioned(
      top: 2,
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
        child: ColorFiltered(
          colorFilter: const ColorFilter.mode(Color(0x73000000), BlendMode.srcIn),
          child: Image.asset(asset, width: width, height: height, fit: BoxFit.contain,
            filterQuality: FilterQuality.high),
        ),
      ),
    ),
    // FilterQuality.high — the source PNG is 106×260, downscaled ~3.4x to fit this 31×76 box.
    // Default FilterQuality.low (bilinear) blurs the hull outline/shading badly at that ratio,
    // which read fine against the dark basemap but made the boat nearly disappear against the
    // light Map basemap's similarly pale water. The PWA renders the same PNG via a browser
    // <image> element, which doesn't have this softening.
    Image.asset(asset, width: width, height: height, fit: BoxFit.contain,
      filterQuality: FilterQuality.high),
  ]);
}

// PWA `pinIcon()` (index.html:1563-1573) — a teardrop SVG, 34x46 for the destination pin,
// 28x38 (34/46 * 0.82) for interim waypoints, anchored at the bottom point. Flutter previously
// used a generic Material location_on glyph at 32/26px — noticeably shorter and genericer than
// the PWA's teardrop. Ported as a CustomPainter reproducing the same path geometry.
class _WaypointPin extends StatelessWidget {
  final bool isDest;
  final String grade;   // 'g' = calm/green, 'a' = fair/amber, 'r' = rough/red
  const _WaypointPin({required this.isDest, this.grade = 'a'});
  @override
  Widget build(BuildContext context) {
    final s = isDest ? 1.0 : 0.82;
    final w = (34 * s).roundToDouble(), h = (46 * s).roundToDouble();
    return SizedBox(width: w, height: h,
      child: CustomPaint(size: Size(w, h),
        painter: _TeardropPinPainter(color: _gradeColors[grade] ?? const Color(0xFFF2A93B))));
  }
}

class _TeardropPinPainter extends CustomPainter {
  final Color color;
  const _TeardropPinPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 34.0;   // viewBox is 0 0 34 46, uniformly scaled to w x h
    canvas.save();
    canvas.scale(scale);
    // ground shadow ellipse
    canvas.drawOval(Rect.fromCenter(center: const Offset(17, 43.5), width: 15, height: 5.2),
      Paint()..color = const Color(0x540F2A44));
    // main teardrop body: M17 45 C7 30 2 22 2 15 A15 15 0 1 1 32 15 C32 22 27 30 17 45 Z
    final body = ui.Path()
      ..moveTo(17, 45)
      ..cubicTo(7, 30, 2, 22, 2, 15)
      ..arcToPoint(const Offset(32, 15), radius: const Radius.circular(15), clockwise: true, largeArc: true)
      ..cubicTo(32, 22, 27, 30, 17, 45)
      ..close();
    canvas.drawPath(body, Paint()..color = color);
    canvas.drawPath(body, Paint()..color = const Color(0x8C0B2744)
      ..style = PaintingStyle.stroke..strokeWidth = 1.4);
    // bottom shading
    final shade = ui.Path()
      ..moveTo(17, 45)
      ..cubicTo(13.5, 39, 10, 33, 7, 27)
      ..cubicTo(11, 30.5, 14, 32, 17, 32)
      ..cubicTo(20, 32, 23, 30.5, 27, 27)
      ..cubicTo(24, 33, 20.5, 39, 17, 45)
      ..close();
    canvas.drawPath(shade, Paint()..color = const Color(0x29000000));
    // highlight ellipse, rotated -24deg around (12,10)
    canvas.save();
    canvas.translate(12, 10);
    canvas.rotate(-24 * math.pi / 180);
    canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: 9.2, height: 12.8),
      Paint()..color = Colors.white.withOpacity(.3));
    canvas.restore();
    // white "eye" circle
    canvas.drawCircle(const Offset(17, 15), 5.6, Paint()..color = Colors.white);
    canvas.restore();
  }
  @override
  bool shouldRepaint(covariant _TeardropPinPainter old) => old.color != color;
}

// Batch B.5 — chart overlay markers
// A map-anchored callout (NOT a bottom sheet): tapping a dock pin opens a small, compact
// (fixed ~240lp wide, content-driven height) glass card positioned immediately above the pin,
// with a matching glass pointer tail. _MapScreenState computes, once per open, whether there's
// room above (else flips below) and how far to nudge horizontally to stay clear of the screen
// edges — see _openDockPopup. The tail always stays centered on the pin itself (not re-centered
// under a shifted card), so it keeps pointing at the true marker per spec. Rendered via a plain
// Stack with clipBehavior: Clip.none inside the Marker's own small box — flutter_map's
// MarkerLayer/MobileLayerTransformer don't clip marker children (confirmed in package source),
// so this paints outside the 28x28 marker box without needing an Overlay/OverflowBox.
// Dock callout layout constants — fixed card width (never stretches edge-to-edge on a wide
// viewport), an estimated height used only for the above/below flip decision at open time
// (see _MapScreenState._openDockPopup), and the on-screen margin/gap kept around it.
const double _dockPopupW = 240, _dockPopupEstH = 150, _dockPopupMargin = 10, _dockPopupGap = 9;

// Test-only entry points — _DockCallout/_GlassTail are private (same single-file-by-design
// pattern as the rest of main.dart), so a widget test in test/ can't reach them directly.
// These just expose the same widgets for a golden-image test; no behavior added.
@visibleForTesting
Widget debugDockCallout({required DockKind kind, required String name, VoidCallback? onRouteHere}) =>
    _DockCallout(kind: kind, name: name, onRouteHere: onRouteHere ?? () {});
@visibleForTesting
Widget debugGlassTail({required bool pointingUp}) => _GlassTail(pointingUp: pointingUp);

// Just the tappable pin icon — the callout itself is shown via Overlay (see
// _MapScreenState._openDockPopup), not rendered inline here. It used to be: the pin's own
// 28x28 Marker box painted the card via Stack(clipBehavior: Clip.none) so it could visually
// overflow that tiny box, which worked for painting but NOT for hit-testing — Flutter checks
// `size.contains(position)` on the ANCESTOR box (flutter_map's own Positioned(28,28) around
// this widget) before it ever recurses into children, so anything painted outside that 28x28
// box was visible but untappable. Moving the callout to a proper Overlay entry (positioned in
// real screen coordinates, with no such box) fixed "Route here" not responding to taps.
class _DockPin extends StatelessWidget {
  final DockKind kind;
  final String name;
  final bool isOpen;
  final void Function(Offset anchorTopLeft, Size anchorSize) onOpen;
  final VoidCallback onClose;
  const _DockPin({
    required this.kind, required this.name, required this.isOpen, required this.onOpen, required this.onClose,
  });
  @override
  Widget build(BuildContext context) {
    final color = kind == DockKind.fuel ? const Color(0xFF1F8A5B)
        : (kind == DockKind.slipway ? const Color(0xFF2E6F9E) : const Color(0xFF6B4FC6));
    final icon = kind == DockKind.fuel ? Icons.local_gas_station
        : (kind == DockKind.slipway ? Icons.directions_boat : Icons.anchor);
    return Tooltip(
      message: name,
      child: InkWell(
        onTap: () {
          if (isOpen) { onClose(); return; }
          final box = context.findRenderObject();
          if (box is RenderBox && box.attached && box.hasSize) {
            onOpen(box.localToGlobal(Offset.zero), box.size);
          } else {
            onOpen(Offset.zero, const Size(28, 28));
          }
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
          ),
          child: Padding(padding: const EdgeInsets.all(3), child: Icon(icon, color: color, size: 16)),
        ),
      ),
    );
  }
}

// The callout's content: icon + name + subtitle + Route-here button, wrapped in the optical
// glass card. Fixed width (never stretches edge-to-edge on a wide viewport), content-driven
// height.
class _DockCallout extends StatelessWidget {
  final DockKind kind;
  final String name;
  final VoidCallback onRouteHere;
  const _DockCallout({required this.kind, required this.name, required this.onRouteHere});
  @override
  Widget build(BuildContext context) {
    final iconWidget = kind == DockKind.fuel
        ? Image.asset('assets/icons/dock_fuel.png', width: 24, height: 24, fit: BoxFit.contain)
        : (kind == DockKind.slipway
            ? Image.asset('assets/icons/dock_ramp.png', width: 24, height: 24, fit: BoxFit.contain)
            : const Icon(Icons.anchor, color: Colors.white, size: 20));
    final subtitle = kind == DockKind.fuel ? 'Fuel dock' : (kind == DockKind.slipway ? 'Boat ramp / slipway' : 'Marina');
    return _OpticalGlassCard(
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child: Padding(padding: const EdgeInsets.fromLTRB(11, 11, 11, 11), child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          _OpticalIconTile(child: iconWidget),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16,
                shadows: [Shadow(color: Color(0x5561A6E3), blurRadius: 10)])),
            Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFA7C2DA), fontWeight: FontWeight.w600, fontSize: 11.5)),
          ])),
        ]),
        const SizedBox(height: 10),
        _OpticalGlassButton(
          onTap: onRouteHere,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(children: [
              const Icon(Icons.navigation_rounded, color: Colors.white, size: 15),
              const SizedBox(width: 7),
              Container(width: 1, height: 14, color: Colors.white.withOpacity(.3)),
              const SizedBox(width: 7),
              const Expanded(child: Text('Route here',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13))),
              Icon(Icons.chevron_right_rounded, color: Colors.white.withOpacity(.85), size: 17),
            ]),
          ),
        ),
      ]),
    ));
  }
}

// ==================================================================================================
// Optical glass — the dock-popup callout's material/lighting recipe. A distinct, more detailed
// technique than the ayecaptain-glass-design SKILL.md recipe used elsewhere (_GlassSurface):
// real backdrop blur of whatever is behind the card (the map), a noticeably transparent 3-stop
// gradient body (not a flat opaque tint), and a CustomPainter for the parts a plain
// Border/BoxShadow can't reproduce — edge brightness that varies by position (a sweep-gradient
// stroke), a second inner rim confined to the top+left edges only, a broad soft diagonal
// reflection confined to the upper-left, and two specular blooms of deliberately unequal
// strength. The pointer tail (_GlassTail) reuses the same blur+gradient+edge-light recipe,
// clipped to a triangle, so the card and tail read as one continuous piece of glass. Built to
// an exact color/opacity spec (not the general glass tokens), so don't fold this into
// _GlassSurface — it's intentionally a different, more detailed surface.
// ==================================================================================================

class _OpticalGlassCard extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  const _OpticalGlassCard({required this.child, required this.borderRadius});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(.22), blurRadius: 18, offset: const Offset(0, 7)),
          const BoxShadow(color: Color(0x1416CFFF), blurRadius: 12),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        // Visual order per spec: map -> background blur -> transparent dark glass ->
        // internal reflection -> content -> thin refractive edge -> specular highlights. Split
        // across two painters (below/above) bracketing `child` in the Stack, so the edge
        // lighting and specular blooms genuinely paint on top of the text/icon content instead
        // of being covered by it.
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Stack(children: [
            // Dark translucent glass body — noticeably transparent (down from the previous
            // ~78-80% alpha to ~50-56%) so the blurred map stays subtly visible through it,
            // not a flat opaque tint.
            const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [Color(0x8F123E56), Color(0x80072638), Color(0x8F041F30)],
                stops: [0, .55, 1],
              ),
            ))),
            Positioned.fill(child: IgnorePointer(
              child: CustomPaint(painter: _OpticalGlassBelowPainter(borderRadius: borderRadius, isCard: true)))),
            child,
            Positioned.fill(child: IgnorePointer(
              child: CustomPaint(painter: _OpticalGlassAbovePainter(borderRadius: borderRadius, isCard: true)))),
          ]),
        ),
      ),
    );
  }
}

// The icon tile — a smaller version of the same optical glass (own gradient body + the same
// painter for its rim/reflection), not a scaled-down copy of the card widget above (no
// backdrop blur needed at this size — nothing meaningful shows through a 38px tile).
class _OpticalIconTile extends StatelessWidget {
  final Widget child;
  const _OpticalIconTile({required this.child});
  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(11));
    return Container(
      width: 38, height: 38,
      decoration: BoxDecoration(borderRadius: radius,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(.28), blurRadius: 6, offset: const Offset(0, 2))]),
      child: ClipRRect(borderRadius: radius, child: Stack(children: [
        const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xD91C66B7), Color(0xD9103C70)]),
        ))),
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _OpticalGlassBelowPainter(borderRadius: radius, isCard: false)))),
        Center(child: child),
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _OpticalGlassAbovePainter(borderRadius: radius, isCard: false)))),
      ])),
    );
  }
}

// Pre-content layers: faint internal illumination, the broad diagonal reflection, and the
// second top+left inner rim. Painted BEHIND the card/tile's content.
class _OpticalGlassBelowPainter extends CustomPainter {
  final BorderRadius borderRadius;
  final bool isCard;
  const _OpticalGlassBelowPainter({required this.borderRadius, required this.isCard});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = borderRadius.toRRect(rect);

    canvas.save();
    canvas.clipRRect(rrect);

    // Faint internal illumination — low cyan glow behind the content, kept subtle so it
    // doesn't fight the card's overall transparency.
    canvas.drawRect(rect, Paint()..shader = ui.Gradient.radial(
      Offset(size.width * .5, size.height * .95), size.width * .8,
      const [Color(0x1416CFFF), Color(0x0016CFFF)],
    ));

    // Broad, soft diagonal mirror reflection confined to the upper-left quadrant — reflected
    // light on curved glass, not a stripe: white at ~12-14% opacity fading through pale cyan
    // to fully transparent, heavily blurred.
    canvas.save();
    canvas.translate(size.width * .04, -size.height * .08);
    canvas.rotate(-0.55);
    final reflectRect = Rect.fromLTWH(-size.width * .15, 0, size.width * .72, size.height * .62);
    canvas.drawRRect(
      RRect.fromRectAndRadius(reflectRect, const Radius.circular(60)),
      Paint()
        ..shader = ui.Gradient.linear(
          reflectRect.topLeft, reflectRect.bottomRight,
          const [Color(0x22FFFFFF), Color(0x0C67E8FF), Color(0x0067E8FF)], const [0, .6, 1],
        )
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, isCard ? 15 : 6),
    );
    canvas.restore();

    // Second, thin rim reflection along only the top and left edges (an inner accent distinct
    // from the perimeter edge-lighting stroke) — brightest at the top-left corner, fading to
    // nothing along both edges, so the border doesn't read as equal brightness.
    final inset = isCard ? 2.5 : 1.5;
    final rimPath = ui.Path()
      ..moveTo(rect.left + inset, rect.top + size.height * .55)
      ..lineTo(rect.left + inset, rect.top + inset + (isCard ? 6 : 3))
      ..arcToPoint(Offset(rect.left + inset + (isCard ? 6 : 3), rect.top + inset),
          radius: Radius.circular(isCard ? 6 : 3))
      ..lineTo(rect.left + size.width * .5, rect.top + inset);
    canvas.drawPath(rimPath, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = isCard ? 1.2 : 0.8
      ..strokeCap = StrokeCap.round
      ..shader = ui.Gradient.linear(
        Offset(rect.left, rect.top + size.height * .5), Offset(rect.left + size.width * .5, rect.top),
        const [Color(0x00E9FBFF), Color(0xB3E9FBFF), Color(0x1A67E8FF)], const [0, .35, 1],
      )
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, isCard ? 1 : .6));
    canvas.restore();   // end clip
  }

  @override
  bool shouldRepaint(covariant _OpticalGlassBelowPainter old) => old.borderRadius != borderRadius || old.isCard != isCard;
}

// Post-content layers: the perimeter edge-lighting stroke and the two specular blooms.
// Painted ON TOP of the card/tile's content, per spec ("...content -> thin refractive edge ->
// tiny specular highlights").
class _OpticalGlassAbovePainter extends CustomPainter {
  final BorderRadius borderRadius;
  final bool isCard;
  const _OpticalGlassAbovePainter({required this.borderRadius, required this.isCard});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = borderRadius.toRRect(rect);

    // Glass edge — a very thin (~1px) border whose brightness varies by position (a sweep
    // gradient stroke, not a flat color): bright white/cyan top-left, faint along the right,
    // a brighter cyan pass along part of the bottom.
    canvas.drawRRect(rrect.deflate(.5), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = isCard ? .9 : .7
      ..shader = ui.Gradient.sweep(
        rect.center,
        const [
          Color(0xE6E9FBFF), Color(0xCC67E8FF), Color(0x5A268CFF),
          Color(0x5A16CFFF), Color(0x40268CFF), Color(0xE6E9FBFF),
        ],
        const [0, .18, .40, .62, .85, 1],
        ui.TileMode.clamp, -math.pi * .72, math.pi * 1.28,
      ));

    // Specular highlights — one tiny bright point near the top-left edge/corner, and one
    // extremely subtle highlight near the opposite (bottom-right) edge. Not symmetric: the
    // second is far more restrained than the first.
    void bloom(Offset at, double r, Color core, double strength) {
      canvas.drawCircle(at, r * 2.2, Paint()..color = core.withOpacity(.07 * strength)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
      canvas.drawCircle(at, r * 1.2, Paint()..color = core.withOpacity(.28 * strength)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5));
      canvas.drawCircle(at, r * .35, Paint()..color = Colors.white.withOpacity(.85 * strength)..maskFilter = const MaskFilter.blur(BlurStyle.normal, .8));
    }
    bloom(Offset(rect.left + (isCard ? 12 : 7), rect.top + (isCard ? 8 : 5)), isCard ? 2.0 : 1.2, const Color(0xFF67E8FF), 1);
    bloom(Offset(rect.right - (isCard ? 14 : 8), rect.bottom - (isCard ? 9 : 6)), isCard ? 1.6 : 1.0, const Color(0xFF16CFFF), .35);
  }

  @override
  bool shouldRepaint(covariant _OpticalGlassAbovePainter old) => old.borderRadius != borderRadius || old.isCard != isCard;
}

// The pointer tail — built from the SAME backdrop blur + gradient body + edge lighting as the
// card (a smaller instance of the same painter/material, clipped to a triangle), so the card
// and its tail read as one continuous piece of glass rather than two different surfaces.
class _GlassTail extends StatelessWidget {
  final bool pointingUp;   // true: callout is below the pin, tail points up into it
  const _GlassTail({required this.pointingUp});
  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: _TailClipper(pointingUp: pointingUp),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Stack(children: [
          const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0x8F123E56), Color(0x8F041F30)]),
          ))),
          Positioned.fill(child: CustomPaint(painter: _TailEdgePainter(pointingUp: pointingUp))),
        ]),
      ),
    );
  }
}

class _TailClipper extends CustomClipper<ui.Path> {
  final bool pointingUp;
  const _TailClipper({required this.pointingUp});
  @override
  ui.Path getClip(Size size) {
    final p = ui.Path();
    if (pointingUp) {
      p.moveTo(size.width / 2, 0);
      p.lineTo(size.width, size.height);
      p.lineTo(0, size.height);
    } else {
      p.moveTo(0, 0);
      p.lineTo(size.width, 0);
      p.lineTo(size.width / 2, size.height);
    }
    p.close();
    return p;
  }

  @override
  bool shouldReclip(covariant _TailClipper old) => old.pointingUp != pointingUp;
}

// Thin cyan/white edge light along the tail's two slanted sides, matching the card's rim.
class _TailEdgePainter extends CustomPainter {
  final bool pointingUp;
  const _TailEdgePainter({required this.pointingUp});
  @override
  void paint(Canvas canvas, Size size) {
    final path = ui.Path();
    if (pointingUp) {
      path.moveTo(0, size.height);
      path.lineTo(size.width / 2, 0);
      path.lineTo(size.width, size.height);
    } else {
      path.moveTo(0, 0);
      path.lineTo(size.width / 2, size.height);
      path.lineTo(size.width, 0);
    }
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8
      ..strokeJoin = StrokeJoin.round
      ..shader = ui.Gradient.linear(
        Offset(size.width * .5, pointingUp ? size.height : 0), Offset(size.width * .5, pointingUp ? 0 : size.height),
        const [Color(0x40E9FBFF), Color(0xB3E9FBFF)],
      ));
  }
  @override
  bool shouldRepaint(covariant _TailEdgePainter old) => old.pointingUp != pointingUp;
}

// Route-here button — "emerald glass" per spec: translucent (not opaque) teal/emerald body,
// its own light backdrop blur, a brighter glass top edge, subtle internal reflection, a thin
// mint rim, and a restrained (not a big) green bloom.
class _OpticalGlassButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const _OpticalGlassButton({required this.child, required this.onTap});
  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(12));
    return Container(
      decoration: BoxDecoration(borderRadius: radius,
        boxShadow: const [BoxShadow(color: Color(0x2620A875), blurRadius: 9)]),
      child: ClipRRect(borderRadius: radius, child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Material(
          color: Colors.transparent,
          child: InkWell(onTap: onTap, child: Stack(children: [
            const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [Color(0xCC20A875), Color(0xCC087B69)]),
            ))),
            Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _OpticalButtonGlassPainter(borderRadius: radius)))),
            child,
          ])),
        ),
      )),
    );
  }
}

class _OpticalButtonGlassPainter extends CustomPainter {
  final BorderRadius borderRadius;
  const _OpticalButtonGlassPainter({required this.borderRadius});
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = borderRadius.toRRect(rect);
    canvas.save();
    canvas.clipRRect(rrect);

    // Brighter glass top edge / subtle internal reflection across the upper portion only —
    // the upper edge catches light like polished glass; the lower portion stays unlit.
    final upper = Rect.fromLTWH(0, 0, size.width, size.height * .5);
    canvas.drawRect(upper, Paint()..shader = ui.Gradient.linear(
      upper.topLeft, upper.bottomLeft,
      const [Color(0x52FFFFFF), Color(0x0EFFFFFF), Color(0x00FFFFFF)], const [0, .5, 1],
    ));
    // Dark lower internal shading.
    final lower = Rect.fromLTWH(0, size.height * .55, size.width, size.height * .45);
    canvas.drawRect(lower, Paint()..shader = ui.Gradient.linear(
      lower.topLeft, lower.bottomLeft, const [Color(0x00000000), Color(0x2E000000)],
    ));
    canvas.restore();

    // ~1px mint/cyan rim.
    canvas.drawRRect(rrect.deflate(.5), Paint()
      ..style = PaintingStyle.stroke..strokeWidth = 1..color = const Color(0x8C9DF2D8));

    // One small, restrained specular highlight near the upper-right edge.
    final at = Offset(size.width * .86, size.height * .18);
    canvas.drawCircle(at, 4, Paint()..color = const Color(0xFF67E8FF).withOpacity(.1)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawCircle(at, 1.8, Paint()..color = Colors.white.withOpacity(.75)..maskFilter = const MaskFilter.blur(BlurStyle.normal, .8));
  }
  @override
  bool shouldRepaint(covariant _OpticalButtonGlassPainter old) => false;
}

class _NavAidPin extends StatelessWidget {
  final String category;   // "red", "green", "amber"
  final String name;
  const _NavAidPin({required this.category, required this.name});
  @override
  Widget build(BuildContext context) {
    final color = category == 'red' ? const Color(0xFFD93A2B)
      : (category == 'green' ? const Color(0xFF1F8A5B) : const Color(0xFFF2A93B));
    return Tooltip(
      message: name,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color,
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 2)])),
        Container(width: 1.5, height: 8, color: color),
      ]),
    );
  }
}

// PWA curIcon() (index.html:818-823): a custom chevron SVG, base 26x26, scaled uniformly by
// clamp(speed/2.2, 0.65, 1.5) — NOT a size-varying icon, a CSS `transform:scale()` on a fixed
// shape. Colour is ALWAYS #2E6F9E (blue) regardless of flood vs ebb — only the arrow's rotation
// (meanFloodDir / meanEbbDir) and the popup text distinguish direction, there's no colour code.
// Flutter's prior version used a generic Material arrow icon and wrongly recoloured ebb purple.
class _TidalCurrentArrow extends StatelessWidget {
  final TidalCurrent sample;
  const _TidalCurrentArrow({required this.sample});
  @override
  Widget build(BuildContext context) {
    final v = sample.velocityKt.abs();
    final slack = v < 0.15;
    if (slack) {
      // PWA slack marker: 11x11 blue circle, 2px white border (index.html:842).
      return Tooltip(message: '${sample.stationName}\nSlack water',
        child: Container(width: 11, height: 11,
          decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF2E6F9E),
            border: Border.all(color: Colors.white, width: 2))));
    }
    final scale = (v / 2.2).clamp(0.65, 1.5).toDouble();
    return Tooltip(
      message: '${sample.stationName}\n${sample.velocityKt >= 0 ? "Flood" : "Ebb"} · ${v.toStringAsFixed(1)} kn',
      child: Transform.rotate(
        angle: sample.directionDeg * math.pi / 180,
        child: Transform.scale(
          scale: scale,
          child: CustomPaint(size: const Size(26, 26), painter: const _CurrentArrowPainter()),
        ),
      ),
    );
  }
}

class _CurrentArrowPainter extends CustomPainter {
  const _CurrentArrowPainter();
  @override
  void paint(Canvas canvas, Size size) {
    // M13 2 L19 17 L13 13 L7 17 Z — index.html:820.
    final path = ui.Path()
      ..moveTo(13, 2)
      ..lineTo(19, 17)
      ..lineTo(13, 13)
      ..lineTo(7, 17)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF2E6F9E));
    canvas.drawPath(path, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.2);
  }
  @override
  bool shouldRepaint(covariant _CurrentArrowPainter old) => false;
}

class _TopHud extends StatelessWidget {
  final double speedKt;
  final String status;
  final double? accuracyM;
  final Basemap base;
  final ValueChanged<Basemap> onBaseChange;
  const _TopHud({required this.speedKt, required this.status, required this.accuracyM, required this.base,
      required this.onBaseChange});
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), boxShadow: [
              BoxShadow(color: const Color(0xFF28AFFF).withOpacity(.38), blurRadius: 18, spreadRadius: 1),
              BoxShadow(color: Colors.black.withOpacity(.24), blurRadius: 12, offset: const Offset(0, 5)),
            ]),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFB7EBFF).withOpacity(.82), width: 1.2),
                    gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [Color(0xB31C507D), Color(0xB309213A)]),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                      Text(speedKt.toStringAsFixed(1), style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700, height: 1)),
                      const SizedBox(width: 4),
                      const Text('kn', style: TextStyle(color: Color(0xFFB7E7FF), fontSize: 12)),
                    ]),
                    const SizedBox(height: 2),
                    Tooltip(message: status, child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xFFD1EEFF), fontSize: 12)),
                    )),
                  ]),
                ),
              ),
            ),
          ),
          // PWA has no separate boat chip in the top HUD — boat identity lives in the sheet
          // header only (index.html speed HUD has just kn + status line).
          const SizedBox(width: 8),
          Expanded(child: Align(alignment: Alignment.centerRight,
            child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight,
              child: _BaseSwitcher(base: base, onChange: onBaseChange)))),
        ]),
      ]);
}

class _BaseSwitcher extends StatelessWidget {
  final Basemap base;
  final ValueChanged<Basemap> onChange;
  const _BaseSwitcher({required this.base, required this.onChange});
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), boxShadow: [
          BoxShadow(color: const Color(0xFF36B9FF).withOpacity(.32), blurRadius: 16),
          BoxShadow(color: Colors.black.withOpacity(.18), blurRadius: 12, offset: const Offset(0, 4)),
        ]),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.white.withOpacity(.78), width: 1.1),
                gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                  colors: [Color(0x995BA7CF), Color(0x6643637C)]),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final b in Basemap.values) _basemapButton(b),
              ]),
            ),
          ),
        ),
      );
  Widget _basemapButton(Basemap b) {
    final selected = b == base;
    return GestureDetector(
      onTap: () => onChange(b),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 1),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xBF082C4D) : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          border: selected ? Border.all(color: const Color(0xFF48D8FF), width: 1.5) : null,
          boxShadow: selected ? [BoxShadow(color: const Color(0xFF21C5FF).withOpacity(.75), blurRadius: 12, spreadRadius: 1)] : null,
        ),
        child: Text(_basemapNames[b]!, style: TextStyle(
          color: selected ? Colors.white : const Color(0xFFE3F5FF), fontWeight: FontWeight.w700, fontSize: 13)),
      ),
    );
  }
}

// Batch A.5: right rail now matches the PWA — Follow / Go-to / Locate / ⋯ More-tools / MOB.
// The four ad-hoc singleton buttons for fuel/anchor/forecast/smart moved into `_MoreToolsSheet`.
class _RightRail extends StatelessWidget {
  final bool follow, picking, gpsOn, mobOn;
  final VoidCallback onFollow, onGoto, onLocate, onMob, onMoreTools, onBoatProfile;
  const _RightRail({required this.follow, required this.picking, required this.gpsOn, required this.mobOn,
    required this.onFollow, required this.onGoto, required this.onLocate, required this.onMob,
    required this.onMoreTools, required this.onBoatProfile});
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        // Was the "Edit" text link inside the weather sheet header — moved here (its own
        // glass icon button, like the map tools below it) per ayecaptain-glass-design
        // SKILL.md. Green-tinted so it reads as a different category of action from the
        // blue map-view tools and the red MOB button.
        _btn(icon: Icons.sailing, active: false, onTap: onBoatProfile, tip: 'Boat profile',
          accentColor: const Color(0xFF6FE8BC)),
        const SizedBox(height: 8),
        _btn(icon: Icons.navigation, active: follow, onTap: onFollow, tip: 'Follow my boat'),
        const SizedBox(height: 8),
        _btn(icon: Icons.add_location_alt, active: picking, onTap: onGoto, tip: 'Go to a point'),
        const SizedBox(height: 8),
        _btn(icon: gpsOn ? Icons.my_location : Icons.location_searching, active: gpsOn, onTap: onLocate, tip: 'Track my location'),
        const SizedBox(height: 8),
        _btn(icon: Icons.more_horiz, active: false, onTap: onMoreTools, tip: 'More tools'),
        const SizedBox(height: 8),
        _mobButton(),
      ]);
  // Was PWA-parity "default WHITE 44px circle" — deliberately departed from that here,
  // same category as the 3D nav view / route-bar glass: a Flutter-side enhancement toward
  // the reference design (.claude/skills/ayecaptain-glass-design/SKILL.md), not a PWA port.
  // Active state keeps a filled accent disc behind the icon (the glass ring alone reads too
  // subtly as "on" at 46px) rather than swapping the whole button to solid navy like before.
  Widget _btn({required IconData icon, required bool active, required VoidCallback onTap, required String tip,
      Color? accentColor}) {
    return SizedBox(
      width: 46, height: 46,
      child: _GlassSurface(
        severity: GlassSeverity.nav, circular: true,
        child: Material(
          color: active ? const Color(0xFF2E6F9E).withOpacity(.55) : Colors.transparent,
          shape: const CircleBorder(),
          child: Tooltip(
            message: tip,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Icon(icon, color: active ? Colors.white : (accentColor ?? const Color(0xFFB7E7FF))),
            ),
          ),
        ),
      ),
    );
  }
  // Solid fill kept (not frosted glass) — an emergency control should read as maximally
  // visible/urgent, not translucent. Adds the subtle red bloom called for in the approved
  // design (artifacts 55091e25.../b83ec157...) via a plain BoxShadow, nothing else changed.
  Widget _mobButton() => Container(
        decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [
          BoxShadow(color: (mobOn ? const Color(0xFF8B0000) : const Color(0xFFD93A2B)).withOpacity(.55),
            blurRadius: 14, spreadRadius: 1),
        ]),
        child: Material(
          color: mobOn ? const Color(0xFF8B0000) : const Color(0xFFD93A2B),
          shape: const CircleBorder(),
          elevation: 4,
          child: Tooltip(
            message: mobOn ? 'MOB active — tap to clear' : 'Man overboard',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onMob,
              child: const SizedBox(width: 50, height: 50, child: Icon(Icons.accessibility_new, color: Colors.white)),
            ),
          ),
        ),
      );
}

// Batch A.5: bottom-sheet popover with 5 toggles — matches the PWA's More tools sheet.
// Anchor / Fuel / Smart routes are the real toggles wired to state. Docks & fuel and Nav aids
// are stubs until Batch B.5 lands the overlays.
class MoreToolsSheet extends StatelessWidget {
  final bool docksOn, navAidsOn, anchorOn, fuelOn, smartOn;
  final ValueChanged<bool> onToggleDocks, onToggleNavAids, onToggleAnchor, onToggleFuel, onToggleSmart;
  final VoidCallback onOpenForecast;
  // Overrides the default subtitle while loading/failed — matches the PWA's
  // "Loading nearby docks…" / "Couldn't reach dock data — tap to retry" (index.html:1662,1683).
  final String? docksSub, navAidsSub;
  final bool docksError, navAidsError;
  final VoidCallback? onRetryDocks, onRetryNavAids;
  const MoreToolsSheet({super.key,
    required this.docksOn, required this.navAidsOn, required this.anchorOn, required this.fuelOn, required this.smartOn,
    required this.onToggleDocks, required this.onToggleNavAids, required this.onToggleAnchor, required this.onToggleFuel, required this.onToggleSmart,
    required this.onOpenForecast,
    this.docksSub, this.navAidsSub, this.docksError = false, this.navAidsError = false,
    this.onRetryDocks, this.onRetryNavAids});
  @override
  Widget build(BuildContext context) {
    return SafeArea(child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4,
          decoration: BoxDecoration(color: const Color(0xFFDDE4EA), borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 12),
        const Padding(padding: EdgeInsets.only(left: 4, bottom: 4),
          child: Text('More tools', style: TextStyle(color: Color(0xFF0F2A44), fontWeight: FontWeight.w800, fontSize: 18))),
        _row(Icons.anchor, 'Docks & fuel', docksSub ?? 'Marinas, ramps & fuel docks nearby (20 mi)',
          docksOn, onToggleDocks, subError: docksError, onSubTap: docksError ? onRetryDocks : null),
        _row(Icons.center_focus_strong, 'Anchor watch', 'Alarm if you drift off the hook', anchorOn, onToggleAnchor),
        _row(Icons.local_gas_station, 'Fuel range', 'Half-range ring from your tank & burn rate', fuelOn, onToggleFuel),
        _row(Icons.location_on, 'Nav aids', navAidsSub ?? 'Channel buoys & beacons nearby (20 mi)',
          navAidsOn, onToggleNavAids, subError: navAidsError, onSubTap: navAidsError ? onRetryNavAids : null),
        _row(Icons.route, 'Smart routes', 'Bend routes around land (experimental)', smartOn, onToggleSmart),
        const Divider(color: Color(0xFFDDE4EA), height: 24),
        Material(color: const Color(0xFFF4F8FA), borderRadius: BorderRadius.circular(10),
            child: InkWell(borderRadius: BorderRadius.circular(10), onTap: onOpenForecast,
              child: const Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(children: [
                  Icon(Icons.cloud_outlined, color: Color(0xFF2E6F9E)),
                  SizedBox(width: 8),
                  Text('7-day forecast', style: TextStyle(color: Color(0xFF0F2A44), fontWeight: FontWeight.w800, fontSize: 14)),
                ])))),
      ]),
    ));
  }
  Widget _row(IconData icon, String title, String sub, bool on, ValueChanged<bool> onTap,
      {bool subError = false, VoidCallback? onSubTap}) {
    final subWidget = Text(sub, style: TextStyle(
      color: subError ? const Color(0xFFD93A2B) : const Color(0xFF708597),
      fontWeight: subError ? FontWeight.w700 : FontWeight.normal, fontSize: 12));
    return Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(children: [
      Container(width: 42, height: 42,
        decoration: BoxDecoration(color: const Color(0xFFF0F5F9), shape: BoxShape.circle),
        child: Icon(icon, color: const Color(0xFF2E6F9E))),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Color(0xFF0F2A44), fontWeight: FontWeight.w800, fontSize: 15)),
        onSubTap != null
          ? InkWell(onTap: onSubTap, child: subWidget)
          : subWidget,
      ])),
      Switch(value: on, onChanged: onTap, activeColor: const Color(0xFF2E6F9E)),
    ]));
  }
}

// Modal sheet for editing the boat profile — name/type/length + wind/gust/wave limits + fuel.
// Type dropdown offers "Use defaults" that snap limits/cruise to the type presets.
class BoatProfileSheet extends StatefulWidget {
  final BoatProfile initial;
  final Future<void> Function(BoatProfile) onSave;
  const BoatProfileSheet({super.key, required this.initial, required this.onSave});
  @override
  State<BoatProfileSheet> createState() => _BoatProfileSheetState();
}
class _BoatProfileSheetState extends State<BoatProfileSheet> {
  late BoatProfile p;
  @override
  void initState() {
    super.initState();
    p = BoatProfile.fromJson(widget.initial.toJson());
  }
  TextEditingController _num(double v) => TextEditingController(text: v == 0 ? '' : v.toString());
  // PWA #pform input (index.html:182): white bg, ink text, light navy border; labels are
  // var(--sea) (index.html:181). Was wrongly white-on-dark.
  Widget _field(String label, double value, ValueChanged<double> onChange, {String suffix = ''}) => TextField(
    controller: _num(value),
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    style: const TextStyle(color: Color(0xFF0F2A44)),
    decoration: InputDecoration(
      filled: true, fillColor: Colors.white,
      labelText: label, labelStyle: const TextStyle(color: Color(0xFF2E6F9E), fontSize: 12, fontWeight: FontWeight.w700),
      suffixText: suffix, suffixStyle: const TextStyle(color: Color(0xAA0F2A44)),
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0x400F2A44))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0x400F2A44))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF2E6F9E), width: 2)),
    ),
    onChanged: (s) { final d = double.tryParse(s); if (d != null) onChange(d); },
  );
  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    initialChildSize: 0.75, minChildSize: 0.4, maxChildSize: 0.95, expand: false,
    builder: (ctx, scroll) => Container(
      // PWA #pform (index.html:178): background:var(--paper) #F4F8FA — was wrongly dark navy.
      decoration: const BoxDecoration(color: Color(0xFFF4F8FA), borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: ListView(controller: scroll, children: [
        Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(color: const Color(0x470F2A44), borderRadius: BorderRadius.circular(2)))),
        const Text('Your boat', style: TextStyle(color: Color(0xFF0F2A44), fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text('Bayside grades forecasts against these limits and computes fuel from tank & burn rate.',
            style: TextStyle(color: const Color(0xFF0F2A44).withOpacity(.75), fontSize: 12)),
        const SizedBox(height: 16),
        TextField(
          controller: TextEditingController(text: p.name),
          style: const TextStyle(color: Color(0xFF0F2A44)),
          decoration: InputDecoration(
            filled: true, fillColor: Colors.white,
            labelText: 'Boat name', labelStyle: const TextStyle(color: Color(0xFF2E6F9E), fontSize: 12, fontWeight: FontWeight.w700),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0x400F2A44))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0x400F2A44))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF2E6F9E), width: 2)),
          ),
          onChanged: (s) => p.name = s,
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _field('Length (ft)', p.lengthFt ?? 0, (v) => setState(() => p.lengthFt = v > 0 ? v : null), suffix: 'ft')),
          const SizedBox(width: 12),
          Expanded(child: DropdownButtonFormField<BoatType>(
            value: p.type,
            dropdownColor: Colors.white,
            style: const TextStyle(color: Color(0xFF0F2A44)),
            decoration: InputDecoration(
              filled: true, fillColor: Colors.white,
              labelText: 'Type', labelStyle: const TextStyle(color: Color(0xFF2E6F9E), fontSize: 12, fontWeight: FontWeight.w700),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0x400F2A44))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0x400F2A44))),
            ),
            items: BoatType.values.map((t) => DropdownMenuItem(value: t, child: Text(_typeNames[t]!))).toList(),
            onChanged: (v) { if (v != null) setState(() => p.type = v); },
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          // PWA pairs Cruise + Draft on one row (index.html:424-425).
          Expanded(child: _field('Cruise (kn)', p.cruise, (v) => setState(() => p.cruise = v), suffix: 'kn')),
          const SizedBox(width: 12),
          Expanded(child: _field('Draft (ft)', p.draftFt ?? 0,
            (v) => setState(() => p.draftFt = v > 0 ? v : null), suffix: 'ft')),
        ]),
        const SizedBox(height: 12),
        Material(color: const Color(0xFF2E6F9E), borderRadius: BorderRadius.circular(8),
          child: InkWell(borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => p.applyTypeDefaults(p.type)),
            child: const Padding(padding: EdgeInsets.symmetric(vertical: 14),
              child: Center(child: Text('Use defaults for type', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)))),
          ),
        ),
        const SizedBox(height: 20),
        Text('Comfort limits — Bayside warns when forecasts exceed these',
            style: TextStyle(color: const Color(0xFF0F2A44).withOpacity(.75), fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _field('Max wind', p.wind, (v) => setState(() => p.wind = v), suffix: 'kn')),
          const SizedBox(width: 12),
          Expanded(child: _field('Max gust', p.gust, (v) => setState(() => p.gust = v), suffix: 'kn')),
          const SizedBox(width: 12),
          Expanded(child: _field('Max wave', p.wave, (v) => setState(() => p.wave = v), suffix: 'ft')),
        ]),
        const SizedBox(height: 20),
        Text('Fuel — for the range ring & route fuel estimate',
            style: TextStyle(color: const Color(0xFF0F2A44).withOpacity(.75), fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _field('Burn @ cruise', p.burn, (v) => setState(() => p.burn = v), suffix: 'gal/h')),
          const SizedBox(width: 12),
          Expanded(child: _field('Tank size', p.tank, (v) => setState(() => p.tank = v), suffix: 'gal')),
        ]),
        const SizedBox(height: 24),
        // PWA #pform .save (index.html:184): background:var(--ink), colour:var(--paper) —
        // dark navy, not green.
        Material(color: const Color(0xFF0F2A44), borderRadius: BorderRadius.circular(10),
          child: InkWell(borderRadius: BorderRadius.circular(10),
            onTap: () async {
              await widget.onSave(p);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Padding(padding: EdgeInsets.symmetric(vertical: 14),
              child: Center(child: Text('Save', style: TextStyle(color: Color(0xFFF4F8FA), fontWeight: FontWeight.w800, fontSize: 15)))),
          ),
        ),
        const SizedBox(height: 12),
      ]),
    ),
  );
}

// One bottom-sheet region whose content is driven by app state, not three independent
// widgets (formerly _RouteBar here + _NavBar/_MobHud floating separately in the top HUD)
// — see .claude/skills/ayecaptain-glass-design/SKILL.md §2. Exactly one mode shows at a
// time; MOB takes priority over navigating, which takes priority over plain planning.
//
// This absorbs the PWA's separate #routebar (index.html:66-74,316-321), #nav bar, and MOB
// chip into one region — a deliberate Flutter-side structural departure from the PWA
// (which keeps all three as independent DOM elements), not a port of PWA structure.
enum _NavMode { planning, navigating, mob }

class _NavShell extends StatelessWidget {
  final _NavMode mode;
  // Caller passes `_me ?? _homeCenter` (same no-GPS fallback _toggleMob already uses) —
  // navigating/MOB mode must render immediately on tap regardless of GPS, same as the old
  // _RouteBar's Start/Stop button never depended on _me. Only the distance/bearing shown
  // end up relative to home-center instead of a real fix when GPS isn't available yet.
  final LatLng me;

  // planning
  final int waypointCount;
  final double routeNm, fuelGal;
  final int etaMin;
  final bool picking, unverified;
  final VoidCallback onStart, onUndoRoute, onGpx, onClearRoute;

  // navigating — leg-specific distance/bearing computed from me/navTarget below; etaMin
  // and fuelGal above are reused as-is (the same whole-remaining-route figures the old
  // _NavBar took, not re-derived).
  final LatLng? navTarget;
  final int legIdx, totalWps;
  final double speedKt;
  final VoidCallback onEndRoute;

  // mob
  final LatLng? mobPoint;
  final VoidCallback onStopGuidance;

  const _NavShell({
    required this.mode, required this.me,
    required this.waypointCount, required this.routeNm, required this.etaMin, required this.fuelGal,
    required this.picking, required this.unverified,
    required this.onStart, required this.onUndoRoute, required this.onGpx, required this.onClearRoute,
    required this.navTarget, required this.legIdx, required this.totalWps, required this.speedKt,
    required this.onEndRoute,
    required this.mobPoint, required this.onStopGuidance,
  });

  bool get _hasRoute => waypointCount > 0;

  @override
  Widget build(BuildContext context) {
    // index.html:1414 equivalent — planning mode only shows while picking or once a
    // route exists; navigating/mob modes are only ever entered with real state backing
    // them (guarded by the caller), so they always render.
    if (mode == _NavMode.planning && !picking && !_hasRoute) return const SizedBox.shrink();
    return _GlassSurface(
      severity: mode == _NavMode.mob ? GlassSeverity.mob : GlassSeverity.nav,
      borderRadius: 14,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: switch (mode) {
          _NavMode.planning => _planningContent(),
          _NavMode.navigating => _navigatingContent(),
          _NavMode.mob => _mobContent(),
        },
      ),
    );
  }

  // ---- planning: same content/behavior the old _RouteBar always showed, minus the
  // Stop-button variant — navigating now has its own mode, so this is always "Start". ----
  Widget _planningContent() {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 14, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _stat(_hasRoute ? '$waypointCount' : '0', _hasRoute ? 'point${waypointCount > 1 ? 's' : ''}' : 'points'),
        _hasRoute ? _etaStat() : _stat('tap map', 'to add'),
      ]),
      const SizedBox(height: 9),
      Row(children: [
        Expanded(flex: 2, child: _bigBtn('Start', onStart)),
        const SizedBox(width: 6),
        Expanded(child: _smallBtn('Undo', onUndoRoute)),
        const SizedBox(width: 6),
        Expanded(child: _smallBtn('GPX', onGpx)),
        const SizedBox(width: 6),
        Expanded(child: _smallBtn('Clear', onClearRoute)),
      ]),
    ]);
  }

  // index.html:1480-1486 — nm bold, then "{mins} · arrive {time}{gal}" light, plus an
  // optional ⚠ when any remaining leg couldn't be routed around land.
  Widget _etaStat() {
    final eta = etaMin >= 60 ? '${etaMin ~/ 60}h ${etaMin % 60}m' : '${math.max(1, etaMin)} min';
    final arrive = _fmtTime(DateTime.now().add(Duration(minutes: etaMin)));
    final gal = fuelGal > 0
      ? ' · ~${fuelGal < 10 ? fuelGal.toStringAsFixed(1) : fuelGal.round()} gal'
      : '';
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _stat('${routeNm.toStringAsFixed(1)} nm', '$eta · arrive $arrive$gal'),
      if (unverified) const Padding(padding: EdgeInsets.only(left: 2),
        child: Text('⚠', style: TextStyle(color: Color(0xFFF2A93B), fontSize: 15))),
    ]);
  }

  // ---- navigating: was _NavBar (top HUD) — identical distance/bearing math, "Done"
  // renamed "End Route" per the approved sheet-architecture design. Distance/bearing are
  // leg-specific (to the current target); ETA/fuel stay whole-remaining-route figures. ----
  Widget _navigatingContent() {
    final from = me, target = navTarget!;
    final brg = _bearingDeg(from, target);
    final dm = _haversineM(from, target);
    final distStr = dm < 370 ? '${(dm * 3.28).round()} ft' : '${(dm / 1852).toStringAsFixed(dm / 1852 < 10 ? 2 : 1)} nm';
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('⚑', style: TextStyle(fontSize: 16)),
        const SizedBox(width: 7),
        Expanded(child: Text('Waypoint ${legIdx + 1} of $totalWps', maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15))),
        _smallBtn('End Route', onEndRoute),
      ]),
      _glassDivider(),
      Row(children: [
        _metric(distStr, 'DISTANCE'),
        _metric(etaMin >= 60 ? '${etaMin ~/ 60}h ${etaMin % 60}m' : '${math.max(1, etaMin)} min', 'ETA'),
        _metric('${brg.round().toString().padLeft(3, '0')}°', 'BEARING'),
        _metric('${speedKt.toStringAsFixed(1)} kn', 'SOG'),
      ]),
      if (fuelGal > 0) ...[
        _glassDivider(),
        Text('~${fuelGal < 10 ? fuelGal.toStringAsFixed(1) : fuelGal.round()} gal to finish',
          style: const TextStyle(color: Color(0xFFD7ECFF), fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    ]);
  }

  // ---- mob: was _MobHud (top HUD) — identical distance/bearing math, "Clear MOB"
  // renamed "Stop Guidance". ETA/SOG are new here: both were already fully computable
  // from existing real data (distance + live speed), just not previously surfaced. ----
  Widget _mobContent() {
    final from = me, to = mobPoint!;
    final d = _haversineM(from, to);
    final b = _bearingDeg(from, to);
    final dist = d < 370 ? '${(d * 3.28).round()} ft' : '${(d / 1852).toStringAsFixed(d / 1852 < 10 ? 2 : 1)} nm';
    final etaStr = speedKt > 0 ? '${math.max(1, (d / 1852 / speedKt * 60).round())} min' : '—';
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('🛟', style: TextStyle(fontSize: 16)),
        const SizedBox(width: 7),
        const Expanded(child: Text('Man Overboard', maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15))),
        _smallBtn('Stop Guidance', onStopGuidance),
      ]),
      _glassDivider(),
      Row(children: [
        _metric(dist, 'DISTANCE'),
        _metric(etaStr, 'ETA'),
        _metric('${b.round().toString().padLeft(3, '0')}°', 'BEARING'),
        _metric('${speedKt.toStringAsFixed(1)} kn', 'SOG'),
      ]),
    ]);
  }

  Widget _glassDivider() => Container(
    height: 1, margin: const EdgeInsets.symmetric(vertical: 9),
    color: Colors.white.withOpacity(.10),
  );

  Widget _metric(String value, String label) => Expanded(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
      Text(label, style: TextStyle(
        color: mode == _NavMode.mob ? const Color(0xFFD98A96) : const Color(0xFF8FB6D6),
        fontSize: 9.5, letterSpacing: .4)),
    ],
  ));

  Widget _stat(String bold, String light) => Text.rich(TextSpan(children: [
    TextSpan(text: bold, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
    TextSpan(text: ' $light', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500, height: 1.6)),
  ]), maxLines: 1, overflow: TextOverflow.ellipsis);

  Widget _bigBtn(String label, VoidCallback onTap) => Material(
        color: const Color(0xFF1F8A5B), borderRadius: BorderRadius.circular(9),
        child: InkWell(borderRadius: BorderRadius.circular(9), onTap: onTap,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Center(child:
              Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13))),
          ),
        ),
      );
  Widget _smallBtn(String label, VoidCallback onTap) => Material(
        color: const Color(0x24FFFFFF), borderRadius: BorderRadius.circular(9),
        child: InkWell(borderRadius: BorderRadius.circular(9), onTap: onTap,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Text(label, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
          ),
        ),
      );
}

// Batch A.5: rewrite as a stateful sheet that hosts the "Set up your boat" content
// (weather block + best-window pill + day tabs + hourly "Best time to boat" table).
// The route/nav/MOB summary lives separately in _NavShell — this sheet stays the PWA-
// exact light card (index.html:79); _NavShell is the deliberately-glassed, state-driven
// region above it.
class _BottomSheet extends StatefulWidget {
  final Weather? weather;
  final TideStation? tideStation;
  final List<TidePoint> tides;
  final String tideUnit;
  final ValueChanged<String> onTideUnitChanged;
  final BestWindow? window;
  final List<HourlyPoint> hourly;
  final List<DailyForecast> daily;
  final BoatProfile profile;
  final bool expanded;
  final ValueChanged<bool> onExpandedChanged;
  final bool showInstallPrompt;
  final VoidCallback onInstall;
  const _BottomSheet({required this.weather,
    required this.window, required this.hourly, required this.daily,
    required this.tideStation, required this.tides, required this.tideUnit,
    required this.onTideUnitChanged,
    required this.profile, required this.expanded, required this.onExpandedChanged,
    required this.showInstallPrompt, required this.onInstall});
  @override
  State<_BottomSheet> createState() => _BottomSheetState();
}

class _BottomSheetState extends State<_BottomSheet> {
  int _dayIdx = 0;             // 0 = today, 1..6 = following days
  double _dragDy = 0;          // accumulated vertical drag for swipe-to-toggle
  bool get _expanded => widget.expanded;
  void _setExpanded(bool v) => widget.onExpandedChanged(v);
  // Fixed chrome shown above the scrollable content: grab handle + boat header. Extracted so
  // it can go either above a separate scroll view (expanded) or stand alone at its natural
  // compact size (collapsed).
  // "Edit" used to live here as a text link (PWA #boatline, index.html:185-186) — moved to a
  // dedicated boat-profile icon on the right rail instead (ayecaptain-glass-design SKILL.md);
  // this header is now just the summary line + expand/collapse chevron.
  Widget _fixedChrome() => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
    // Grab handle — was PWA-exact dark-on-light (#grab, index.html:81-82); now light-on-glass
    // to match the sheet's new dark background.
    Center(child: InkWell(
      onTap: () => _setExpanded(!_expanded),
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(width: 60, height: 24, child: Center(
        child: Container(width: 40, height: 5,
          decoration: BoxDecoration(color: Colors.white.withOpacity(.30),
            borderRadius: BorderRadius.circular(3))),
      )),
    )),
    InkWell(
      onTap: () => _setExpanded(!_expanded),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          Icon(_expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up, color: const Color(0xFFB7E7FF), size: 20),
          const SizedBox(width: 6),
          Expanded(child: Text(_headerText(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15))),
        ]),
      ),
    ),
    // Not duplicated here — the boat-warning banner already shows in the top HUD
    // (_MapScreenState.build(), above the rail). PWA only shows it once too (index.html:327,
    // inside #sheet) but the user explicitly wants the HUD copy kept and this one dropped.
  ]);

  @override
  Widget build(BuildContext context) {
    // User feedback: 86vh (the PWA's own number) still opened nearly full-screen once the
    // fixed chrome above it (grab handle/route row/header/warning) was added on top — that
    // extra height was never subtracted from the cap. Target ~half the screen instead, and
    // cap the WHOLE sheet (chrome included) in one ConstrainedBox+SingleChildScrollView so
    // the total height can never exceed it regardless of how tall the fixed rows get.
    final sheetMaxH = MediaQuery.sizeOf(context).height * 0.5;
    return GestureDetector(
      // PWA index.html:1974 swipe handler — dy<-40 opens, dy>40 closes.
      onVerticalDragStart: (_) => _dragDy = 0,
      onVerticalDragUpdate: (d) => _dragDy += d.delta.dy,
      onVerticalDragEnd: (_) {
        if (_dragDy < -40 && !_expanded) _setExpanded(true);
        else if (_dragDy > 40 && _expanded) _setExpanded(false);
        _dragDy = 0;
      },
      // Was PWA-exact light sky-to-sand gradient (#sheet, index.html:79) — deliberately
      // departed from that here, same glass recipe as _NavShell/the rail buttons
      // (ayecaptain-glass-design SKILL.md), not a PWA port.
      child: _GlassSurface(
        severity: GlassSeverity.nav, borderRadius: 14,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
              ? ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: sheetMaxH),
                  child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _fixedChrome(),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
                        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
                          children: _expandedBody()),
                      ),
                    ]),
                  ),
                )
              : _fixedChrome(),
          ),
        ),
      ),
    );
  }

  String _headerText() {
    final p = widget.profile;
    if (p.name.isEmpty && p.lengthFt == null) return 'Set up your boat';
    final bits = <String>[];
    if (p.name.isNotEmpty) bits.add(p.name);
    if (p.lengthFt != null) bits.add('${p.lengthFt!.round()} ft');
    bits.add('limits ${p.wind.round()} kn · ${p.wave.toStringAsFixed(1)} ft');
    return bits.join(' · ');
  }

  List<Widget> _expandedBody() {
    final w = widget.weather;
    return [
      const SizedBox(height: 6),
      if (w != null) _weatherBlock(w),
      if (widget.window != null) ...[
        const SizedBox(height: 8),
        BestWindowPill(win: widget.window!),
      ],
      const SizedBox(height: 10),
      DayTabs(daily: widget.daily, selected: _dayIdx, onSelect: (i) => setState(() => _dayIdx = i)),
      const SizedBox(height: 8),
      const Text('Best time to boat', style: TextStyle(color: Colors.white,
        fontWeight: FontWeight.w800, fontSize: 13, letterSpacing: 0.3)),
      const SizedBox(height: 4),
      HourlyTable(hourly: widget.hourly, dayIdx: _dayIdx, profile: widget.profile),
      const SizedBox(height: 16),
      TidesSheet(
        station: widget.tideStation, tides: widget.tides,
        sunrise: widget.weather?.sunrise, sunset: widget.weather?.sunset,
        tomorrowSunrise: widget.weather?.tomorrowSunrise,
        tomorrowSunset: widget.weather?.tomorrowSunset,
        initialUnit: widget.tideUnit, onUnitChanged: widget.onTideUnitChanged,
      ),
      // PWA #install (index.html:157-158,378,1976-1978): hidden until beforeinstallprompt
      // fires, dark-navy full-width button, near the bottom of the expanded sheet.
      if (widget.showInstallPrompt) ...[
        const SizedBox(height: 14),
        SizedBox(width: double.infinity, child: Material(
          color: const Color(0xFF0F2A44), borderRadius: BorderRadius.circular(12),
          child: InkWell(borderRadius: BorderRadius.circular(12), onTap: widget.onInstall,
            child: const Padding(padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: Text('Add Bayside to home screen',
                style: TextStyle(color: Color(0xFFF4F8FA), fontWeight: FontWeight.w700, fontSize: 16))),
            ),
          ),
        )),
      ],
    ];
  }

  Widget _weatherBlock(Weather w) {
    final theme = Theme.of(context);
    final isNight = w.sunset != null && DateTime.now().isAfter(w.sunset!);
    final tiles = <Widget>[
      MetricTile(icon: 'assets/icons/wx_wind.png',
        label: 'Wind', value: '${w.windKt?.round() ?? '—'} kn ${_dirName(w.windDirDeg?.toDouble() ?? 0)}'),
      MetricTile(icon: 'assets/icons/wx_gust.png',
        label: 'Gust', value: '${w.gustKt?.round() ?? '—'} kn'),
      if (w.sunset != null) MetricTile(icon: 'assets/icons/wx_sunset.png',
        label: 'Sunset', value: _fmtTime(w.sunset!)),
      if (w.waterTempF != null) MetricTile(icon: 'assets/icons/wx_water.png',
        label: 'Water', value: '${w.waterTempF!.round()}°F'),
      if (w.waveFt != null) MetricTile(icon: 'assets/icons/wx_wave.png',
        label: 'Wave', value: '${w.waveFt!.toStringAsFixed(1)} ft'),
      if (w.wavePeriodS != null) MetricTile(icon: 'assets/icons/wx_period.png',
        label: 'Period', value: '${w.wavePeriodS!.round()} s'),
      if (w.precipPct != null && w.precipPct! > 0) MetricTile(icon: null,
        label: 'Rain', value: '${w.precipPct!.round()}%'),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // PWA: temp 42 pt weight-700 + condition small top-right (index.html #wxhead).
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _wxIconWidget(w.weatherCode, size: 42, isNight: isNight),
        const SizedBox(width: AppSpacing.sm),
        Baseline(baseline: 42, baselineType: TextBaseline.alphabetic,
          child: Text('${w.tempF?.round() ?? '—'}°',
            style: const TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.w800, height: 1))),
        const SizedBox(width: 2),
        const Baseline(baseline: 42, baselineType: TextBaseline.alphabetic,
          child: Text('F', style: TextStyle(color: Color(0xFFB7E7FF), fontSize: 15, fontWeight: FontWeight.w700))),
        const Spacer(),
        Padding(padding: const EdgeInsets.only(top: 2),
          child: Text(_condText(w.weatherCode), style: theme.textTheme.titleSmall)),
      ]),
      const SizedBox(height: AppSpacing.md),
      MetricsGrid(tiles: tiles),
    ]);
  }

}

// One label+value metric cell (Wind/Gust/Sunset/Water/Wave/Period/Rain) with its icon — the
// reusable unit MetricsGrid below lays out responsively. Was a bare Column with no icon, a
// 10px label and 14px value packed into a plain Wrap with no per-row alignment — crowded, and
// "Period" fell alone onto its own trailing line whenever the row count didn't divide evenly.
class MetricTile extends StatelessWidget {
  final String? icon;   // asset path, or null for a plain Material-icon fallback (Rain — no
                         // user-supplied asset for it)
  final String label;
  final String value;
  const MetricTile({super.key, required this.icon, required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Was Row[icon, gap, Expanded(Column[label, value])] — icon+gap (32px) came out of the
    // SAME narrow width budget as both label and value, since Expanded wrapped them together.
    // In a 3-column grid on a 320px sheet that left the value well under 70px, not enough for
    // "6:33 PM" at the unchanged 16px/w700 bodyLarge style, which wrapped to "6:33"/"PM".
    // Unchanged fonts/weights/colors/icon size/spacing — only the icon now shares a row with
    // the (short) label instead of sitting beside the (longer) value, so the value gets the
    // tile's FULL width instead of width-minus-icon. maxLines:1/softWrap:false make the "never
    // wrap" requirement structural, not just a hope that it now fits.
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        icon != null
          ? Image.asset(icon!, width: 24, height: 24, fit: BoxFit.contain)
          : const Icon(Icons.water_drop_rounded, color: Color(0xFF6FC6FF), size: 22),
        const SizedBox(width: AppSpacing.sm),
        Flexible(child: Text(label, style: theme.textTheme.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]),
      const SizedBox(height: 2),
      Text(value, style: theme.textTheme.bodyLarge, maxLines: 1, softWrap: false, overflow: TextOverflow.visible),
    ]);
  }
}

// Measures the real available width (LayoutBuilder, not device width) and picks a column count
// — 3 on a typical sheet width, 2 once it's genuinely narrow — rather than letting Wrap's
// natural flow decide where each row breaks, which is what orphaned "Period" onto its own line
// whenever the preceding count wasn't a clean multiple. Fixed per-item width inside Wrap keeps
// items falling into true aligned rows/columns with a consistent gap, while still letting each
// tile grow taller on its own if a label/value ever needs to wrap under text scaling.
class MetricsGrid extends StatelessWidget {
  final List<Widget> tiles;
  const MetricsGrid({super.key, required this.tiles});
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth < 280 ? 2 : 3;
      const gap = AppSpacing.md;
      final itemWidth = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(spacing: gap, runSpacing: gap,
        children: [for (final t in tiles) SizedBox(width: itemWidth, child: t)]);
    });
  }
}

String _condText(int? code) {
  if (code == null) return '';
  if (code == 0) return 'Clear';
  if (code <= 2) return 'Mostly clear';
  if (code == 3) return 'Cloudy';
  if (code == 45 || code == 48) return 'Foggy';
  if (code <= 57) return 'Drizzle';
  if (code <= 67) return 'Rainy';
  if (code <= 77) return 'Snow';
  if (code <= 82) return 'Showers';
  return 'Thunder';
}

String _fmtTime(DateTime t) {
  final l = t.toLocal();
  final h = l.hour == 0 ? 12 : (l.hour > 12 ? l.hour - 12 : l.hour);
  final m = l.minute.toString().padLeft(2, '0');
  final ampm = l.hour >= 12 ? 'PM' : 'AM';
  return '$h:$m $ampm';
}

class BestWindowPill extends StatelessWidget {
  final BestWindow win;
  const BestWindowPill({super.key, required this.win});
  @override
  Widget build(BuildContext context) {
    final color = win.level == 'g' ? const Color(0xFF1F8A5B) : const Color(0xFFF2A93B);
    final label = win.level == 'g' ? 'Calm' : 'Fair';
    final now = DateTime.now();
    final sameDay = win.start.year == now.year && win.start.month == now.month && win.start.day == now.day;
    final day = sameDay ? 'Today' : _weekday(win.start);
    // Was a true pill (borderRadius 999, Row mainAxisSize:min hugging its text) — fine for a
    // short string, but "Best window: Sun 12:00 PM–8:00 PM · Fair" plus a longer day name or
    // 150%+ text scale routinely ran past the sheet's width with nowhere to go, clipping at the
    // right edge. A pill shape can't wrap onto a second line without looking broken (huge round
    // caps on a multi-line block), so this is a full-width banner instead — same tint/border
    // language, a normal card radius, and a wrapping Text that lets the row grow taller.
    return SizedBox(width: double.infinity, child: Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(color: color.withOpacity(.22),
        border: Border.all(color: color, width: 1), borderRadius: BorderRadius.circular(14)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 5),
          child: Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color))),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text('Best window: $day ${_fmtTime(win.start)}–${_fmtTime(win.end)} · $label',
          // PWA #bestWin{color:var(--ink)} (index.html:226) was dark text on a light tinted
          // pill — inverted to white now that the sheet itself is dark glass, not light paper.
          style: Theme.of(context).textTheme.titleSmall)),
      ]),
    ));
  }
}

String _weekday(DateTime t) {
  const names = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  return names[(t.toLocal().weekday - 1) % 7];
}

class DayTabs extends StatelessWidget {
  final List<DailyForecast> daily;
  final int selected;
  final ValueChanged<int> onSelect;
  const DayTabs({super.key, required this.daily, required this.selected, required this.onSelect});
  @override
  Widget build(BuildContext context) {
    final labels = <String>[];
    for (int i = 0; i < 7; i++) {
      if (i == 0) { labels.add('Today'); continue; }
      final t = daily.length > i ? daily[i].date : DateTime.now().add(Duration(days: i));
      labels.add(_weekday(t));
    }
    final theme = Theme.of(context);
    // Was flush against both scroll edges with only an 8px inter-pill gap and tight 12/6
    // padding — read as "cut off" rather than "scrollable", since nothing hinted more tabs sat
    // just past the edge. Leading/trailing AppSpacing.md gives the row visible breathing room
    // on both ends; roomier per-pill padding + a stronger selected-state border/shadow make the
    // current tab unambiguous at a glance.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Row(children: List.generate(labels.length, (i) {
        final sel = i == selected;
        // PWA #days button (index.html:111-112): inactive rgba(15,42,68,.10) bg + ink text;
        // active var(--ink) bg + white text.
        return Padding(padding: const EdgeInsets.only(right: AppSpacing.sm),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: sel ? const LinearGradient(colors: [Color(0xE65FB3E8), Color(0x8019C8FF)]) : null,
              color: sel ? null : Colors.white.withOpacity(.08),
              border: Border.all(color: sel ? Colors.white.withOpacity(.55) : Colors.white.withOpacity(.14)),
              boxShadow: sel ? [BoxShadow(color: const Color(0xFF19C8FF).withOpacity(.35), blurRadius: 10)] : null,
            ),
            child: Material(color: Colors.transparent, borderRadius: BorderRadius.circular(999),
              child: InkWell(borderRadius: BorderRadius.circular(999), onTap: () => onSelect(i),
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Text(labels[i], style: (sel ? theme.textTheme.titleSmall : theme.textTheme.labelMedium)
                    ?.copyWith(color: sel ? Colors.white : _secondaryText))))),
          ),
        );
      })),
    );
  }
}

// Public (not `_`-prefixed) specifically so test/hourly_table_responsive_test.dart can pump
// it directly — see that file for the width×text-scale verification matrix this was built
// against. Was a Row of fixed SizedBox-width cells (46/40/70/42px) that clipped "Rough" to
// "Roug"/"h" and let "10 AM" wrap, worse again under text scaling, since those widths were
// guessed against one font size rather than measured. Rebuilt on a LayoutBuilder choosing
// between a Table (IntrinsicColumnWidth — every column sized to its own widest cell across
// all rows, with zero hardcoded pixel widths, growing automatically under text scaling) and,
// below a measured width threshold, a stacked two-line layout per the "move wind details to
// a second line on narrow screens" requirement.
class HourlyTable extends StatelessWidget {
  final List<HourlyPoint> hourly;
  final int dayIdx;
  final BoatProfile profile;
  const HourlyTable({super.key, required this.hourly, required this.dayIdx, required this.profile});
  @override
  Widget build(BuildContext context) {
    if (hourly.isEmpty) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Loading hourly forecast…', style: TextStyle(color: Color(0xFF8FB6D6), fontSize: 12)));
    }
    final today = DateTime.now();
    final target = DateTime(today.year, today.month, today.day).add(Duration(days: dayIdx));
    final startHour = dayIdx == 0 ? today.hour : 5;
    final rows = hourly.where((h) {
      final l = h.t.toLocal();
      return l.year == target.year && l.month == target.month && l.day == target.day
          && l.hour >= startHour && l.hour <= 21;
    }).toList();
    if (rows.isEmpty) {
      // PWA index.html:728 — day-aware ("today" only when dayIdx is actually today) and
      // points at the day tabs rather than naming a specific weekday, which stopped being
      // true for most dayIdx values the moment this became a 7-day tab row.
      return Padding(padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('No daylight hours left ${dayIdx == 0 ? 'today' : 'that day'} — pick another day above.',
          style: const TextStyle(color: Color(0xFF8FB6D6), fontSize: 12)));
    }
    final items = rows.map((h) => _WeatherRow(h: h, profile: profile)).toList();
    return LayoutBuilder(builder: (context, constraints) {
      // Below this, the wide table's Wind/Gust columns (each its own explicit-label text,
      // e.g. "Wind 13 kn WNW") start contesting space with Time/Condition/Icon+Temp badly
      // enough to force wrapping even with IntrinsicColumnWidth — verified empirically via
      // the responsive test file at 320/375/390/430 lp × 100/150/200% text scale, not guessed.
      final narrow = constraints.maxWidth < 340;
      if (narrow) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: items.map((r) => r.buildNarrow(context)).toList());
      }
      return Table(
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        columnWidths: const {
          0: IntrinsicColumnWidth(), 1: IntrinsicColumnWidth(), 2: IntrinsicColumnWidth(),
          3: IntrinsicColumnWidth(), 4: IntrinsicColumnWidth(),
        },
        children: items.map((r) => r.buildWideRow(context)).toList(),
      );
    });
  }
}

String _hourLabel(DateTime t) {
  final l = t.toLocal();
  final h = l.hour == 0 ? 12 : (l.hour > 12 ? l.hour - 12 : l.hour);
  final ampm = l.hour >= 12 ? 'PM' : 'AM';
  return '$h $ampm';
}

// One hourly forecast row's content — cell builders are shared between the wide (Table,
// column-aligned) and narrow (stacked, 2-line) layouts in HourlyTable above, so both follow
// identical formatting/labels/colors and only the arrangement differs. Kept private/internal
// to HourlyTable (not part of its public test surface) since tests only need to pump
// HourlyTable itself to exercise this.
class _WeatherRow {
  final HourlyPoint h;
  final BoatProfile profile;
  const _WeatherRow({required this.h, required this.profile});

  String get _grade => score(h.windKt, h.gustKt, null, profile);
  Color get _color => _gradeColors[_grade]!;
  String get _condLabel => _grade == 'g' ? 'Calm' : (_grade == 'a' ? 'Fair' : 'Rough');
  String get _windStr => '${h.windKt?.round() ?? '—'} kn ${_dirName(h.windDirDeg ?? 0.0)}';
  String get _gustStr => '${h.gustKt?.round() ?? '—'} kn';
  String? get _rainStr => (h.precipPct != null && h.precipPct! > 0) ? '${h.precipPct!.round()}%' : null;

  Widget _time() => Text(_hourLabel(h.t), maxLines: 1, softWrap: false, overflow: TextOverflow.visible,
    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12));

  Widget _condition() => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: _color)),
    const SizedBox(width: 6),
    Text(_condLabel, maxLines: 1, softWrap: false, overflow: TextOverflow.visible,
      style: TextStyle(color: _color, fontWeight: FontWeight.w800, fontSize: 11)),
  ]);

  Widget _iconTemp() => Row(mainAxisSize: MainAxisSize.min, children: [
    _wxIconWidget(h.weatherCode, size: 16),
    const SizedBox(width: 4),
    Text('${h.tempF?.round() ?? '—'}°', maxLines: 1, overflow: TextOverflow.visible,
      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
  ]);

  // Explicit "Wind"/"Gust" labels + units, per spec — not just bare numbers.
  Widget _wind() => Text.rich(TextSpan(children: [
    const TextSpan(text: 'Wind ', style: TextStyle(color: Color(0xFF8FB6D6), fontSize: 10, fontWeight: FontWeight.w600)),
    TextSpan(text: _windStr, style: const TextStyle(color: Color(0xFFD1EEFF), fontSize: 11)),
  ]), maxLines: 1, softWrap: false, overflow: TextOverflow.visible);

  Widget _gust() => Text.rich(TextSpan(children: [
    const TextSpan(text: 'Gust ', style: TextStyle(color: Color(0xFF8FB6D6), fontSize: 10, fontWeight: FontWeight.w600)),
    TextSpan(text: _gustStr, style: const TextStyle(color: Color(0xFFD1EEFF), fontSize: 11)),
  ]), maxLines: 1, softWrap: false, overflow: TextOverflow.visible);

  Widget _rainChip() => Text('${_rainStr!} rain', maxLines: 1, overflow: TextOverflow.visible,
    style: const TextStyle(color: Color(0xFF8FB6D6), fontSize: 10));

  // ---- wide: one TableRow; HourlyTable's Table gives every column (across ALL rows) the
  // width of its own widest cell — no pixel guess here needs to anticipate the longest
  // string, the Table measures it. ----
  TableRow buildWideRow(BuildContext context) {
    Widget cell(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
      child: Align(alignment: Alignment.centerLeft, child: child),
    );
    return TableRow(children: [
      cell(_time()),
      cell(_condition()),
      cell(_iconTemp()),
      cell(_wind()),
      cell(Row(mainAxisSize: MainAxisSize.min, children: [
        _gust(),
        if (_rainStr != null) ...[const SizedBox(width: 10), _rainChip()],
      ])),
    ]);
  }

  // ---- narrow: time+condition stay one line (the only pairing the spec requires); icon+temp,
  // wind, gust and rain all flow into a Wrap below. A Row+Spacer for icon+temp overflowed at
  // 320lp/200% text scale — Spacer can't create space that doesn't exist, and time+condition+
  // icon+temp's combined intrinsic width exceeded 320px at that scale (caught by the
  // responsive test file, not guessed). Wrap can't overflow the same way: an item that doesn't
  // fit drops to its own line instead of clipping or forcing negative space. ----
  Widget buildNarrow(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        _time(),
        const SizedBox(width: 10),
        _condition(),
      ]),
      Padding(padding: const EdgeInsets.only(top: 3),
        child: Wrap(spacing: 14, runSpacing: 4, children: [
          _iconTemp(),
          _wind(),
          _gust(),
          if (_rainStr != null) _rainChip(),
        ])),
    ]),
  );
}

// ==================================================================================================
// Batch B widgets (alerts, MOB, anchor HUD, forecast sheet)
// ==================================================================================================

// PWA index.html:62-63 `#alert small{max-height:0}` collapses to a headline; `.open` reveals
// the full description. Tap toggles.
// Glassmorphism shell for the two map-overlay warning cards (NWS alert + boat-condition
// warning). Visual treatment only — the caller picks the amber/red gradient+border+glow;
// the actual title/body content and the optional close callback stay fully owned by the
// caller, so none of the underlying warning logic/data lives here.
// `nav` is the calmer blue/cyan variant for non-alert chrome (the nav shell's planning/
// navigating states). `mob` is a deliberately distinct, darker/denser red from the `red`
// warning severity above — an active emergency mode, not a dismissible alert — see
// .claude/skills/ayecaptain-glass-design/SKILL.md for the color-token rationale.
enum GlassSeverity { amber, red, nav, mob }

// Crossfade the round alert icon and the full card while animating their height.
// Keeping expansion here leaves alert/weather visibility decisions in the callers.
class _AnimatedWarningCard extends StatelessWidget {
  final GlassSeverity severity;
  final IconData icon;
  final Widget content;
  final VoidCallback onIconTap;
  final VoidCallback? onDismiss;
  final bool expanded;
  const _AnimatedWarningCard({required this.severity, required this.icon,
    required this.content, required this.onIconTap, this.onDismiss, required this.expanded});

  @override
  Widget build(BuildContext context) => AnimatedCrossFade(
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 260),
    sizeCurve: Curves.easeInOutCubic,
    firstCurve: Curves.easeInOut,
    secondCurve: Curves.easeInOut,
    alignment: Alignment.topLeft,
    crossFadeState: expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
    firstChild: GlassWarningCard(severity: severity, icon: icon,
      content: content, onIconTap: onIconTap, expanded: false),
    secondChild: GlassWarningCard(severity: severity, icon: icon,
      content: content, onIconTap: onIconTap, onDismiss: onDismiss, expanded: true),
  );
}

class GlassWarningCard extends StatelessWidget {
  final GlassSeverity severity;
  final IconData icon;
  final Widget content;
  final VoidCallback? onDismiss;
  final VoidCallback? onIconTap;
  final bool expanded;
  const GlassWarningCard({super.key, required this.severity, required this.icon,
    required this.content, this.onDismiss, this.onIconTap, required this.expanded});

  @override
  Widget build(BuildContext context) {
    final isAmber = severity == GlassSeverity.amber;
    final glow = isAmber ? const Color(0xFFFFAA24) : const Color(0xFFFF304B);
    final core = isAmber ? const Color(0xFFFFF3B0) : const Color(0xFFFFE9E9);

    final iconButton = GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onIconTap,
                  child: Semantics(
                    button: onIconTap != null,
                    label: isAmber ? 'Toggle alert details' : 'Toggle boat warning details',
                    child: Container(
                      width: 42, height: 42, alignment: Alignment.center,
                      decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [core.withOpacity(.34), glow.withOpacity(.24),
                        const Color(0xFF130F19).withOpacity(.76)],
                      stops: const [0, .42, 1],
                    ),
                    border: Border.all(color: core.withOpacity(.55), width: .8),
                    boxShadow: [
                      BoxShadow(color: glow.withOpacity(.52), blurRadius: 18, spreadRadius: 1),
                      BoxShadow(color: Colors.black.withOpacity(.34), blurRadius: 4,
                        offset: const Offset(1.5, 3)),
                    ],
                  ),
                      child: Stack(alignment: Alignment.center, children: [
                    Positioned(
                      left: 6, right: 6, top: 3, height: 11,
                      child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(100),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter, end: Alignment.bottomCenter,
                          colors: [Colors.white.withOpacity(.38), Colors.white.withOpacity(0)],
                        ),
                      ))),
                    ),
                    ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                      child: Icon(icon, color: glow, size: 32),
                    ),
                    ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(sigmaX: 1.8, sigmaY: 1.8),
                      child: Icon(icon, color: glow, size: 29),
                    ),
                    Transform.translate(
                      offset: const Offset(1.2, 2),
                      child: Icon(icon, color: const Color(0xFF421620), size: 27),
                    ),
                    Transform.translate(
                      offset: const Offset(-.6, -.7),
                      child: Icon(icon, color: core, size: 27),
                    ),
                  ]),
                    ),
                  ),
    );

    if (!expanded) {
      return Align(alignment: Alignment.centerLeft,
        child: Padding(padding: const EdgeInsets.only(left: 15), child: iconButton));
    }

    return _GlassSurface(
      severity: severity, borderRadius: 18, blurSigma: 5,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          iconButton,
          const SizedBox(width: 12),
          Expanded(child: content),
          if (onDismiss != null) ...[
            const SizedBox(width: 8),
            Container(width: .7, height: 34, color: glow.withOpacity(.70)),
            const SizedBox(width: 3),
            _GlassCloseButton(onTap: onDismiss!),
          ],
        ]),
      ),
    );
  }
}

// Shared glass-card shell — composes the layered recipe (edge glow painted over a
// blurred, tinted, reflective fill) used by GlassWarningCard, _NavShell, and the
// right-rail buttons. One place to adjust if the recipe itself ever changes, instead of
// three hand-nested CustomPaint/Clip/BackdropFilter stacks drifting apart over time.
// For `circular: true`, the edge radius is a large sentinel so _WarningEdgeGlow's own
// RRect clamps it down to a true half-size circle regardless of the child's actual size —
// avoids hardcoding a radius that only happens to match one particular button size.
class _GlassSurface extends StatelessWidget {
  final GlassSeverity severity;
  final Widget child;
  final double borderRadius;
  final bool circular;
  final double blurSigma;
  const _GlassSurface({
    required this.severity, required this.child,
    this.borderRadius = 14, this.circular = false, this.blurSigma = 6,
  });

  @override
  Widget build(BuildContext context) {
    final blurred = BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
      child: CustomPaint(painter: _WarningGlassSurface(severity: severity), child: child),
    );
    return CustomPaint(
      // Paint after the clipped glass: its tint must not dim the neon or hotspots.
      foregroundPainter: _WarningEdgeGlow(
        severity: severity,
        radius: circular ? 999 : borderRadius - .8,
      ),
      child: circular
        ? ClipOval(child: blurred)
        : ClipRRect(borderRadius: BorderRadius.circular(borderRadius), child: blurred),
    );
  }
}

// Translucent colored glass, with broad reflections and pools of light at the rim.
// All fills are clipped by the card. The map supplies the detail behind the glass.
class _WarningGlassSurface extends CustomPainter {
  final GlassSeverity severity;
  const _WarningGlassSurface({required this.severity});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // (glow color, base tint wash, base wash opacity, overall intensity — `nav` reads calm
    // rather than alarming, so it runs denser/more opaque but visually quieter than a warning).
    final (color, baseTint, baseOpacity, intensity) = switch (severity) {
      GlassSeverity.amber => (const Color(0xFFFFAA24), const Color(0xFF162932), .43, 1.0),
      GlassSeverity.red => (const Color(0xFFFF304B), const Color(0xFF30182C), .43, 1.0),
      GlassSeverity.nav => (const Color(0xFF19C8FF), const Color(0xFF041E32), .78, .6),
      // Darker/denser than the warning red, full intensity (urgent, not muted like nav).
      GlassSeverity.mob => (const Color(0xFFFF4055), const Color(0xFF190A15), .80, 1.0),
    };
    canvas.drawRect(rect, Paint()..color = baseTint.withOpacity(baseOpacity));
    canvas.drawRect(rect, Paint()..shader = LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [color.withOpacity(.40 * intensity), color.withOpacity(.08 * intensity),
        color.withOpacity(.03 * intensity), color.withOpacity(.26 * intensity)],
      stops: const [0, .28, .68, 1],
    ).createShader(rect));

    // Wide, tapered reflection across the face, like light reflected in tinted glass.
    canvas.drawRect(rect, Paint()..shader = LinearGradient(
      begin: Alignment.topLeft, end: Alignment.bottomRight,
      colors: [Colors.white.withOpacity(.16), Colors.white.withOpacity(.02),
        Colors.transparent, Colors.white.withOpacity(.10), Colors.transparent],
      stops: const [0, .18, .44, .72, 1],
    ).createShader(rect));

    void light(double x, double y, double width, double height, double opacity) {
      final ellipse = Rect.fromCenter(center: Offset(size.width * x, size.height * y),
        width: size.width * width, height: size.height * height);
      canvas.save();
      canvas.translate(ellipse.center.dx, ellipse.center.dy);
      canvas.scale(ellipse.width / 2, ellipse.height / 2);
      canvas.drawCircle(Offset.zero, 1, Paint()..shader = ui.Gradient.radial(
        Offset.zero, 1, [color.withOpacity(opacity), color.withOpacity(opacity * .3),
          color.withOpacity(0)], const [0, .42, 1]));
      canvas.restore();
    }
    light(.02, .10, .40, 1.5, .36 * intensity);
    light(.90, .02, .50, 1.3, .44 * intensity);
    light(.09, 1, .42, .85, .40 * intensity);
    light(.98, .95, .32, 1.1, .30 * intensity);
  }

  @override
  bool shouldRepaint(covariant _WarningGlassSurface old) => old.severity != severity;
}

class _WarningEdgeGlow extends CustomPainter {
  final GlassSeverity severity;
  // Matches the card's own ClipRRect radius minus the .8 deflate below (18 - .8 ≈ 17.2) —
  // pass the caller's actual corner radius so the rim doesn't mismatch a differently-rounded card.
  final double radius;
  const _WarningEdgeGlow({required this.severity, this.radius = 17.2});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(.8);
    final edge = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final isAmber = severity == GlassSeverity.amber;
    final (color, core, intensity) = switch (severity) {
      GlassSeverity.amber => (const Color(0xFFFFB52E), const Color(0xFFFFFFBC), 1.0),
      GlassSeverity.red => (const Color(0xFFFF304B), const Color(0xFFFFEEEE), 1.0),
      // Deliberately quieter than the alert severities — this is calm chrome, not a warning.
      GlassSeverity.nav => (const Color(0xFF19C8FF), const Color(0xFFD7F3FF), .55),
      // Muted core (not bright white, unlike the warning cards) — urgent/dark, not glossy.
      GlassSeverity.mob => (const Color(0xFFFF4055), const Color(0xFFFF8A96), 1.0),
    };
    // Keep the continuous rim restrained so individual reflections can shine brighter.
    canvas.drawRRect(edge, Paint()
      ..color = color.withOpacity(.65 * intensity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawRRect(edge, Paint()
      ..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [core, color.withOpacity(.65), color, core.withOpacity(.85)],
        stops: const [0, .38, .70, 1]).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.15);

    // Radial shaders fade each hotspot along the actual rounded outline, including
    // corners. A white-hot core, tight colored glow and wide bloom share that fade.
    void hotspot(double x, double y, double radius) {
      final center = Offset(size.width * x, size.height * y);
      final reach = size.width * radius;
      for (final layer in <List<double>>[
        [9, 6, .85], [3.5, 1.6, 1], [1.4, 0, 1],
      ]) {
        final ink = layer[1] == 0 ? core : color;
        final paint = Paint()
          ..shader = ui.Gradient.radial(center, reach,
            [ink.withOpacity(layer[2] * intensity), ink.withOpacity(layer[2] * .65 * intensity),
              ink.withOpacity(0)],
            const [0, .25, 1])
          ..style = PaintingStyle.stroke
          ..strokeWidth = layer[0];
        if (layer[1] > 0) paint.maskFilter = MaskFilter.blur(BlurStyle.normal, layer[1]);
        canvas.drawRRect(edge, paint);
      }
    }
    hotspot(.045, .13, .13);
    hotspot(isAmber ? .92 : .83, 0, .17);
    hotspot(.14, 1, .12);
    hotspot(.99, .84, .11);

    // Narrow, white reflections on the rounded rim give a few spots a polished
    // specular shine. Fade both ends to avoid a continuous white frame.
    void glint(double x1, double x2, double y, double strength) {
      final span = Rect.fromLTRB(size.width * x1, y - 2,
        size.width * x2, y + 2);
      canvas.drawLine(Offset(span.left, y), Offset(span.right, y), Paint()
        ..shader = LinearGradient(colors: [
          Colors.white.withOpacity(0), Colors.white.withOpacity(strength),
          Colors.white.withOpacity(strength), Colors.white.withOpacity(0),
        ], stops: const [0, .38, .52, 1]).createShader(span)
        ..strokeWidth = 1.35
        ..strokeCap = StrokeCap.round);
    }
    glint(isAmber ? .26 : .08, isAmber ? .52 : .27, edge.top, .88 * intensity);
    glint(isAmber ? .82 : .70, .96, edge.top, .96 * intensity);
    glint(.04, isAmber ? .22 : .18, edge.bottom, .83 * intensity);
    glint(.77, .96, edge.bottom, .92 * intensity);
  }

  @override
  bool shouldRepaint(covariant _WarningEdgeGlow old) =>
      old.severity != severity || old.radius != radius;
}

// Transparent normally, subtle translucent-white circle while pressed — per the design brief,
// not a Material ripple (a Material ancestor would fight the transparent glass background).
class _GlassCloseButton extends StatefulWidget {
  final VoidCallback onTap;
  const _GlassCloseButton({required this.onTap});
  @override
  State<_GlassCloseButton> createState() => _GlassCloseButtonState();
}
class _GlassCloseButtonState extends State<_GlassCloseButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTapDown: (_) => setState(() => _pressed = true),
    onTapCancel: () => setState(() => _pressed = false),
    onTapUp: (_) => setState(() => _pressed = false),
    onTap: widget.onTap,
    child: Container(
      width: 38, height: 38, alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle,
        color: _pressed ? Colors.white.withOpacity(.18) : Colors.transparent),
      child: const Icon(Icons.close, color: Colors.white, size: 18),
    ),
  );
}

class _AlertBanner extends StatefulWidget {
  final NwsAlert alert;
  final VoidCallback onDismiss;
  const _AlertBanner({required this.alert, required this.onDismiss});
  @override
  State<_AlertBanner> createState() => _AlertBannerState();
}
class _AlertBannerState extends State<_AlertBanner> {
  bool _open = false;
  @override
  void didUpdateWidget(covariant _AlertBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.alert.event != widget.alert.event ||
        oldWidget.alert.headline != widget.alert.headline) _open = false;
  }

  @override
  Widget build(BuildContext context) {
    return _AnimatedWarningCard(
        // NWS alerts are always amber; the boat-conditions warning below is red.
        severity: GlassSeverity.amber,
        icon: Icons.warning_amber_rounded,
        onIconTap: () => setState(() => _open = !_open),
        expanded: _open,
        onDismiss: widget.onDismiss,
        content: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(widget.alert.event, style: const TextStyle(color: Color(0xFFFFC846), fontWeight: FontWeight.w700, fontSize: 15)),
          if (widget.alert.headline.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(widget.alert.headline,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white.withOpacity(.93), fontSize: 12, height: 1.3)),
            ),
        ]),
    );
  }
}

class _BoatWarningBanner extends StatefulWidget {
  final String text;
  final String severity;   // Kept for the near-limit text treatment.
  final VoidCallback onDismiss;
  const _BoatWarningBanner({required this.text, required this.onDismiss, this.severity = 'over'});
  @override
  State<_BoatWarningBanner> createState() => _BoatWarningBannerState();
}

class _BoatWarningBannerState extends State<_BoatWarningBanner> {
  bool _open = false;

  @override
  void didUpdateWidget(covariant _BoatWarningBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.severity != widget.severity) _open = false;
  }

  @override
  Widget build(BuildContext context) {
    final isNear = widget.severity == 'near';
    return _AnimatedWarningCard(
      severity: GlassSeverity.red,
      icon: Icons.error_outline_rounded,
      onIconTap: () => setState(() => _open = !_open),
      expanded: _open,
      onDismiss: widget.onDismiss,
      content: Text(widget.text,
        style: TextStyle(
        color: isNear ? const Color(0xFFFFC846) : Colors.white,
        fontWeight: FontWeight.w700, fontSize: 13, height: 1.3)),
    );
  }
}

// Batch C: pulsing ring — port of the PWA's `.mobring` / `@keyframes mobpulse`
// (index.html:201-202): a 1.4s ease-out box-shadow ring that grows from 0 to 20px while
// fading out, repeating forever. Flutter has no native box-shadow animation, so an
// AnimationController drives a Container whose BoxShadow spreadRadius/opacity we compute
// each frame — same visual result.
class _MobPin extends StatefulWidget {
  const _MobPin();
  @override
  State<_MobPin> createState() => _MobPinState();
}
class _MobPinState extends State<_MobPin> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 90, height: 90,
    child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
      AnimatedBuilder(animation: _ctrl, builder: (ctx, _) {
        final t = _ctrl.value;
        final spread = 20 * t;
        final alpha = (0.55 * (1 - t)).clamp(0, 1).toDouble();
        return Container(
          width: 30, height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0x59D93A2B),
            border: Border.all(color: const Color(0xFFD93A2B), width: 3),
            boxShadow: [BoxShadow(color: Color.fromRGBO(217, 58, 43, alpha), spreadRadius: spread)],
          ),
        );
      }),
      // PWA `.mobbuoy{width:56px!important;height:auto}` (index.html:205) — the source PNG is
      // 420x391, so height ≈ 52px preserving that ratio. Was 36x36, ~35% undersized for a
      // safety-critical marker.
      Image.asset('assets/icons/mob-buoy.png', width: 56, height: 52, fit: BoxFit.contain),
    ]),
  );
}

// Rotating chevron pointing along the bearing from boat → MOB, capped at t=0.88 along the
// line so it doesn't bury the pulsing ring — matches index.html:1851-1854, 1868-1872.
class _MobArrow extends StatelessWidget {
  final double bearingDeg;
  const _MobArrow({required this.bearingDeg});
  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: bearingDeg * math.pi / 180,
    child: CustomPaint(size: const Size(24, 24), painter: _MobArrowPainter()),
  );
}
class _MobArrowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // SVG path M13 1 L20 18 L13 13.5 L6 18 Z scaled from a 26x26 viewBox to 24x24.
    final s = size.width / 26;
    final path = ui.Path()
      ..moveTo(13 * s, 1 * s)
      ..lineTo(20 * s, 18 * s)
      ..lineTo(13 * s, 13.5 * s)
      ..lineTo(6 * s, 18 * s)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFFF4433));
    canvas.drawPath(path, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.4);
  }
  @override
  bool shouldRepaint(covariant _MobArrowPainter old) => false;
}

// Hand-drawn particle smoke drifting with live wind — orange puffs rising from the buoy.
// Approximates index.html mobsmoke2 canvas (index.html:206-211, startMobSmokeLoop).
class _MobSmoke extends StatefulWidget {
  final double windKt, windDirDeg;
  const _MobSmoke({required this.windKt, required this.windDirDeg});
  @override
  State<_MobSmoke> createState() => _MobSmokeState();
}
class _MobSmokeState extends State<_MobSmoke> with SingleTickerProviderStateMixin {
  late final _tick = createTicker(_step);
  final math.Random _rng = math.Random();
  final List<_SmokePuff> _puffs = [];
  int _lastMs = 0;
  @override
  void initState() { super.initState(); _tick.start(); }
  @override
  void dispose() { _tick.dispose(); super.dispose(); }
  void _step(Duration elapsed) {
    final now = elapsed.inMilliseconds;
    final dt = _lastMs == 0 ? 0.016 : math.min(0.05, (now - _lastMs) / 1000);
    _lastMs = now;
    if (_puffs.length < 14 && _rng.nextDouble() < 0.12) {
      _puffs.add(_SmokePuff(x: (_rng.nextDouble() - 0.5) * 6, y: 0, age: 0, life: 1.8 + _rng.nextDouble()));
    }
    final rad = (widget.windDirDeg + 180) * math.pi / 180;
    final vx = math.sin(rad) * (widget.windKt * 0.6);
    for (final p in _puffs) {
      p.age += dt;
      p.y -= (14 + widget.windKt) * dt;
      p.x += vx * dt;
    }
    _puffs.removeWhere((p) => p.age >= p.life);
    setState(() {});
  }
  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(80, 80),
    painter: _SmokePainter(puffs: _puffs),
  );
}
class _SmokePuff {
  double x, y, age, life;
  _SmokePuff({required this.x, required this.y, required this.age, required this.life});
}
class _SmokePainter extends CustomPainter {
  final List<_SmokePuff> puffs;
  const _SmokePainter({required this.puffs});
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2 + 8);
    for (final p in puffs) {
      final t = p.age / p.life;
      final alpha = (1 - t).clamp(0, 1).toDouble() * 0.5;
      final r = 6 + 14 * t;
      final center = c + Offset(p.x, p.y);
      canvas.drawCircle(center, r, Paint()
        ..shader = RadialGradient(colors: [
          Color.fromRGBO(255, 140, 40, alpha), Color.fromRGBO(255, 140, 40, 0),
        ]).createShader(Rect.fromCircle(center: center, radius: r)));
    }
  }
  @override
  bool shouldRepaint(covariant _SmokePainter old) => true;
}

// Wake spray — churning white particles astern of the boat while underway. Direct port of
// the PWA's drawSpray (index.html:1026-1051): STERN_OFF=40px behind the marker, particle
// count/spread/speed scale with a speed factor saturating at 16 kn, only emits above 1.4 kn.
// Ported to LOCAL (pre-rotation) coordinates — bow points up (-y) in this widget's own space,
// so "astern" is simply +y; the caller wraps this in the SAME heading rotation as the boat
// sprite, so screen-space orientation matches automatically with no LatLng->screen projection.
class _WakeSpray extends StatefulWidget {
  final double headingDeg, speedKt;
  const _WakeSpray({required this.headingDeg, required this.speedKt});
  @override
  State<_WakeSpray> createState() => _WakeSprayState();
}
class _WakeSprayState extends State<_WakeSpray> with SingleTickerProviderStateMixin {
  late final _tick = createTicker(_step);
  final math.Random _rng = math.Random();
  final List<_SprayParticle> _particles = [];
  int _lastMs = 0;
  @override
  void initState() { super.initState(); _tick.start(); }
  @override
  void dispose() { _tick.dispose(); super.dispose(); }

  void _step(Duration elapsed) {
    final now = elapsed.inMilliseconds;
    final dt = _lastMs == 0 ? 0.016 : math.min(0.05, (now - _lastMs) / 1000);
    _lastMs = now;
    final sf = math.min(1.0, widget.speedKt / 16);
    if (widget.speedKt > 1.4) {
      const sternOff = 40.0;
      final wantPerSec = 1 + (sf * 4).round();
      final spawnCount = (wantPerSec * dt * 60).round().clamp(0, 6);
      for (int i = 0; i < spawnCount; i++) {
        final fan = (_rng.nextDouble() - 0.5) * (0.5 + sf * 0.9);
        final ca = math.cos(fan), sa = math.sin(fan);
        // astern unit vector in local space = (0,1); rotate by the fan angle, matching the
        // PWA's dx = bxu*ca - byu*sa, dy = bxu*sa + byu*ca with (bxu,byu) = (0,1).
        final dx = -sa, dy = ca;
        final s = 1.2 + sf * 3.6 + _rng.nextDouble() * 1.5;
        _particles.add(_SprayParticle(
          x: (_rng.nextDouble() - 0.5) * 6, y: sternOff + (_rng.nextDouble() - 0.5) * 6,
          vx: dx * s, vy: dy * s, r: 1.6 + _rng.nextDouble() * 2.4, life: 1.0,
        ));
      }
    }
    if (_particles.length > 170) _particles.removeRange(0, _particles.length - 170);
    final damp = math.pow(0.93, dt * 60).toDouble();
    for (final p in _particles) {
      p.x += p.vx * dt * 60; p.y += p.vy * dt * 60;
      p.vx *= damp; p.vy *= damp;
      p.vy += 0.04 * dt * 60;
      p.r += 0.12 * dt * 60;
      p.life -= 0.028 * dt * 60;
    }
    _particles.removeWhere((p) => p.life <= 0);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: widget.headingDeg * math.pi / 180,
    child: CustomPaint(size: const Size(260, 260), painter: _SprayPainter(particles: _particles)),
  );
}
class _SprayParticle {
  double x, y, vx, vy, r, life;
  _SprayParticle({required this.x, required this.y, required this.vx, required this.vy, required this.r, required this.life});
}
class _SprayPainter extends CustomPainter {
  final List<_SprayParticle> particles;
  const _SprayPainter({required this.particles});
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    for (final p in particles) {
      final alpha = math.min(.8, p.life * .9).clamp(0.0, 1.0).toDouble();
      if (alpha <= 0) continue;
      canvas.drawCircle(c + Offset(p.x, p.y), p.r, Paint()..color = Colors.white.withOpacity(alpha));
    }
  }
  @override
  bool shouldRepaint(covariant _SprayPainter old) => true;
}


class _AnchorHud extends StatelessWidget {
  final LatLng from, to;
  final double radiusFt;
  final bool breached;
  final VoidCallback onPlus, onMinus, onStop;
  const _AnchorHud({required this.from, required this.to, required this.radiusFt, required this.breached,
      required this.onPlus, required this.onMinus, required this.onStop});
  @override
  Widget build(BuildContext context) {
    final driftFt = _haversineM(from, to) * 3.28;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(color: breached ? const Color(0xE6D93A2B) : const Color(0xE60F2A44), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        _adjBtn('−', onMinus),
        const SizedBox(width: 8),
        Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
          Text('${driftFt.round()} ft', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, height: 1)),
          Text('drift · radius ${radiusFt.round()} ft', style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 11)),
        ])),
        _adjBtn('+', onPlus),
        const SizedBox(width: 8),
        Material(color: const Color(0x33FFFFFF), borderRadius: BorderRadius.circular(8),
          child: InkWell(borderRadius: BorderRadius.circular(8), onTap: onStop,
            child: const Padding(padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text('Stop', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)))),
        ),
      ]),
    );
  }
  Widget _adjBtn(String label, VoidCallback onTap) => Material(color: const Color(0x33FFFFFF), borderRadius: BorderRadius.circular(8),
    child: InkWell(borderRadius: BorderRadius.circular(8), onTap: onTap,
      child: SizedBox(width: 34, height: 34, child: Center(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800))))));
}

class ForecastSheet extends StatelessWidget {
  final List<DailyForecast> daily;
  const ForecastSheet({super.key, required this.daily});
  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    initialChildSize: 0.75, minChildSize: 0.4, maxChildSize: 0.95, expand: false,
    builder: (ctx, scroll) => Container(
      decoration: const BoxDecoration(color: Color(0xFF0F2A44), borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: ListView(controller: scroll, children: [
        Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(color: const Color(0x66FFFFFF), borderRadius: BorderRadius.circular(2)))),
        const Text('7-day forecast', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (daily.isEmpty) const Text('No forecast data', style: TextStyle(color: Color(0xCCFFFFFF)))
        else ...daily.take(7).map((d) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            SizedBox(width: 56, child: Text(_dayName(d.date), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
            Text(_wxIcon(d.weatherCode), style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 10),
            Expanded(child: Text('${d.tMaxF?.round() ?? "—"}°/${d.tMinF?.round() ?? "—"}° · wind ${d.windMaxKt?.round() ?? "—"} kn gust ${d.gustMaxKt?.round() ?? "—"}',
                style: const TextStyle(color: Color(0xEEFFFFFF), fontSize: 13))),
          ]),
        )),
        const SizedBox(height: 12),
      ]),
    ),
  );
}

String _dayName(DateTime d) {
  const names = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  return names[(d.weekday - 1) % 7];
}
// ==================================================================================================
// Batch B.6 — tide dashboard: SVG-style curve + sunrise/sunset icons + ocean band + Now pill + hi/lo cards.
// Ports index.html:865-963 (renderTide) and the visual language of the PWA screenshot.
// ==================================================================================================

class TidesSheet extends StatefulWidget {
  final TideStation? station;
  final List<TidePoint> tides;
  final DateTime? sunrise, sunset, tomorrowSunrise, tomorrowSunset;
  final String initialUnit;
  final ValueChanged<String>? onUnitChanged;
  const TidesSheet({super.key, required this.station, required this.tides,
    this.sunrise, this.sunset, this.tomorrowSunrise, this.tomorrowSunset,
    this.initialUnit = 'ft', this.onUnitChanged});
  @override
  State<TidesSheet> createState() => _TidesSheetState();
}

class _TidesSheetState extends State<TidesSheet> {
  late String _unit;
  ui.Image? _sunrise, _sunset, _ocean;
  @override
  void initState() {
    super.initState();
    _unit = widget.initialUnit;
    _loadImage('assets/icons/sunrise.png').then((i) { if (mounted) setState(() => _sunrise = i); });
    _loadImage('assets/icons/sunset.png').then((i) { if (mounted) setState(() => _sunset = i); });
    _loadImage('assets/icons/ocean.png').then((i) { if (mounted) setState(() => _ocean = i); });
  }
  @override
  void didUpdateWidget(covariant TidesSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialUnit != widget.initialUnit) _unit = widget.initialUnit;
  }
  Future<ui.Image?> _loadImage(String assetPath) async {
    try {
      final bd = await rootBundle.load(assetPath);
      final codec = await ui.instantiateImageCodec(bd.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) { return null; }
  }

  void _setUnit(String u) {
    setState(() => _unit = u);
    widget.onUnitChanged?.call(u);
  }

  @override
  Widget build(BuildContext context) {
    final tides = widget.tides;
    final curve = cosineTideCurve(tides);
    final now = DateTime.now();
    // Pick a 24-hour window centred (roughly) on now — matches the PWA's default view.
    final t0 = curve.isNotEmpty
        ? curve.firstWhere((s) => !s.t.isBefore(now.subtract(const Duration(hours: 6))), orElse: () => curve.first).t
        : now.subtract(const Duration(hours: 6));
    final t1 = t0.add(const Duration(hours: 24));
    final windowCurve = curve.where((s) => !s.t.isBefore(t0) && !s.t.isAfter(t1)).toList();
    final windowHilo = tides.where((p) => !p.t.isBefore(t0) && !p.t.isAfter(t1)).toList();
    final nextFour = tides.where((p) => !p.t.isBefore(now)).take(4).toList();
    // Used to be its own dark-navy card (own gradient/shadow/radius) hand-embedded inside the
    // light "Set up your boat" sheet — a mismatch (dark card floating in a light sheet) that
    // only existed because this was originally a standalone full-screen tide modal (TODO.md).
    // Now that the sheet itself is glass (ayecaptain-glass-design SKILL.md), this is just a
    // divider + continuation of the same card, not a nested one.
    // Sizing below is tightened throughout (padding, gaps, chart height, card/footer text) so
    // this one sub-section doesn't dwarf the sheet's 50%-of-screen height budget
    // (_BottomSheetState.sheetMaxH), shared with the weather block/day tabs/hourly table above.
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(height: 1, color: Colors.white.withOpacity(.10), margin: const EdgeInsets.only(bottom: 12)),
          _header(),
          const SizedBox(height: 8),
          _legend(),
          const SizedBox(height: 8),
          // PWA's chart is a fixed viewBox="0 0 360 220" (index.html:886), scaled via
          // width:100%/height:auto — i.e. a FIXED 360:220 aspect ratio. The painter's margins
          // (mL/mR/mT/mB below) are pixel constants tuned to that exact ratio; an earlier pass
          // changed this to 150/360 to save vertical space, which distorted the ratio and cut
          // the chart off. Restored to the real ratio — this section's own height stays this
          // real size; the space savings live in the padding/gaps/fonts around it instead.
          LayoutBuilder(builder: (context, box) => SizedBox(
            // Clamp range bumped slightly (was 165-280) to give the now-larger chart
            // annotations room without distorting the real 360:220 ratio above.
            height: (box.maxWidth * 220 / 360).clamp(175.0, 300.0).toDouble(),
            child: CustomPaint(painter: _TidePainter(
              curve: windowCurve, hilo: windowHilo,
              t0: t0, t1: t1, now: now,
              sunrises: [widget.sunrise, widget.tomorrowSunrise].whereType<DateTime>().toList(),
              sunsets: [widget.sunset, widget.tomorrowSunset].whereType<DateTime>().toList(),
              sunriseImg: _sunrise, sunsetImg: _sunset, oceanImg: _ocean,
              unit: _unit,
              // CustomPainter text has no Theme/MediaQuery access of its own — a plain Text
              // widget scales under system text-scaling automatically, but canvas-drawn text
              // doesn't unless the scale factor is read here and threaded through explicitly.
              textScale: MediaQuery.textScalerOf(context).scale(1.0),
            )),
          )),
          const SizedBox(height: 10),
          _hiLoCards(nextFour),
          const SizedBox(height: 8),
          _footer(),
        ]);
  }

  Widget _header() {
    final theme = Theme.of(context);
    final s = widget.station;
    final today = DateTime.now();
    final dateStr = '${_dayName(today)}, ${_monthName(today.month)} ${today.day}, ${today.year}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.location_on_rounded, color: Color(0xFF2388FF), size: 20),
        const SizedBox(width: AppSpacing.xs + 2),
        Expanded(child: Text(s?.name ?? 'Finding tide station…', maxLines: 1, overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium)),
        _unitToggle(),
      ]),
      if (s != null) Padding(padding: const EdgeInsets.only(left: 26, top: 1),
        child: Text('${s.lat.abs().toStringAsFixed(4)}° ${s.lat >= 0 ? 'N' : 'S'}, '
          '${s.lng.abs().toStringAsFixed(4)}° ${s.lng >= 0 ? 'E' : 'W'}',
          style: theme.textTheme.labelSmall)),
      Padding(padding: const EdgeInsets.only(top: AppSpacing.xs + 2),
        child: Container(padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          decoration: BoxDecoration(color: const Color(0xFF0B2E4C),
            border: Border.all(color: const Color(0xFF245372)), borderRadius: BorderRadius.circular(9)),
          // mainAxisSize:min keeps this a compact chip rather than a full-width bar, but a
          // plain Text sibling can't shrink below its own intrinsic width — at 320lp/150%+
          // text scale "Sat, Oct 3, 2026" alone exceeded the sheet width with nowhere to go,
          // overflowing horizontally (caught by the responsive test, not guessed). Flexible
          // lets the Row still shrink-wrap when the date fits on one line (the common case)
          // while allowing it to wrap onto a second line instead of overflowing when it won't.
          child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.calendar_month_outlined, color: _secondaryText, size: 14),
            const SizedBox(width: 5),
            Flexible(child: Text(dateStr, style: theme.textTheme.labelMedium?.copyWith(color: Colors.white))),
          ]))),
    ]);
  }

  Widget _unitToggle() {
    Widget chip(String u) {
      final on = _unit == u;
      return Material(color: on ? const Color(0xFF1466C7) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(borderRadius: BorderRadius.circular(8), onTap: () => _setUnit(u),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(u, style: TextStyle(color: on ? Colors.white : const Color(0xFF9CC1DE),
              fontWeight: FontWeight.w800, fontSize: 11)))));
    }
    return Container(padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: const Color(0xFF0B2E4C),
        border: Border.all(color: const Color(0xFF2D5C7C)), borderRadius: BorderRadius.circular(11)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [chip('ft'), chip('m')]));
  }

  // Sub-labels ("Good conditions" etc.) dropped — same meaning already carried by color+label
  // elsewhere (hourly table), and cutting them saves a whole extra text line here.
  Widget _legend() {
    Widget dot(Color c, String l) => Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: c)),
      const SizedBox(width: 5),
      Text(l, style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 13)),
    ]);
    return Wrap(spacing: AppSpacing.md, runSpacing: AppSpacing.xs, children: [
      dot(const Color(0xFF22C55E), 'Calm'),
      dot(const Color(0xFFF2A93B), 'Fair'),
      dot(const Color(0xFFD93A2B), 'Rough'),
    ]);
  }

  // PWA's #tideCards (index.html:145-153): a plain 2-col CSS grid, gap 9px, each .tcard sized
  // by its own content (flex row, padding 11px, icon-text gap 10px) — NOT a fixed aspect ratio.
  // GridView.count(childAspectRatio:...) forced every card to a taller box than its content
  // needed, leaving dead space that read as "a lot of padding". Rebuilt as natural-height rows
  // (IntrinsicHeight keeps the two cards in each row equal-height without forcing either
  // taller than needed) to match the PWA's actual sizing exactly.
  Widget _hiLoCards(List<TidePoint> pts) {
    Widget card(TidePoint p) {
      final isHigh = p.type == 'H';
      final color = isHigh ? const Color(0xFF35E96A) : const Color(0xFFFF5A55);
      // Sized for this embedded context, not the original standalone-modal constants (11px
      // padding/30px ring/17px time) — those read as oversized once placed among the sheet's
      // other compact rows; caught via a live demo pass, not a style preference.
      return Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
        decoration: BoxDecoration(color: const Color(0x8C0B2C47),
          border: Border.all(color: const Color(0x33194762)), borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 22, height: 22,
            decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF17313D),
              border: Border.all(color: color, width: 2)),
            child: Icon(isHigh ? Icons.arrow_upward : Icons.arrow_downward, color: color, size: 10)),
          const SizedBox(width: 8),
          Flexible(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(isHigh ? 'High Tide' : 'Low Tide', maxLines: 1,
              style: const TextStyle(color: _secondaryText, fontSize: 11, fontWeight: FontWeight.w600)),
            Text(_fmtTime(p.t), maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14, height: 1.2)),
            Text('${_fmtV(p.v)} $_unit', maxLines: 1,
              style: const TextStyle(color: _secondaryText, fontSize: 12)),
          ])),
        ]));
    }
    if (pts.isEmpty) return Padding(padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Text('No upcoming tide events', style: Theme.of(context).textTheme.labelSmall));
    final rows = <Widget>[];
    for (var i = 0; i < pts.length; i += 2) {
      if (i > 0) rows.add(const SizedBox(height: 9));
      rows.add(IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: card(pts[i])),
        if (i + 1 < pts.length) ...[const SizedBox(width: 9), Expanded(child: card(pts[i + 1]))]
        else const Spacer(),
      ])));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  Widget _footer() {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('⚓  Plan Better. Boat Safer.',
        style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: AppSpacing.xs - 1),
      Text('≈ Tide Data · ${widget.station?.name ?? "—"}', style: theme.textTheme.labelSmall),
      Text('NOAA CO-OPS astronomical predictions · updates every 20 min', style: theme.textTheme.labelSmall),
    ]);
  }

  double _fmtVal(double v) => _unit == 'm' ? v * 0.3048 : v;
  String _fmtV(double v) => _fmtVal(v).toStringAsFixed(1);
}

String _monthName(int m) {
  const names = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  return names[(m - 1).clamp(0, 11)];
}

class _TidePainter extends CustomPainter {
  final List<_TideSample> curve;
  final List<TidePoint> hilo;
  final DateTime t0, t1, now;
  final List<DateTime> sunrises, sunsets;
  final ui.Image? sunriseImg, sunsetImg, oceanImg;
  final String unit;
  final double textScale;
  _TidePainter({required this.curve, required this.hilo, required this.t0, required this.t1, required this.now,
    required this.sunrises, required this.sunsets,
    this.sunriseImg, this.sunsetImg, this.oceanImg, required this.unit, required this.textScale});

  double _u(double v) => unit == 'm' ? v * 0.3048 : v;
  String _fv(double v) => '${_u(v).toStringAsFixed(1)} $unit';
  double _rangeMs(DateTime t) => t.difference(t0).inMilliseconds.toDouble();
  double _totalMs() => t1.difference(t0).inMilliseconds.toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    if (curve.isEmpty) {
      _drawPlaceholder(canvas, size);
      return;
    }
    // Same margin geometry as the PWA (index.html:886), mT/mB bumped slightly (was 42/26) to
    // give the now-larger grid/axis labels room without crowding the plotted curve.
    const mL = 30.0, mR = 10.0, mT = 46.0, mB = 30.0;
    final plotW = size.width - mL - mR;
    final plotH = size.height - mT - mB;
    final compact = size.width < 330;
    // Y range: pad vmin-2.3 / vmax+0.9 (index.html:888).
    double vmin = curve.first.v, vmax = curve.first.v;
    for (final s in curve) { if (s.v < vmin) vmin = s.v; if (s.v > vmax) vmax = s.v; }
    vmin -= 2.3; vmax += 0.9;
    if (vmax - vmin < 0.5) vmax = vmin + 0.5;
    final base = mT + plotH;
    double x(DateTime t) => mL + _rangeMs(t) / _totalMs() * plotW;
    double y(double v) => mT + (1 - (v - vmin) / (vmax - vmin)) * plotH;

    // 1) Background rounded clip (rx 6 like PWA plotClip).
    final bgRect = Rect.fromLTWH(mL, mT, plotW, plotH);
    final bgRRect = RRect.fromRectAndRadius(bgRect, const Radius.circular(8));
    canvas.save();
    canvas.clipRRect(bgRRect);
    // Fill dark bg gradient
    canvas.drawRect(bgRect, Paint()..shader = const LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [Color(0xFF0B2A44), Color(0xFF061A2D)]).createShader(bgRect));

    // 2) Grid lines every 2 tide units, with a value label on each — the lines existed before
    // but had no numbers alongside them; added per live feedback on the preview (not present
    // in the original design, not just a contrast fix).
    final grid = Paint()..color = const Color(0xFF1D4C6A).withOpacity(.5)..strokeWidth = 0.7;
    final vFirst = (vmin / 2).ceil() * 2.0;
    for (double v = vFirst; v <= vmax; v += 2) {
      final gy = y(v);
      canvas.drawLine(Offset(mL, gy), Offset(mL + plotW, gy), grid);
      _text(canvas, v.round().toString(), Offset(mL - 6, gy), 12, FontWeight.w600,
        const Color(0xFFE3F0FA), center: true);
    }
    // X-ticks every 12 h (12 AM, 12 PM) — draw thin vertical guide.
    var tick = DateTime(t0.year, t0.month, t0.day, t0.hour < 12 ? 0 : 12);
    while (tick.isBefore(t1)) {
      if (!tick.isBefore(t0)) {
        final gx = x(tick);
        canvas.drawLine(Offset(gx, mT), Offset(gx, base), grid);
      }
      tick = tick.add(const Duration(hours: 12));
    }

    // 3) Sunrise/Sunset images at the mean-tide horizon.
    final meanV = curve.fold<double>(0, (a, s) => a + s.v) / curve.length;
    final horizonY = y(meanV);
    void drawSun(ui.Image? img, DateTime t) {
      if (img == null) return;
      if (t.isBefore(t0.add(const Duration(minutes: 3))) || t.isAfter(t1.subtract(const Duration(minutes: 3)))) return;
      final sw = math.min(94.0, plotW * (compact ? .28 : .26));
      final sh = sw * img.height / img.width;
      final xc = x(t);
      // waterline at 80% down (PWA magic wl=0.80)
      final rect = Rect.fromLTWH(xc - sw / 2, horizonY - sh * 0.80, sw, sh);
      // The sun assets' own edge alpha doesn't fully reach 0 right at the bounding box —
      // visible as a faint box behind the icon once composited on the glass card (caught via
      // a live demo, not guessed). Draw into a layer, then knock the edges out with a radial
      // gradient in dstIn so only the center stays, feathering to the card color at the rim.
      canvas.saveLayer(rect, Paint());
      canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        rect, Paint()..color = Colors.white.withOpacity(.95));
      canvas.drawRect(rect, Paint()
        ..shader = ui.Gradient.radial(rect.center, rect.longestSide * .58,
          const [Colors.white, Colors.white, Colors.transparent], const [0, .62, 1])
        ..blendMode = BlendMode.dstIn);
      canvas.restore();
    }
    for (final t in sunrises) { drawSun(sunriseImg, t); }
    for (final t in sunsets) { drawSun(sunsetImg, t); }

    // 4) Ocean band under the horizon.
    if (oceanImg != null) {
      final rect = Rect.fromLTWH(mL, horizonY - 5, plotW, (base - horizonY) + 14);
      // ocean.png fades to transparent at its own left/right edges (measured: solid from
      // x≈80 to x≈680 of 760px) — stretching the whole image left that fade visible mid-band
      // once drawn full-width. Crop to the solid center slice instead (same asset, same
      // stretch, just not the fading parts of it).
      final srcW = oceanImg!.width.toDouble();
      final cropL = srcW * (80 / 760), cropR = srcW * (680 / 760);
      canvas.drawImageRect(oceanImg!,
        Rect.fromLTWH(cropL, 0, cropR - cropL, oceanImg!.height.toDouble()),
        rect, Paint()..color = Colors.white.withOpacity(.8));
    }

    // 5) Tide fill path (blue gradient).
    final fillPath = ui.Path()..moveTo(x(curve.first.t), base);
    for (final s in curve) { fillPath.lineTo(x(s.t), y(s.v)); }
    fillPath.lineTo(x(curve.last.t), base);
    fillPath.close();
    canvas.drawPath(fillPath, Paint()..shader = LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [const Color(0x5933B8FF), const Color(0x291476A8), const Color(0x0506273F)],
      stops: const [0, .55, 1]).createShader(bgRect));

    // 6) Tide curve — cyan with a soft glow (draw twice, second thicker/blurred).
    final curvePath = ui.Path()..moveTo(x(curve.first.t), y(curve.first.v));
    for (int i = 1; i < curve.length; i++) { curvePath.lineTo(x(curve[i].t), y(curve[i].v)); }
    final glow = Paint()..color = const Color(0xFF2DB7FF).withOpacity(.55)
      ..style = PaintingStyle.stroke..strokeWidth = 6
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawPath(curvePath, glow);
    canvas.drawPath(curvePath, Paint()..color = const Color(0xFF2DB7FF)
      ..style = PaintingStyle.stroke..strokeWidth = 3.2..strokeCap = StrokeCap.round);

    canvas.restore();   // end clipRRect

    // 7) Hi/Lo dots + labels (unclipped so labels can peek above).
    double? lastLx;
    for (final p in hilo) {
      if (p.t.isBefore(t0) || p.t.isAfter(t1)) continue;
      final px = x(p.t), py = y(p.v);
      final isH = p.type == 'H';
      final color = isH ? const Color(0xFF23DD67) : const Color(0xFFFF514F);
      canvas.drawCircle(Offset(px, py), 5.5, Paint()..color = color);
      canvas.drawCircle(Offset(px, py), 5.5,
        Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.6);
      // The four events remain visible as dots regardless; inline labels only draw when they
      // fit without colliding — the full detail for every event (including ones skipped here)
      // still reaches the user via the hi/lo cards row below the chart, real Flutter widgets
      // that wrap/scale normally rather than fighting a fixed canvas size. The gap required to
      // show a label scales with textScale too, since the label itself grows with it — at
      // 200% scale, fewer inline labels fit and more fall through to that cards row, which is
      // exactly the "move details to a panel when space is limited" degradation, not a bug.
      final minGap = (compact ? 88.0 : 74.0) * textScale;
      if (lastLx == null || (px - lastLx).abs() >= minGap) {
        _text(canvas, _fv(p.v), Offset(px, py - 25), compact ? 11 : 13,
          FontWeight.w700, color, center: true);
        _text(canvas, _fmtTime(p.t), Offset(px, py + 14), compact ? 10 : 12,
          FontWeight.w600, const Color(0xFFBBD6EC), center: true);
        lastLx = px;
      }
    }

    // 8) Now indicator — dashed vertical + circle + pill (only if now is inside window).
    if (!now.isBefore(t0) && !now.isAfter(t1)) {
      final nx = x(now).clamp(mL + 8, mL + plotW - 8);
      // find sample nearest now
      _TideSample nearest = curve.first;
      var bestDt = curve.first.t.difference(now).abs();
      for (final s in curve) {
        final dt = s.t.difference(now).abs();
        if (dt < bestDt) { bestDt = dt; nearest = s; }
      }
      final ny = y(nearest.v);
      // dashed vertical line
      final dash = Paint()..color = const Color(0xFFD7EFFF).withOpacity(.7)..strokeWidth = 1;
      double yD = ny;
      while (yD < base) {
        canvas.drawLine(Offset(nx.toDouble(), yD), Offset(nx.toDouble(), math.min(yD + 4, base)), dash);
        yD += 8;
      }
      // circle on the curve
      canvas.drawCircle(Offset(nx.toDouble(), ny), 6, Paint()..color = const Color(0xFF146DD7));
      canvas.drawCircle(Offset(nx.toDouble(), ny), 6,
        Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.6);
      // pill above the circle — sized to the actual measured text instead of a fixed guess
      // (that guess was tuned for the old smaller fonts; at bigger sizes/200% text scale the
      // value text was wider than the hardcoded 52-66px pill and drew outside it uncontained).
      const nowSize = 10.0, valSize = 12.5;
      final valueStr = _fv(nearest.v);
      final nowW = _measureWidth('Now', nowSize, FontWeight.w700);
      final valW = _measureWidth(valueStr, valSize, FontWeight.w800);
      final pillW = math.max(nowW, valW) + 20;
      final pillH = (nowSize + valSize) * textScale + 18;
      final tipX = nx.clamp(mL + pillW / 2, mL + plotW - pillW / 2).toDouble();
      // tipY is the pill's vertical CENTER; the bottom edge (tipY + pillH/2) should sit a
      // fixed gap above the dot on the curve (ny).
      final tipY = math.max<double>(mT + pillH / 2 + 2, ny - 8 - pillH / 2);
      final pillRect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(tipX, tipY), width: pillW, height: pillH),
        const Radius.circular(9));
      canvas.drawRRect(pillRect, Paint()..color = const Color(0xFF1271E7));
      canvas.drawRRect(pillRect, Paint()..color = const Color(0xFF58A7FF)
        ..style = PaintingStyle.stroke..strokeWidth = 1.2);
      _text(canvas, 'Now', Offset(tipX, tipY - pillH * .22), nowSize, FontWeight.w700, Colors.white, center: true);
      _text(canvas, valueStr, Offset(tipX, tipY + pillH * .22), valSize, FontWeight.w800, Colors.white, center: true);
    }

    // 9) Y-axis label and x-tick times.
    _text(canvas, 'Tide Height ($unit)', Offset(mL - 22, mT + plotH / 2), 11, FontWeight.w600, const Color(0xFFCFE3F2), center: true, rotate: -math.pi / 2);
    var tt = DateTime(t0.year, t0.month, t0.day, t0.hour < 12 ? 0 : 12);
    double? lastTickX;
    // Spacing requirement scales with textScale for the same reason the hi/lo gap above does —
    // a bigger label needs more room before the next one would collide with it.
    final tickGap = 54.0 * textScale;
    while (tt.isBefore(t1)) {
      if (!tt.isBefore(t0)) {
        final gx = x(tt);
        if (lastTickX == null || gx - lastTickX >= tickGap) {
          _text(canvas, tt.hour == 0 ? '12 AM' : '${tt.hour == 12 ? 12 : tt.hour % 12} ${tt.hour < 12 ? "AM" : "PM"}',
            Offset(gx, base + 14), 11.5, FontWeight.w600, const Color(0xFFBBD6EC), center: true);
          lastTickX = gx;
        }
      }
      tt = tt.add(const Duration(hours: 12));
    }
  }

  // Every font size passed through here is a base (100%-scale) value — multiplying by
  // textScale here, in one place, is what makes canvas-drawn chart text actually respect the
  // system text-scale setting the way an ordinary Text widget does for free.
  void _text(Canvas canvas, String text, Offset at, double size, FontWeight w, Color c,
      {bool center = false, double rotate = 0}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: c, fontSize: size * textScale, fontWeight: w)),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(at.dx, at.dy);
    if (rotate != 0) canvas.rotate(rotate);
    tp.paint(canvas, center ? Offset(-tp.width / 2, -tp.height / 2) : Offset.zero);
    canvas.restore();
  }

  double _measureWidth(String text, double size, FontWeight w) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontSize: size * textScale, fontWeight: w)),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  void _drawPlaceholder(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(text: 'Loading tide predictions…',
        style: TextStyle(color: const Color(0xFFBBD6EC), fontSize: 13 * textScale)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
  }

  @override
  bool shouldRepaint(covariant _TidePainter old) => old.curve != curve || old.now != now
    || old.sunrises.length != sunrises.length || old.sunsets.length != sunsets.length
    || old.unit != unit || old.sunriseImg != sunriseImg || old.sunsetImg != sunsetImg || old.oceanImg != oceanImg
    || old.textScale != textScale;
}

// ==================================================================================================
// helpers
// ==================================================================================================

class _TrailPoint {
  final LatLng p;
  final int tMs;
  _TrailPoint(this.p, this.tMs);
}

// Approximates a circle of `radiusM` around `center` as a closed loop of lat/lng points, so a
// dashed Polyline can draw a dashed ring — flutter_map's CircleMarker has no dash support.
List<LatLng> _circlePoints(LatLng center, double radiusM, {int steps = 72}) {
  const earthR = 6371000.0;
  final latRad = center.latitude * math.pi / 180;
  final points = <LatLng>[];
  for (int i = 0; i <= steps; i++) {
    final angle = (i / steps) * 2 * math.pi;
    final dLat = (radiusM * math.cos(angle)) / earthR;
    final dLng = (radiusM * math.sin(angle)) / (earthR * math.cos(latRad));
    points.add(LatLng(center.latitude + dLat * 180 / math.pi, center.longitude + dLng * 180 / math.pi));
  }
  return points;
}

double _bearingDeg(LatLng a, LatLng b) {
  final la1 = a.latitude * math.pi / 180;
  final la2 = b.latitude * math.pi / 180;
  final dlo = (b.longitude - a.longitude) * math.pi / 180;
  final y = math.sin(dlo) * math.cos(la2);
  final x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(dlo);
  final brg = math.atan2(y, x) * 180 / math.pi;
  return (brg + 360) % 360;
}

const _dirs = ['N','NNE','NE','ENE','E','ESE','SE','SSE','S','SSW','SW','WSW','W','WNW','NW','NNW'];
String _dirName(double deg) => _dirs[((deg % 360) / 22.5).round() % 16];
