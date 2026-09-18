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
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() => runApp(const BaysideApp());

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
          textTheme: const TextTheme(
            bodyMedium: TextStyle(color: Colors.white),
            labelMedium: TextStyle(color: Color(0xCCFFFFFF)),
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
String _tileUrl(Basemap b) {
  switch (b) {
    case Basemap.map:   return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}';
    case Basemap.chart: return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    case Basemap.sat:   return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
    case Basemap.dark:  return 'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png';
  }
}
const _noaaChartUrl = 'https://gis.charttools.noaa.gov/arcgis/rest/services/MarineChart_Services/NOAACharts/MapServer/tile/{z}/{y}/{x}';

// ==================================================================================================
// weather
// ==================================================================================================

class Weather {
  final double? tempF, windKt, gustKt;
  final int? windDirDeg, weatherCode;
  // Batch A.5 additions (matches PWA #now grid + tideStrip)
  final double? waveFt, wavePeriodS, waterTempF, precipPct;
  final DateTime? sunset, sunrise;
  const Weather({this.tempF, this.windKt, this.gustKt, this.windDirDeg, this.weatherCode,
    this.waveFt, this.wavePeriodS, this.waterTempF, this.precipPct, this.sunset, this.sunrise});
}

Future<Weather?> fetchWeather(LatLng at) async {
  // three endpoints in parallel: current wx, daily sun times, marine wave/water
  final wxUrl = Uri.parse('https://api.open-meteo.com/v1/forecast?latitude=${at.latitude}&longitude=${at.longitude}'
      '&temperature_unit=fahrenheit&wind_speed_unit=kn&timezone=auto'
      '&current=temperature_2m,wind_speed_10m,wind_gusts_10m,wind_direction_10m,weather_code,precipitation'
      '&daily=sunrise,sunset&forecast_days=1');
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
    DateTime? sr, ss;
    final d = wj['daily'] as Map<String, dynamic>?;
    if (d != null) {
      final sT = (d['sunrise'] as List?)?.cast<String>();
      final ssT = (d['sunset'] as List?)?.cast<String>();
      if (sT != null && sT.isNotEmpty) sr = DateTime.tryParse(sT[0]);
      if (ssT != null && ssT.isNotEmpty) ss = DateTime.tryParse(ssT[0]);
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
        '&forecast_days=3');
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
  BoatProfile({this.name = '', this.lengthFt, this.type = BoatType.bowrider,
    this.cruise = 24.0, this.wind = 13.0, this.gust = 19.0, this.wave = 1.8,
    this.burn = 0.0, this.tank = 0.0});
  Map<String, dynamic> toJson() => {
    'name': name, 'lengthFt': lengthFt, 'type': type.name,
    'cruise': cruise, 'wind': wind, 'gust': gust, 'wave': wave, 'burn': burn, 'tank': tank,
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
  );
  static Future<BoatProfile> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final s = sp.getString('boatProfile');
      if (s == null) return BoatProfile();
      return fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) { return BoatProfile(); }
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

class _MapScreenState extends State<MapScreen> {
  final MapController _controller = MapController();
  StreamSubscription<Position>? _gpsSub;

  Basemap _base = Basemap.map;
  LatLng? _me;
  double _heading = 0;
  double _speedKt = 0;
  double? _accuracyM;
  bool _follow = true;
  bool _picking = false;
  bool _smart = true;    // smart-routes toggle (default ON in Flutter build — the pre-baked data is bundled)
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
  TideStation? _tideStation;
  List<TidePoint> _tides = [];
  List<DailyForecast> _daily = [];
  List<HourlyPoint> _hourly = [];   // Batch A.5: drives "Best time to boat" table + best window pill

  LatLng? _mobPoint;
  LatLng? _anchorPoint;
  double _anchorRadiusFt = 100;
  bool _anchorBreached = false;
  bool _fuelRingOn = false;

  static const _homeCenter = LatLng(40.457, -74.15);

  @override
  void initState() {
    super.initState();
    _loadLand();
    _loadLastPos().then((p) {
      final at = p ?? _homeCenter;
      _refreshWeather(at);
      _refreshAlerts(at);
      _refreshDaily(at);
      _refreshHourly(at);
      _refreshTides(at);
      if (p != null && mounted) {
        // Nudge the map to the last-known area so the user sees home water on load.
        // FlutterMap's controller isn't valid until the widget builds, so schedule for after.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try { _controller.move(p, 12); } catch (_) {}
        });
      }
    });
    BoatProfile.load().then((p) { if (mounted) setState(() => _profile = p); });
    _wxTimer = Timer.periodic(const Duration(minutes: 20), (_) {
      final at = _me ?? _homeCenter;
      _refreshWeather(at);
      _refreshAlerts(at);
      _refreshDaily(at);
      _refreshHourly(at);
      _refreshTides(at);
      _wxAt.clear();   // let stale grades fall through and refresh
      _gradeRouteWaypoints();
    });
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
  // the anchor waypoints, interpolating between them — same trick the PWA uses in renderRoute.
  List<Polyline> _gradedRouteSegments(List<LatLng> pts) {
    final out = <Polyline>[];
    const N = 14;
    for (int i = 0; i < pts.length - 1; i++) {
      final a = pts[i], b = pts[i + 1];
      final la = _gLevel(_gradeAt(a));
      final lb = _gLevel(_gradeAt(b));
      for (int k = 0; k < N; k++) {
        final t0 = k / N, t1 = (k + 1) / N;
        final p0 = LatLng(a.latitude + (b.latitude - a.latitude) * t0, a.longitude + (b.longitude - a.longitude) * t0);
        final p1 = LatLng(a.latitude + (b.latitude - a.latitude) * t1, a.longitude + (b.longitude - a.longitude) * t1);
        out.add(Polyline(points: [p0, p1], color: _gInterpolate(la, lb, (t0 + t1) / 2), strokeWidth: 4,
            pattern: StrokePattern.dashed(segments: const [10, 8])));
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

  @override
  void dispose() {
    _gpsSub?.cancel();
    _wxTimer?.cancel();
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
    if (_follow) {
      _controller.move(here, math.max(_controller.camera.zoom, _navigating ? 16 : 14));
      if (_navigating) _controller.rotate(-h);   // rotate so heading is up
    }
  }

  // ---------- MOB / anchor / fuel ring ----------
  void _toggleMob() {
    setState(() {
      if (_mobPoint != null) { _mobPoint = null; return; }
      _mobPoint = _me ?? _homeCenter;
    });
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
  // human sentence saying so — matches the PWA's boatwarn.
  String? _boatWarning() {
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
    if (over.isNotEmpty) return 'Too rough for $who right now: ${over.join(", ")}';
    if (near.isNotEmpty) return "Near $who's limit: ${near.join(", ")}";
    return null;
  }

  Future<void> _openForecast() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ForecastSheet(daily: _daily, tides: _tides, tideStation: _tideStation),
    );
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
      builder: (ctx) => MoreToolsSheet(
        docksOn: false,   // Batch B.5 overlay lands with real data
        navAidsOn: false, // Batch B.5 overlay lands with real data
        anchorOn: _anchorPoint != null,
        fuelOn: _fuelRingOn,
        smartOn: _smart,
        onToggleDocks: (_) => _stubOverlayToast('Docks & fuel'),
        onToggleNavAids: (_) => _stubOverlayToast('Nav aids'),
        onToggleAnchor: (_) { Navigator.of(ctx).pop(); _toggleAnchor(); },
        onToggleFuel: (_) { Navigator.of(ctx).pop(); _toggleFuelRing(); },
        onToggleSmart: (_) { Navigator.of(ctx).pop(); setState(() => _smart = !_smart); _recomputeRoute(); },
        onOpenForecast: () { Navigator.of(ctx).pop(); _openForecast(); },
      ),
    );
  }
  void _stubOverlayToast(String name) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$name overlay lands in Batch B.5'),
      duration: const Duration(seconds: 2),
    ));
  }

  void _handleMapTap(TapPosition _, LatLng ll) {
    if (!_picking) return;
    setState(() => _waypoints.add(ll));
    _recomputeRoute();
    _gradeRouteWaypoints();   // fetch a per-point forecast in the background so segments colour up
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
    final pts = _routedPath ?? [
      if (_me != null) _me!,
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
    if (_me != null) _controller.move(_me!, math.max(_controller.camera.zoom, 16));
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
    setState(() => _navigating = false);
    try { await WakelockPlus.disable(); } catch (_) {}
    _controller.rotate(0);   // back to north-up
  }

  @override
  Widget build(BuildContext context) {
    final routeLine = _routedPath ?? <LatLng>[
      if (_me != null) _me!,
      ..._waypoints,
    ];
    final tiltMatrix = Matrix4.identity()
      ..setEntry(3, 2, 0.001)
      ..rotateX(_navigating ? 0.785398 : 0.0);   // 45 deg
    return Scaffold(
      body: SafeArea(
        child: Stack(children: [
          // The map itself, wrapped in a Transform that tilts to ~45° during active nav (matches the
          // PWA's `body.nav-active #map { transform: perspective... rotateX(45deg) }` trick — Flutter
          // widgets support the same perspective/rotate math via Matrix4).
          AnimatedContainer(
            duration: const Duration(milliseconds: 700),
            curve: Curves.easeInOut,
            transformAlignment: const Alignment(0, 0.2),
            transform: tiltMatrix,
            child: FlutterMap(
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
                TileLayer(urlTemplate: _tileUrl(_base), userAgentPackageName: 'net.bayside.flutter'),
                if (_base == Basemap.chart)
                  TileLayer(urlTemplate: _noaaChartUrl, userAgentPackageName: 'net.bayside.flutter'),
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
                    CircleMarker(
                      point: _anchorPoint!,
                      radius: _anchorRadiusFt * 0.3048,
                      useRadiusInMeter: true,
                      color: _anchorBreached ? const Color(0x33D93A2B) : const Color(0x1A2E6F9E),
                      borderColor: _anchorBreached ? const Color(0xFFD93A2B) : const Color(0xFF2E6F9E),
                      borderStrokeWidth: 2,
                    ),
                ]),
                // MOB dashed line back from boat to the pin
                if (_mobPoint != null && _me != null)
                  PolylineLayer(polylines: [
                    Polyline(points: [_me!, _mobPoint!], color: const Color(0xFFD93A2B), strokeWidth: 3,
                        pattern: StrokePattern.dashed(segments: const [6, 6])),
                  ]),
                MarkerLayer(markers: [
                  for (int i = 0; i < _waypoints.length; i++)
                    Marker(
                      point: _waypoints[i],
                      width: 32, height: 32,
                      child: _WaypointPin(isDest: i == _waypoints.length - 1),
                    ),
                  if (_mobPoint != null)
                    Marker(
                      point: _mobPoint!,
                      width: 40, height: 40,
                      child: const _MobPin(),
                    ),
                  if (_anchorPoint != null)
                    Marker(
                      point: _anchorPoint!,
                      width: 20, height: 20,
                      child: const Icon(Icons.anchor, color: Color(0xFF2E6F9E), size: 20),
                    ),
                  if (_me != null)
                    Marker(
                      point: _me!,
                      width: 44, height: 44,
                      child: BoatMarker(headingDeg: _heading, active: _navigating),
                    ),
                ]),
              ],
            ),
          ),
          // HUD (never tilts — always flat)
          Positioned(top: 12, left: 12, right: 12, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _TopHud(
              speedKt: _speedKt, status: _statusText, accuracyM: _accuracyM,
              base: _base, onBaseChange: (b) => setState(() => _base = b),
              boatName: _profile.name.isEmpty ? 'Set up your boat' : _profile.name,
              onEditBoat: _openBoatProfile,
            ),
            if (_alert != null) ...[
              const SizedBox(height: 8),
              _AlertBanner(alert: _alert!, onDismiss: () => setState(() => _alert = null)),
            ],
            if (_boatWarning() != null) ...[
              const SizedBox(height: 8),
              _BoatWarningBanner(text: _boatWarning()!),
            ],
            if (_mobPoint != null && _me != null) ...[
              const SizedBox(height: 8),
              _MobHud(from: _me!, to: _mobPoint!, onClear: _toggleMob),
            ],
            if (_anchorPoint != null && _me != null) ...[
              const SizedBox(height: 8),
              _AnchorHud(from: _me!, to: _anchorPoint!, radiusFt: _anchorRadiusFt, breached: _anchorBreached,
                onPlus: () => _bumpAnchor(25), onMinus: () => _bumpAnchor(-25), onStop: _toggleAnchor),
            ],
            if (_navigating && _waypoints.isNotEmpty && _legIdx < _waypoints.length && _me != null) ...[
              const SizedBox(height: 8),
              _NavBar(from: _me!, target: _waypoints[_legIdx], legIdx: _legIdx, totalWps: _waypoints.length,
                  nmToFinal: _routeNm(), etaMin: _etaMin(), headingDeg: _heading,
                  cruiseKt: _profile.cruise, gal: _fuelGal(), onDone: _stopRide),
            ],
          ])),
          Positioned(right: 12, bottom: 140, child: _RightRail(
            follow: _follow, picking: _picking, gpsOn: _gpsSub != null,
            mobOn: _mobPoint != null,
            onFollow: () => setState(() {
              _follow = !_follow;
              if (_follow && _me != null) _controller.move(_me!, math.max(_controller.camera.zoom, 14));
            }),
            onGoto: () => setState(() { _picking = !_picking; }),
            onLocate: _startGps,
            onMob: _toggleMob,
            onMoreTools: _openMoreTools,
          )),
          Positioned(left: 12, right: 12, bottom: 12, child: _BottomSheet(
            weather: _weather, routeNm: _routeNm(), etaMin: _etaMin(), fuelGal: _fuelGal(),
            waypointCount: _waypoints.length, picking: _picking,
            unverified: _routeUnverified, navigating: _navigating,
            onClearRoute: () async { setState(() { _waypoints.clear(); _picking = false; _routedPath = null; _legIdx = 0; }); await _stopRide(); },
            onUndoRoute: () { if (_waypoints.isEmpty) return; setState(() { _waypoints.removeLast(); if (_legIdx >= _waypoints.length) _legIdx = math.max(0, _waypoints.length - 1); }); _recomputeRoute(); },
            onStart: _startRide, onStop: _stopRide,
            onGpx: _gpxPlaceholder, onEditProfile: _openBoatProfile,
            warningText: _boatWarning(), window: bestWindow(_hourly, _profile),
            hourly: _hourly, daily: _daily, profile: _profile,
          )),
        ]),
      ),
    );
  }
}

// ==================================================================================================
// widgets
// ==================================================================================================

class BoatMarker extends StatelessWidget {
  final double headingDeg;
  final bool active;
  const BoatMarker({super.key, required this.headingDeg, this.active = false});
  @override
  Widget build(BuildContext context) => Transform.rotate(
        angle: headingDeg * math.pi / 180,
        child: SizedBox(
          width: 44, height: 44,
          child: Stack(alignment: Alignment.center, children: [
            // classic top-down skiff (always there, fades OUT during Start ride)
            AnimatedOpacity(
              opacity: active ? 0 : 1,
              duration: const Duration(milliseconds: 500),
              child: Image.asset('assets/icons/boat.png', fit: BoxFit.contain),
            ),
            // photo-real orange RIB (fades IN during Start ride) — matches the PWA's boat crossfade
            AnimatedOpacity(
              opacity: active ? 1 : 0,
              duration: const Duration(milliseconds: 500),
              child: Image.asset('assets/icons/boat-3d.png', fit: BoxFit.contain),
            ),
          ]),
        ),
      );
}

// Small floating bar shown while navigating — mirrors the PWA's #nav ("steer XXX° · point N of M ·
// to final N.N nm"). Sits just below the top HUD.
class _NavBar extends StatelessWidget {
  final LatLng from;
  final LatLng target;
  final int legIdx;
  final int totalWps;
  final double nmToFinal;
  final int etaMin;
  final double headingDeg;
  final double cruiseKt;
  final double gal;
  final VoidCallback onDone;
  const _NavBar({required this.from, required this.target, required this.legIdx, required this.totalWps,
      required this.nmToFinal, required this.etaMin, required this.headingDeg,
      required this.cruiseKt, required this.gal, required this.onDone});
  @override
  Widget build(BuildContext context) {
    final brg = _bearingDeg(from, target);
    final dm = _haversineM(from, target);
    final distStr = dm < 370 ? '${(dm * 3.28).round()} ft' : '${(dm/1852).toStringAsFixed(dm/1852<10?2:1)} nm';
    final galStr = gal < 10 ? '${gal.toStringAsFixed(1)} gal' : '${gal.round()} gal';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: const Color(0xE60F2A44), borderRadius: BorderRadius.circular(12)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Transform.rotate(
            angle: (brg - headingDeg) * math.pi / 180,
            child: const Icon(Icons.navigation, color: Color(0xFFF2A93B), size: 26),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(distStr, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white, height: 1)),
            const SizedBox(height: 2),
            Text('steer ${brg.round().toString().padLeft(3, '0')}° ${_dirName(brg)} · point ${legIdx+1} of $totalWps',
                style: const TextStyle(fontSize: 11, color: Color(0xCCFFFFFF))),
          ]),
          const SizedBox(width: 16),
          Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
            Text(etaMin >= 60 ? '${etaMin ~/ 60}h ${etaMin % 60}m' : '${math.max(1, etaMin)} min',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white, height: 1)),
            const SizedBox(height: 2),
            Text('${nmToFinal.toStringAsFixed(1)} nm to final', style: const TextStyle(fontSize: 11, color: Color(0xCCFFFFFF))),
          ]),
          const SizedBox(width: 10),
          Material(color: const Color(0x33FFFFFF), borderRadius: BorderRadius.circular(9),
            child: InkWell(borderRadius: BorderRadius.circular(9), onTap: onDone,
              child: const Padding(padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: Text('Done', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13))))),
        ]),
        const SizedBox(height: 4),
        Text('at ${cruiseKt.round()} kn cruise · ~$galStr',
          style: const TextStyle(fontSize: 11, color: Color(0xAAFFFFFF), fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _WaypointPin extends StatelessWidget {
  final bool isDest;
  const _WaypointPin({required this.isDest});
  @override
  Widget build(BuildContext context) => Icon(
        Icons.location_on,
        size: isDest ? 32 : 26,
        color: isDest ? const Color(0xFFD93A2B) : const Color(0xFFF2A93B),
        shadows: const [Shadow(color: Colors.black45, blurRadius: 4)],
      );
}

class _TopHud extends StatelessWidget {
  final double speedKt;
  final String status;
  final double? accuracyM;
  final Basemap base;
  final ValueChanged<Basemap> onBaseChange;
  final String boatName;
  final VoidCallback onEditBoat;
  const _TopHud({required this.speedKt, required this.status, required this.accuracyM, required this.base,
      required this.onBaseChange, required this.boatName, required this.onEditBoat});
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: const Color(0xE60F2A44), borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(speedKt.toStringAsFixed(1), style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700, height: 1)),
                const SizedBox(width: 4),
                const Text('kn', style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 12)),
              ]),
              const SizedBox(height: 2),
              Text(status, style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 10),
          Flexible(child: _BoatChip(name: boatName, onTap: onEditBoat)),
          const Spacer(),
          _BaseSwitcher(base: base, onChange: onBaseChange),
        ]),
      ]);
}

class _BoatChip extends StatelessWidget {
  final String name;
  final VoidCallback onTap;
  const _BoatChip({required this.name, required this.onTap});
  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xE60F2A44), borderRadius: BorderRadius.circular(12),
    child: InkWell(borderRadius: BorderRadius.circular(12), onTap: onTap,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.directions_boat, color: Color(0xFFF2A93B), size: 18),
          const SizedBox(width: 6),
          Flexible(child: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13))),
          const SizedBox(width: 6),
          const Icon(Icons.edit, color: Color(0xCCFFFFFF), size: 14),
        ]),
      ),
    ),
  );
}

class _BaseSwitcher extends StatelessWidget {
  final Basemap base;
  final ValueChanged<Basemap> onChange;
  const _BaseSwitcher({required this.base, required this.onChange});
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: const Color(0xE6F4F8FA), borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.all(3),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final b in Basemap.values) _basemapButton(b),
        ]),
      );
  Widget _basemapButton(Basemap b) {
    final selected = b == base;
    return GestureDetector(
      onTap: () => onChange(b),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 1),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: selected ? const Color(0xFF0F2A44) : Colors.transparent, borderRadius: BorderRadius.circular(9)),
        child: Text(_basemapNames[b]!, style: TextStyle(color: selected ? Colors.white : const Color(0xFF2E6F9E), fontWeight: FontWeight.w700, fontSize: 13)),
      ),
    );
  }
}

// Batch A.5: right rail now matches the PWA — Follow / Go-to / Locate / ⋯ More-tools / MOB.
// The four ad-hoc singleton buttons for fuel/anchor/forecast/smart moved into `_MoreToolsSheet`.
class _RightRail extends StatelessWidget {
  final bool follow, picking, gpsOn, mobOn;
  final VoidCallback onFollow, onGoto, onLocate, onMob, onMoreTools;
  const _RightRail({required this.follow, required this.picking, required this.gpsOn, required this.mobOn,
    required this.onFollow, required this.onGoto, required this.onLocate, required this.onMob,
    required this.onMoreTools});
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
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
  Widget _btn({required IconData icon, required bool active, required VoidCallback onTap, required String tip}) => Material(
        color: active ? const Color(0xFF2E6F9E) : const Color(0xFFF4F8FA),
        shape: const CircleBorder(),
        elevation: 3,
        child: Tooltip(
          message: tip,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 46, height: 46, child: Icon(icon, color: active ? Colors.white : const Color(0xFF2E6F9E))),
          ),
        ),
      );
  Widget _mobButton() => Material(
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
      );
}

// Batch A.5: bottom-sheet popover with 5 toggles — matches the PWA's More tools sheet.
// Anchor / Fuel / Smart routes are the real toggles wired to state. Docks & fuel and Nav aids
// are stubs until Batch B.5 lands the overlays.
class MoreToolsSheet extends StatelessWidget {
  final bool docksOn, navAidsOn, anchorOn, fuelOn, smartOn;
  final ValueChanged<bool> onToggleDocks, onToggleNavAids, onToggleAnchor, onToggleFuel, onToggleSmart;
  final VoidCallback onOpenForecast;
  const MoreToolsSheet({super.key,
    required this.docksOn, required this.navAidsOn, required this.anchorOn, required this.fuelOn, required this.smartOn,
    required this.onToggleDocks, required this.onToggleNavAids, required this.onToggleAnchor, required this.onToggleFuel, required this.onToggleSmart,
    required this.onOpenForecast});
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
        _row(Icons.anchor, 'Docks & fuel', 'Marinas, ramps & fuel docks nearby (20 mi)', docksOn, onToggleDocks),
        _row(Icons.center_focus_strong, 'Anchor watch', 'Alarm if you drift off the hook', anchorOn, onToggleAnchor),
        _row(Icons.local_gas_station, 'Fuel range', 'Half-range ring from your tank & burn rate', fuelOn, onToggleFuel),
        _row(Icons.location_on, 'Nav aids', 'Channel buoys & beacons nearby (20 mi)', navAidsOn, onToggleNavAids),
        _row(Icons.route, 'Smart routes', 'Bend routes around land (experimental)', smartOn, onToggleSmart),
        const Divider(color: Color(0xFFDDE4EA), height: 24),
        Material(color: const Color(0xFFF4F8FA), borderRadius: BorderRadius.circular(10),
          child: InkWell(borderRadius: BorderRadius.circular(10), onTap: onOpenForecast,
            child: const Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Icon(Icons.cloud_outlined, color: Color(0xFF2E6F9E)),
                SizedBox(width: 8),
                Text('7-day forecast & tides',
                  style: TextStyle(color: Color(0xFF0F2A44), fontWeight: FontWeight.w800, fontSize: 14)),
              ])))),
      ]),
    ));
  }
  Widget _row(IconData icon, String title, String sub, bool on, ValueChanged<bool> onTap) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(children: [
      Container(width: 42, height: 42,
        decoration: BoxDecoration(color: const Color(0xFFF0F5F9), shape: BoxShape.circle),
        child: Icon(icon, color: const Color(0xFF2E6F9E))),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Color(0xFF0F2A44), fontWeight: FontWeight.w800, fontSize: 15)),
        Text(sub, style: const TextStyle(color: Color(0xFF708597), fontSize: 12)),
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
  void initState() { super.initState(); p = BoatProfile.fromJson(widget.initial.toJson()); }
  TextEditingController _num(double v) => TextEditingController(text: v == 0 ? '' : v.toString());
  Widget _field(String label, double value, ValueChanged<double> onChange, {String suffix = ''}) => TextField(
    controller: _num(value),
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    style: const TextStyle(color: Colors.white),
    decoration: InputDecoration(
      labelText: label, labelStyle: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12),
      suffixText: suffix, suffixStyle: const TextStyle(color: Color(0xAAFFFFFF)),
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0x55FFFFFF))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0x33FFFFFF))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF2E6F9E), width: 2)),
    ),
    onChanged: (s) { final d = double.tryParse(s); if (d != null) onChange(d); },
  );
  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    initialChildSize: 0.75, minChildSize: 0.4, maxChildSize: 0.95, expand: false,
    builder: (ctx, scroll) => Container(
      decoration: const BoxDecoration(color: Color(0xFF0F2A44), borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: ListView(controller: scroll, children: [
        Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(color: const Color(0x66FFFFFF), borderRadius: BorderRadius.circular(2)))),
        const Text('Your boat', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('Bayside grades forecasts against these limits and computes fuel from tank & burn rate.',
            style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 12)),
        const SizedBox(height: 16),
        TextField(
          controller: TextEditingController(text: p.name),
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: 'Boat name', labelStyle: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0x55FFFFFF))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0x33FFFFFF))),
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
            dropdownColor: const Color(0xFF0F2A44),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Type', labelStyle: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0x55FFFFFF))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0x33FFFFFF))),
            ),
            items: BoatType.values.map((t) => DropdownMenuItem(value: t, child: Text(_typeNames[t]!))).toList(),
            onChanged: (v) { if (v != null) setState(() => p.type = v); },
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _field('Cruise (kn)', p.cruise, (v) => setState(() => p.cruise = v), suffix: 'kn')),
          const SizedBox(width: 12),
          Expanded(child: Material(color: const Color(0xFF2E6F9E), borderRadius: BorderRadius.circular(8),
            child: InkWell(borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => p.applyTypeDefaults(p.type)),
              child: const Padding(padding: EdgeInsets.symmetric(vertical: 14),
                child: Center(child: Text('Use defaults for type', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)))),
            ),
          )),
        ]),
        const SizedBox(height: 20),
        const Text('Comfort limits — Bayside warns when forecasts exceed these',
            style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _field('Max wind', p.wind, (v) => setState(() => p.wind = v), suffix: 'kn')),
          const SizedBox(width: 12),
          Expanded(child: _field('Max gust', p.gust, (v) => setState(() => p.gust = v), suffix: 'kn')),
          const SizedBox(width: 12),
          Expanded(child: _field('Max wave', p.wave, (v) => setState(() => p.wave = v), suffix: 'ft')),
        ]),
        const SizedBox(height: 20),
        const Text('Fuel — for the range ring & route fuel estimate',
            style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _field('Burn @ cruise', p.burn, (v) => setState(() => p.burn = v), suffix: 'gal/h')),
          const SizedBox(width: 12),
          Expanded(child: _field('Tank size', p.tank, (v) => setState(() => p.tank = v), suffix: 'gal')),
        ]),
        const SizedBox(height: 24),
        Material(color: const Color(0xFF1F8A5B), borderRadius: BorderRadius.circular(10),
          child: InkWell(borderRadius: BorderRadius.circular(10),
            onTap: () async { await widget.onSave(p); if (context.mounted) Navigator.of(context).pop(); },
            child: const Padding(padding: EdgeInsets.symmetric(vertical: 14),
              child: Center(child: Text('Save', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)))),
          ),
        ),
        const SizedBox(height: 12),
      ]),
    ),
  );
}

// Batch A.5: rewrite as a stateful sheet that hosts the "Set up your boat" content
// (weather block + best-window pill + day tabs + hourly "Best time to boat" table) plus
// the pinned route summary row. Kept as a single widget so the callsite doesn't move.
class _BottomSheet extends StatefulWidget {
  final Weather? weather;
  final double routeNm;
  final int etaMin, waypointCount;
  final double fuelGal;
  final bool picking, unverified, navigating;
  final VoidCallback onClearRoute, onUndoRoute, onStart, onStop, onGpx, onEditProfile;
  final String? warningText;
  final BestWindow? window;
  final List<HourlyPoint> hourly;
  final List<DailyForecast> daily;
  final BoatProfile profile;
  const _BottomSheet({required this.weather, required this.routeNm, required this.etaMin, required this.fuelGal,
    required this.waypointCount, required this.picking, required this.unverified, required this.navigating,
    required this.onClearRoute, required this.onUndoRoute, required this.onStart, required this.onStop,
    required this.onGpx, required this.onEditProfile,
    required this.warningText, required this.window, required this.hourly, required this.daily,
    required this.profile});
  @override
  State<_BottomSheet> createState() => _BottomSheetState();
}

class _BottomSheetState extends State<_BottomSheet> {
  int _dayIdx = 0;             // 0 = today, 1..6 = following days
  bool _expanded = false;      // sheet peek collapsed by default until the user taps the header
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xE60F2A44), borderRadius: BorderRadius.circular(14)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        _routeRow(),
        // header — "Set up your boat" / boat summary + Edit + expand/collapse
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 6),
            child: Row(children: [
              Icon(_expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up, color: const Color(0xCCFFFFFF), size: 20),
              const SizedBox(width: 6),
              Expanded(child: Text(_headerText(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15))),
              Material(
                color: Colors.transparent,
                child: InkWell(onTap: widget.onEditProfile,
                  child: const Padding(padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Text('Edit', style: TextStyle(color: Color(0xFF6EB6FF), fontWeight: FontWeight.w700, fontSize: 13)))),
              ),
            ]),
          ),
        ),
        if (widget.warningText != null) _BoatWarningBanner(text: widget.warningText!),
        if (_expanded) ..._expandedBody(),
      ]),
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

  Widget _routeRow() {
    return Row(children: [
      Expanded(child: widget.waypointCount == 0
          ? Text(widget.picking ? 'Tap the map to drop a waypoint' : 'No route — tap Go-to to plan one',
              style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 13))
          : Row(children: [
              _stat('Route${widget.unverified ? ' ⚠' : ''}', '${widget.routeNm.toStringAsFixed(1)} nm'),
              const SizedBox(width: 14),
              _stat('ETA', widget.etaMin >= 60 ? '${widget.etaMin ~/ 60}h ${widget.etaMin % 60}m' : '${math.max(1, widget.etaMin)} min'),
              const SizedBox(width: 14),
              _stat('Points', '${widget.waypointCount}'),
              if (widget.fuelGal > 0) ...[
                const SizedBox(width: 14),
                _stat('Fuel', widget.fuelGal < 10 ? '${widget.fuelGal.toStringAsFixed(1)} gal' : '${widget.fuelGal.round()} gal'),
              ],
            ]),
      ),
      if (widget.waypointCount > 0) ...[
        _bigBtn(widget.navigating ? 'Stop' : 'Start',
          widget.navigating ? const Color(0xFFD93A2B) : const Color(0xFF1F8A5B),
          widget.navigating ? widget.onStop : widget.onStart),
        const SizedBox(width: 6),
        _smallBtn('Undo', widget.onUndoRoute),
        const SizedBox(width: 6),
        _smallBtn('GPX', widget.onGpx),
        const SizedBox(width: 6),
        _smallBtn('Clear', widget.onClearRoute),
      ],
    ]);
  }

  List<Widget> _expandedBody() {
    final w = widget.weather;
    return [
      const SizedBox(height: 6),
      if (w != null) _weatherBlock(w),
      if (widget.window != null) ...[
        const SizedBox(height: 8),
        _BestWindowPill(win: widget.window!),
      ],
      const SizedBox(height: 10),
      _DayTabs(daily: widget.daily, selected: _dayIdx, onSelect: (i) => setState(() => _dayIdx = i)),
      const SizedBox(height: 8),
      Text('Best time to boat', style: TextStyle(color: Colors.white.withOpacity(.9),
        fontWeight: FontWeight.w800, fontSize: 13, letterSpacing: 0.3)),
      const SizedBox(height: 4),
      _HourlyTable(hourly: widget.hourly, dayIdx: _dayIdx, profile: widget.profile),
    ];
  }

  Widget _weatherBlock(Weather w) {
    final isNight = w.sunset != null && DateTime.now().isAfter(w.sunset!);
    final icon = isNight ? '🌙' : _wxIcon(w.weatherCode);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(icon, style: const TextStyle(fontSize: 34)),
        const SizedBox(width: 8),
        Text('${w.tempF?.round() ?? '—'}°', style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w800, height: 1)),
        const Text('F', style: TextStyle(color: Color(0xAAFFFFFF), fontSize: 15, fontWeight: FontWeight.w700)),
        const Spacer(),
        Text(_condText(w.weatherCode), style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 13, fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: 10),
      Wrap(spacing: 14, runSpacing: 8, children: [
        _wxCell('Wind', '${w.windKt?.round() ?? '—'} kn ${_dirName(w.windDirDeg?.toDouble() ?? 0)}'),
        _wxCell('Gust', '${w.gustKt?.round() ?? '—'} kn'),
        if (w.sunset != null) _wxCell('Sunset', _fmtTime(w.sunset!)),
        if (w.waterTempF != null) _wxCell('Water', '${w.waterTempF!.round()}°F'),
        if (w.waveFt != null) _wxCell('Wave', '${w.waveFt!.toStringAsFixed(1)} ft'),
        if (w.wavePeriodS != null) _wxCell('Period', '${w.wavePeriodS!.round()} s'),
        if (w.precipPct != null && w.precipPct! > 0) _wxCell('Rain', '${w.precipPct!.round()}%'),
      ]),
    ]);
  }

  Widget _wxCell(String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
    Text(label, style: const TextStyle(color: Color(0xAAFFFFFF), fontSize: 10, letterSpacing: 0.5)),
    Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
  ]);

  Widget _stat(String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(color: Color(0xAAFFFFFF), fontSize: 10, letterSpacing: 0.5)),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
      ]);
  Widget _bigBtn(String label, Color color, VoidCallback onTap) => Material(
        color: color, borderRadius: BorderRadius.circular(9),
        child: InkWell(borderRadius: BorderRadius.circular(9), onTap: onTap,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          ),
        ),
      );
  Widget _smallBtn(String label, VoidCallback onTap) => Material(
        color: const Color(0x33FFFFFF), borderRadius: BorderRadius.circular(9),
        child: InkWell(borderRadius: BorderRadius.circular(9), onTap: onTap,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ),
      );
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

class _BestWindowPill extends StatelessWidget {
  final BestWindow win;
  const _BestWindowPill({required this.win});
  @override
  Widget build(BuildContext context) {
    final color = win.level == 'g' ? const Color(0xFF1F8A5B) : const Color(0xFFF2A93B);
    final label = win.level == 'g' ? 'Calm' : 'Fair';
    final now = DateTime.now();
    final sameDay = win.start.year == now.year && win.start.month == now.month && win.start.day == now.day;
    final day = sameDay ? 'Today' : _weekday(win.start);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: color.withOpacity(.22),
        border: Border.all(color: color, width: 1), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
        const SizedBox(width: 8),
        Text('Best window: $day ${_fmtTime(win.start)}–${_fmtTime(win.end)} · $label',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12.5)),
      ]),
    );
  }
}

String _weekday(DateTime t) {
  const names = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  return names[(t.toLocal().weekday - 1) % 7];
}

class _DayTabs extends StatelessWidget {
  final List<DailyForecast> daily;
  final int selected;
  final ValueChanged<int> onSelect;
  const _DayTabs({required this.daily, required this.selected, required this.onSelect});
  @override
  Widget build(BuildContext context) {
    final labels = <String>[];
    for (int i = 0; i < 7; i++) {
      if (i == 0) { labels.add('Today'); continue; }
      final t = daily.length > i ? daily[i].date : DateTime.now().add(Duration(days: i));
      labels.add(_weekday(t));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: List.generate(labels.length, (i) {
        final sel = i == selected;
        return Padding(padding: const EdgeInsets.only(right: 6),
          child: Material(color: sel ? const Color(0xFF1466C7) : const Color(0x22FFFFFF),
            borderRadius: BorderRadius.circular(999),
            child: InkWell(borderRadius: BorderRadius.circular(999), onTap: () => onSelect(i),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(labels[i], style: TextStyle(color: sel ? Colors.white : const Color(0xCCFFFFFF),
                  fontWeight: FontWeight.w800, fontSize: 12.5))))),
        );
      })),
    );
  }
}

class _HourlyTable extends StatelessWidget {
  final List<HourlyPoint> hourly;
  final int dayIdx;
  final BoatProfile profile;
  const _HourlyTable({required this.hourly, required this.dayIdx, required this.profile});
  @override
  Widget build(BuildContext context) {
    if (hourly.isEmpty) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Loading hourly forecast…', style: TextStyle(color: Color(0xAAFFFFFF), fontSize: 12)));
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
      return const Padding(padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('No more daylight hours today — swipe to Fri for tomorrow.',
          style: TextStyle(color: Color(0xAAFFFFFF), fontSize: 12)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows.map((h) => _row(h)).toList());
  }
  Widget _row(HourlyPoint h) {
    final s = score(h.windKt, h.gustKt, null, profile);
    final color = _gradeColors[s]!;
    final label = s == 'g' ? 'Calm' : (s == 'a' ? 'Fair' : 'Rough');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(width: 46, child: Text(_hourLabel(h.t), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12))),
        Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
        const SizedBox(width: 6),
        SizedBox(width: 40, child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 11))),
        Text(_wxIcon(h.weatherCode), style: const TextStyle(fontSize: 14)),
        const SizedBox(width: 4),
        SizedBox(width: 36, child: Text('${h.tempF?.round() ?? '—'}°', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700))),
        SizedBox(width: 70, child: Text('${h.windKt?.round() ?? '—'} kn ${_dirName(h.windDirDeg ?? 0.0)}', style: const TextStyle(color: Colors.white, fontSize: 11))),
        SizedBox(width: 42, child: Text('g${h.gustKt?.round() ?? '—'}', style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 11))),
        if (h.precipPct != null && h.precipPct! > 0)
          Text('${h.precipPct!.round()}%', style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 11)),
      ]),
    );
  }
  String _hourLabel(DateTime t) {
    final l = t.toLocal();
    final h = l.hour == 0 ? 12 : (l.hour > 12 ? l.hour - 12 : l.hour);
    final ampm = l.hour >= 12 ? 'PM' : 'AM';
    return '$h $ampm';
  }
}

// ==================================================================================================
// Batch B widgets (alerts, MOB, anchor HUD, forecast sheet)
// ==================================================================================================

class _AlertBanner extends StatelessWidget {
  final NwsAlert alert;
  final VoidCallback onDismiss;
  const _AlertBanner({required this.alert, required this.onDismiss});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: alert.isSevere ? const Color(0xE6D93A2B) : const Color(0xE6F2A93B),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(children: [
      const Icon(Icons.warning_amber_rounded, color: Colors.white),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(alert.event, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
        if (alert.headline.isNotEmpty)
          Text(alert.headline, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xEEFFFFFF), fontSize: 11)),
      ])),
      IconButton(icon: const Icon(Icons.close, color: Colors.white, size: 18), onPressed: onDismiss, padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 30, minHeight: 30)),
    ]),
  );
}

class _BoatWarningBanner extends StatelessWidget {
  final String text;
  const _BoatWarningBanner({required this.text});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(color: const Color(0xE6F2A93B), borderRadius: BorderRadius.circular(12)),
    child: Row(children: [
      const Icon(Icons.info_outline, color: Colors.white, size: 18),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12))),
    ]),
  );
}

class _MobPin extends StatelessWidget {
  const _MobPin();
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 44, height: 44,
    child: Stack(alignment: Alignment.center, children: [
      Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0x33D93A2B),
          border: Border.all(color: const Color(0xFFD93A2B), width: 2),
        ),
      ),
      Image.asset('assets/icons/mob-buoy.png', width: 36, height: 36, fit: BoxFit.contain),
    ]),
  );
}

class _MobHud extends StatelessWidget {
  final LatLng from, to;
  final VoidCallback onClear;
  const _MobHud({required this.from, required this.to, required this.onClear});
  @override
  Widget build(BuildContext context) {
    final d = _haversineM(from, to);
    final b = _bearingDeg(from, to);
    final dist = d < 370 ? '${(d * 3.28).round()} ft' : '${(d/1852).toStringAsFixed(d/1852<10?2:1)} nm';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: const Color(0xE6D93A2B), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Icon(Icons.priority_high, color: Colors.white),
        const SizedBox(width: 10),
        Expanded(child: Text('MOB · $dist · ${b.round().toString().padLeft(3, "0")}° ${_dirName(b)}',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14))),
        Material(color: const Color(0x33FFFFFF), borderRadius: BorderRadius.circular(8),
          child: InkWell(borderRadius: BorderRadius.circular(8), onTap: onClear,
            child: const Padding(padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text('Clear MOB', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)))),
        ),
      ]),
    );
  }
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
  final List<TidePoint> tides;
  final TideStation? tideStation;
  const ForecastSheet({super.key, required this.daily, required this.tides, this.tideStation});
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
        const SizedBox(height: 20),
        const Text('Tides', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
        if (tideStation != null) Text(tideStation!.name, style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12)),
        const SizedBox(height: 8),
        if (tides.isEmpty) const Text('No tide station found', style: TextStyle(color: Color(0xCCFFFFFF)))
        else ...tides.take(8).map((p) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            SizedBox(width: 70, child: Text('${_pad(p.t.month)}/${_pad(p.t.day)} ${_pad(p.t.hour)}:${_pad(p.t.minute)}',
                style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12))),
            const SizedBox(width: 8),
            Icon(p.type == 'H' ? Icons.arrow_upward : Icons.arrow_downward,
                color: p.type == 'H' ? const Color(0xFF22C55E) : const Color(0xFF2E6F9E), size: 16),
            const SizedBox(width: 6),
            Text('${p.v.toStringAsFixed(1)} ft',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
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
String _pad(int n) => n.toString().padLeft(2, '0');

// ==================================================================================================
// helpers
// ==================================================================================================

class _TrailPoint {
  final LatLng p;
  final int tMs;
  _TrailPoint(this.p, this.tMs);
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
