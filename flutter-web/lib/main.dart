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
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, HapticFeedback;
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
  for (final url in _overpassMirrors) {
    try {
      final r = await http.post(Uri.parse(url),
        body: {'data': query}).timeout(const Duration(seconds: 12));
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

Future<List<Dock>> fetchDocks(LatLng at) async {
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
[out:json][timeout:15];
(
  node["leisure"="marina"](${b.south},${b.west},${b.north},${b.east});
  node["leisure"="slipway"](${b.south},${b.west},${b.north},${b.east});
  node["seamark:type"="fuel"](${b.south},${b.west},${b.north},${b.east});
  way["leisure"="marina"](${b.south},${b.west},${b.north},${b.east});
);
out center 60;''';
  final body = await _overpassQuery(q);
  if (body == null) return [];
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

Future<List<NavAid>> fetchNavAids(LatLng at) async {
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
[out:json][timeout:15];
(
  node["seamark:type"="buoy_lateral"](${b.south},${b.west},${b.north},${b.east});
  node["seamark:type"="beacon_lateral"](${b.south},${b.west},${b.north},${b.east});
);
out 120;''';
  final body = await _overpassQuery(q);
  if (body == null) return [];
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
      // PWA index.html:500 — after 1.5 s on first launch (no saved profile), open the modal.
      if (p.name.isEmpty && p.lengthFt == null) {
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (mounted && _profile.name.isEmpty && _profile.lengthFt == null) _openBoatProfile();
        });
      }
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
    final d = await fetchDocks(at);
    if (mounted) setState(() => _docks = d);
  }
  Future<void> _refreshNavAids(LatLng at) async {
    final a = await fetchNavAids(at);
    if (mounted) setState(() => _navAids = a);
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
      builder: (ctx) => ForecastSheet(daily: _daily, tides: _tides, tideStation: _tideStation),
    );
  }

  // Batch B.6 — polished tide dashboard, separated from the plain 7-day forecast sheet.
  Future<void> _openTides() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => TidesSheet(
        station: _tideStation, tides: _tides,
        sunrise: _weather?.sunrise, sunset: _weather?.sunset,
        initialUnit: _tideUnit,
        onUnitChanged: (u) async {
          setState(() => _tideUnit = u);
          try {
            final sp = await SharedPreferences.getInstance();
            await sp.setString('tideUnit', u);
          } catch (_) {}
        },
      ),
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
      builder: (ctx) => StatefulBuilder(builder: (sctx, setSheetState) => MoreToolsSheet(
        docksOn: _docksOn,
        navAidsOn: _navAidsOn,
        anchorOn: _anchorPoint != null,
        fuelOn: _fuelRingOn,
        smartOn: _smart,
        onToggleDocks: (v) {
          setSheetState(() {});
          setState(() => _docksOn = v);
          if (v) _refreshDocks(_me ?? _homeCenter);
        },
        onToggleNavAids: (v) {
          setSheetState(() {});
          setState(() => _navAidsOn = v);
          if (v) _refreshNavAids(_me ?? _homeCenter);
        },
        onToggleAnchor: (_) { Navigator.of(ctx).pop(); _toggleAnchor(); },
        onToggleFuel: (_) { Navigator.of(ctx).pop(); _toggleFuelRing(); },
        onToggleSmart: (_) { Navigator.of(ctx).pop(); setState(() => _smart = !_smart); _recomputeRoute(); },
        onOpenForecast: () { Navigator.of(ctx).pop(); _openForecast(); },
        onOpenTides: () { Navigator.of(ctx).pop(); _openTides(); },
      )),
    );
  }

  void _handleMapTap(TapPosition _, LatLng ll) {
    if (!_picking) {
      // PWA: any interaction with the map area closes the expanded sheet
      // (index.html:1413 clears on picking mode, :1606 clears on route drop).
      if (_sheetExpanded) setState(() => _sheetExpanded = false);
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
                TileLayer(urlTemplate: _tileUrl(_base), userAgentPackageName: 'net.bayside.flutter'),
                // NOAA ENC MarineChart on every non-plain-Map basemap — matches the PWA
                // which overlays it on Chart, Sat and Dark alike (index.html:535, 543-545).
                if (_base != Basemap.map)
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
                  if (_docksOn) for (final d in _docks)
                    Marker(
                      point: d.ll,
                      width: 28, height: 28,
                      child: _DockPin(kind: d.kind, name: d.name, onRouteHere: () => _routeToPoint(d.ll)),
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
                      width: 32, height: 32,
                      child: _WaypointPin(isDest: i == _waypoints.length - 1,
                        grade: _gradeAt(_waypoints[i])),
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
                  if (_me != null)
                    Marker(
                      point: _me!,
                      width: 56, height: 56,
                      child: BoatMarker(headingDeg: _heading, active: _navigating),
                    )
                  else
                    // Ghost boat at the map centre so users can see where the boat *would* be
                    // once GPS is granted — mirrors the PWA "search" state HUD.
                    Marker(
                      point: _homeCenter,
                      width: 56, height: 56,
                      child: const BoatMarker(headingDeg: 0, ghost: true),
                    ),
                ]),
              ],
              ),
              // Weather-animation canvas — wind streaks + rain particles, driven by live wx.
              // Sits above the map inside the same tilt Transform so it feels like weather over
              // the water rather than the screen.
              Positioned.fill(child: IgnorePointer(child: FxCanvas(
                windKt: _weather?.windKt ?? 0,
                gustKt: _weather?.gustKt ?? 0,
                windDirDeg: (_weather?.windDirDeg ?? 0).toDouble(),
                precipPct: _weather?.precipPct ?? 0,
                boatSpeedKt: _speedKt,
                lightBasemap: _base == Basemap.map || _base == Basemap.chart,
              ))),
            ]),
          ),
          // Sun edge marker — PWA index.html:1130-1197. Lives OUTSIDE the tilt transform
          // (the PWA's `#sun` is `position:fixed`, unaffected by the map's perspective) so it
          // stays pinned to the true viewport edge regardless of Start-ride tilt. The Stack
          // it builds only paints a small icon (+ optional popover card), so taps outside
          // those areas fall through to the map beneath. NOTE: placed at the END of this
          // Stack (see below, after the bottom sheet) — earlier it sat here, ahead of the
          // HUD/sheet, and got silently painted OVER whenever the sun/moon's true bearing
          // pointed toward the persistent top or bottom chrome (e.g. the moon at ~180°
          // azimuth lands dead-centre at the bottom edge, exactly behind the sheet's peek).
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
            if (_boatWarning() != null) ...[
              const SizedBox(height: 8),
              _BoatWarningBanner(text: _boatWarning()!.text, severity: _boatWarning()!.severity),
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
              if (_follow && _me != null) _controller.move(_me!, math.max(_controller.camera.zoom, 14));
            }),
            // PWA index.html:1413 — turning picking on closes the sheet so the map is unobstructed.
            onGoto: () => setState(() { _picking = !_picking; if (_picking) _sheetExpanded = false; }),
            onLocate: _startGps,
            onMob: _toggleMob,
            onMoreTools: _openMoreTools,
          )),
          // PWA desktop CSS (index.html:273): `#sheet{left:12px;right:auto;width:390px;...}`
          Positioned(left: 12, bottom: 12,
            right: MediaQuery.sizeOf(context).width >= 820 ? null : 12,
            width: MediaQuery.sizeOf(context).width >= 820 ? 390 : null,
            child: _BottomSheet(
            weather: _weather, routeNm: _routeNm(), etaMin: _etaMin(), fuelGal: _fuelGal(),
            waypointCount: _waypoints.length, picking: _picking,
            unverified: _routeUnverified, navigating: _navigating,
            onClearRoute: () async { setState(() { _waypoints.clear(); _picking = false; _routedPath = null; _legIdx = 0; }); await _stopRide(); },
            onUndoRoute: () { if (_waypoints.isEmpty) return; setState(() { _waypoints.removeLast(); if (_legIdx >= _waypoints.length) _legIdx = math.max(0, _waypoints.length - 1); }); _recomputeRoute(); },
            onStart: _startRide, onStop: _stopRide,
            onGpx: _gpxPlaceholder, onEditProfile: _openBoatProfile,
            warningText: _boatWarning(), window: bestWindow(_hourly, _profile),
            hourly: _hourly, daily: _daily, profile: _profile,
            expanded: _sheetExpanded,
            onExpandedChanged: (v) => setState(() => _sheetExpanded = v),
          )),
          // Painted LAST so it's always on top of the HUD/rail/sheet, regardless of which
          // edge the sun or moon's true bearing points toward. Its Stack only paints a small
          // icon (+ optional popover card), so taps elsewhere still fall through to the UI
          // beneath it.
          Positioned.fill(child: _SunEdgeMarker(
            at: _me ?? _homeCenter,
            sunrise: _weather?.sunrise, sunset: _weather?.sunset,
            open: _suntipOpen,
            onToggle: () => setState(() => _suntipOpen = !_suntipOpen),
          )),
        ]),
      ),
    );
  }
}

// ==================================================================================================
// widgets
// ==================================================================================================

// Batch B.5: weather-animation canvas. Full-viewport overlay above the map, ignoring pointer
// events. Wind streaks scale density with (wind + gust*0.5) and slant along wind direction;
// rain drops appear when precipPct > 0. Wake spray is a placeholder — needs boat screen-projection
// which is nontrivial with `flutter_map` and will land in Batch C.
class FxCanvas extends StatefulWidget {
  final double windKt, gustKt, windDirDeg, precipPct, boatSpeedKt;
  final bool lightBasemap;   // Map/Chart = true (dark streaks), Sat/Dark = false (white streaks)
  const FxCanvas({super.key, required this.windKt, required this.gustKt, required this.windDirDeg,
    required this.precipPct, required this.boatSpeedKt, this.lightBasemap = true});
  @override
  State<FxCanvas> createState() => _FxCanvasState();
}
class _FxCanvasState extends State<FxCanvas> with SingleTickerProviderStateMixin {
  late final _tick = createTicker(_step);
  final math.Random _rng = math.Random();
  final List<_WindStreak> _streaks = [];
  final List<_RainDrop> _drops = [];
  int _lastMs = 0;
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _tick.start();
  }
  @override
  void dispose() { _tick.dispose(); super.dispose(); }

  int _targetStreaks() {
    final eff = widget.windKt + widget.gustKt * 0.4;
    return math.min(120, (eff * 3.5).round());
  }
  int _targetDrops() {
    if (widget.precipPct <= 0) return 0;
    return math.min(140, (widget.precipPct * 1.8).round());
  }

  void _step(Duration elapsed) {
    if (_size == Size.zero) { setState(() {}); return; }
    final now = elapsed.inMilliseconds;
    final dt = _lastMs == 0 ? 0.016 : math.min(0.05, (now - _lastMs) / 1000);
    _lastMs = now;
    // top-up streaks/drops toward the target counts
    while (_streaks.length < _targetStreaks()) _streaks.add(_spawnStreak());
    while (_streaks.length > _targetStreaks()) _streaks.removeLast();
    while (_drops.length < _targetDrops()) _drops.add(_spawnDrop());
    while (_drops.length > _targetDrops()) _drops.removeLast();
    // wind vector — screen x/y for a "wind is BLOWING TOWARD" motion vector.
    // Meteorology gives dir wind comes FROM, so the streak travels toward dir+180.
    final rad = (widget.windDirDeg + 180) * math.pi / 180;
    final vx = math.sin(rad) * (widget.windKt + widget.gustKt * 0.5) * 6;
    final vy = -math.cos(rad) * (widget.windKt + widget.gustKt * 0.5) * 6;
    for (final s in _streaks) {
      s.x += vx * dt;
      s.y += vy * dt;
      if (s.x < -20 || s.x > _size.width + 20 || s.y < -20 || s.y > _size.height + 20) {
        _resetStreak(s);
      }
    }
    for (final d in _drops) {
      d.x += vx * 0.15 * dt;
      d.y += d.speed * dt;
      if (d.y > _size.height + 4) { d.x = _rng.nextDouble() * _size.width; d.y = -8; }
    }
    setState(() {});
  }

  _WindStreak _spawnStreak() {
    final s = _WindStreak(0, 0, 8 + _rng.nextDouble() * 20, .3 + _rng.nextDouble() * .5);
    _resetStreak(s);
    return s;
  }
  void _resetStreak(_WindStreak s) {
    s.x = _rng.nextDouble() * (_size.width + 40) - 20;
    s.y = _rng.nextDouble() * (_size.height + 40) - 20;
  }
  _RainDrop _spawnDrop() => _RainDrop(
    _rng.nextDouble() * _size.width,
    _rng.nextDouble() * _size.height,
    260 + _rng.nextDouble() * 140,
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (ctx, cs) {
    final s = Size(cs.maxWidth, cs.maxHeight);
    if (s != _size) _size = s;
    return CustomPaint(painter: _FxPainter(
      streaks: _streaks, drops: _drops, windDirDeg: widget.windDirDeg,
      precipPct: widget.precipPct, lightBasemap: widget.lightBasemap,
    ), size: s);
  });
}

class _WindStreak {
  double x, y, length, alpha;
  _WindStreak(this.x, this.y, this.length, this.alpha);
}
class _RainDrop {
  double x, y, speed;
  _RainDrop(this.x, this.y, this.speed);
}
class _FxPainter extends CustomPainter {
  final List<_WindStreak> streaks;
  final List<_RainDrop> drops;
  final double windDirDeg, precipPct;
  final bool lightBasemap;
  _FxPainter({required this.streaks, required this.drops, required this.windDirDeg, required this.precipPct,
    required this.lightBasemap});
  @override
  void paint(Canvas canvas, Size size) {
    // Streaks — direction the wind is BLOWING TOWARD (dir + 180).
    final rad = (windDirDeg + 180) * math.pi / 180;
    final dx = math.sin(rad), dy = -math.cos(rad);
    // PWA index.html:1071: dark navy 50% on Map/Chart, white 70% on Sat/Dark — Flutter's
    // earlier white-only ~5-13% opacity was nearly invisible against a detailed basemap.
    final streakColor = lightBasemap
      ? const Color(0xFF0F2A44).withOpacity(.5)
      : Colors.white.withOpacity(.7);
    final streakPaint = Paint()..color = streakColor..strokeWidth = 1.3..strokeCap = StrokeCap.round;
    for (final s in streaks) {
      canvas.drawLine(Offset(s.x, s.y),
        Offset(s.x + dx * s.length, s.y + dy * s.length), streakPaint);
    }
    // Rain drops — small vertical lines with a slight wind lean.
    if (precipPct > 0) {
      // Was capped at .36 max (barely visible) — PWA rain reaches up to .85 (index.html:1082).
      final rainPaint = Paint()..strokeWidth = 1.4..strokeCap = StrokeCap.round
        ..color = const Color(0xFF78AADC).withOpacity(math.min(.75, .3 + precipPct / 130));
      for (final d in drops) {
        canvas.drawLine(Offset(d.x, d.y),
          Offset(d.x + dx * 3, d.y + 8), rainPaint);
      }
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

class BoatMarker extends StatelessWidget {
  final double headingDeg;
  final bool active;
  final bool ghost;   // true = grey "GPS not fixed" placeholder centred on the map
  const BoatMarker({super.key, required this.headingDeg, this.active = false, this.ghost = false});
  @override
  Widget build(BuildContext context) {
    final haloColor = ghost ? const Color(0x66FFFFFF) : const Color(0x66F2A93B);
    return Transform.rotate(
      angle: headingDeg * math.pi / 180,
      child: SizedBox(
        width: 56, height: 56,
        child: Stack(alignment: Alignment.center, children: [
          // Always-visible halo ring so the boat stands out at low zoom (was invisible when
          // the RIB detail scaled down to a couple of pixels). No blur/shadow here on purpose —
          // a soft glow bled through the boat sprite's antialiased edges and made the ring look
          // like it was crossing IN FRONT of the boat, even though paint order (this Container
          // first, boat images after) was always correct. A crisp flat ring reads unambiguously
          // as sitting behind the boat.
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: haloColor.withOpacity(.16),
              border: Border.all(color: haloColor, width: 1.5),
            ),
          ),
          // classic top-down skiff (always there, fades OUT during Start ride)
          Opacity(
            opacity: ghost ? .35 : 1,
            child: AnimatedOpacity(
              opacity: active ? 0 : 1,
              duration: const Duration(milliseconds: 500),
              child: Image.asset('assets/icons/boat.png', fit: BoxFit.contain, width: 40, height: 40),
            ),
          ),
          // photo-real orange RIB (fades IN during Start ride) — matches the PWA's boat crossfade
          if (!ghost) AnimatedOpacity(
            opacity: active ? 1 : 0,
            duration: const Duration(milliseconds: 500),
            child: Image.asset('assets/icons/boat-3d.png', fit: BoxFit.contain, width: 40, height: 40),
          ),
        ]),
      ),
    );
  }
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
  final String grade;   // 'g' = calm/green, 'a' = fair/amber, 'r' = rough/red
  const _WaypointPin({required this.isDest, this.grade = 'a'});
  @override
  Widget build(BuildContext context) => Icon(
        Icons.location_on,
        size: isDest ? 32 : 26,
        color: _gradeColors[grade] ?? const Color(0xFFF2A93B),
        shadows: const [Shadow(color: Colors.black45, blurRadius: 4)],
      );
}

// Batch B.5 — chart overlay markers
class _DockPin extends StatelessWidget {
  final DockKind kind;
  final String name;
  final VoidCallback onRouteHere;
  const _DockPin({required this.kind, required this.name, required this.onRouteHere});
  @override
  Widget build(BuildContext context) {
    final color = kind == DockKind.fuel ? const Color(0xFF1F8A5B)
        : (kind == DockKind.slipway ? const Color(0xFF2E6F9E) : const Color(0xFF6B4FC6));
    final icon = kind == DockKind.fuel ? Icons.local_gas_station
        : (kind == DockKind.slipway ? Icons.directions_boat : Icons.anchor);
    return Tooltip(
      message: name,
      child: InkWell(
        onTap: () => _openDockCallout(context, name, kind, onRouteHere),
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
  static void _openDockCallout(BuildContext c, String name, DockKind kind, VoidCallback onRouteHere) {
    showModalBottomSheet<void>(context: c, backgroundColor: Colors.transparent,
      builder: (bc) => SafeArea(child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(color: Color(0xFF0F2A44), fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 4),
          Text(kind == DockKind.fuel ? 'Fuel dock' : (kind == DockKind.slipway ? 'Boat ramp / slipway' : 'Marina'),
            style: const TextStyle(color: Color(0xFF708597), fontSize: 12)),
          const SizedBox(height: 12),
          Material(color: const Color(0xFF1F8A5B), borderRadius: BorderRadius.circular(10),
            child: InkWell(borderRadius: BorderRadius.circular(10), onTap: () { Navigator.of(bc).pop(); onRouteHere(); },
              child: const Padding(padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text('Route here', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))))),
        ]),
      )));
  }
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

class _TidalCurrentArrow extends StatelessWidget {
  final TidalCurrent sample;
  const _TidalCurrentArrow({required this.sample});
  @override
  Widget build(BuildContext context) {
    final v = sample.velocityKt.abs();
    final slack = v < 0.15;
    final color = slack ? const Color(0xFF708597)
      : (sample.velocityKt >= 0 ? const Color(0xFF2E6F9E) : const Color(0xFF6B4FC6));
    if (slack) {
      return Tooltip(message: '${sample.stationName}\nSlack',
        child: Container(width: 10, height: 10,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color,
            border: Border.all(color: Colors.white, width: 1.5))));
    }
    final size = math.min(40.0, 24 + v * 4);
    return Tooltip(
      message: '${sample.stationName}\n${sample.velocityKt >= 0 ? "Flood" : "Ebb"} · ${v.toStringAsFixed(1)} kn',
      child: Transform.rotate(
        angle: sample.directionDeg * math.pi / 180,
        child: Icon(Icons.arrow_upward, color: color, size: size,
          shadows: const [Shadow(color: Colors.black45, blurRadius: 3)]),
      ),
    );
  }
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
          // PWA has no separate boat chip in the top HUD — boat identity lives in the sheet
          // header only (index.html speed HUD has just kn + status line).
          const Spacer(),
          _BaseSwitcher(base: base, onChange: onBaseChange),
        ]),
      ]);
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
  // PWA rail: default WHITE 44 px circle + sea icon; active flips to sea bg + white icon.
  Widget _btn({required IconData icon, required bool active, required VoidCallback onTap, required String tip}) => Material(
        color: active ? const Color(0xFF2E6F9E) : Colors.white,
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
  final VoidCallback onOpenTides;
  const MoreToolsSheet({super.key,
    required this.docksOn, required this.navAidsOn, required this.anchorOn, required this.fuelOn, required this.smartOn,
    required this.onToggleDocks, required this.onToggleNavAids, required this.onToggleAnchor, required this.onToggleFuel, required this.onToggleSmart,
    required this.onOpenForecast, required this.onOpenTides});
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
        Row(children: [
          Expanded(child: Material(color: const Color(0xFFF4F8FA), borderRadius: BorderRadius.circular(10),
            child: InkWell(borderRadius: BorderRadius.circular(10), onTap: onOpenTides,
              child: const Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(children: [
                  Icon(Icons.waves, color: Color(0xFF2E6F9E)),
                  SizedBox(width: 8),
                  Text('Tides', style: TextStyle(color: Color(0xFF0F2A44), fontWeight: FontWeight.w800, fontSize: 14)),
                ]))))),
          const SizedBox(width: 8),
          Expanded(child: Material(color: const Color(0xFFF4F8FA), borderRadius: BorderRadius.circular(10),
            child: InkWell(borderRadius: BorderRadius.circular(10), onTap: onOpenForecast,
              child: const Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(children: [
                  Icon(Icons.cloud_outlined, color: Color(0xFF2E6F9E)),
                  SizedBox(width: 8),
                  Text('7-day forecast', style: TextStyle(color: Color(0xFF0F2A44), fontWeight: FontWeight.w800, fontSize: 14)),
                ]))))),
        ]),
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
  final ({String text, String severity})? warningText;
  final BestWindow? window;
  final List<HourlyPoint> hourly;
  final List<DailyForecast> daily;
  final BoatProfile profile;
  final bool expanded;
  final ValueChanged<bool> onExpandedChanged;
  const _BottomSheet({required this.weather, required this.routeNm, required this.etaMin, required this.fuelGal,
    required this.waypointCount, required this.picking, required this.unverified, required this.navigating,
    required this.onClearRoute, required this.onUndoRoute, required this.onStart, required this.onStop,
    required this.onGpx, required this.onEditProfile,
    required this.warningText, required this.window, required this.hourly, required this.daily,
    required this.profile, required this.expanded, required this.onExpandedChanged});
  @override
  State<_BottomSheet> createState() => _BottomSheetState();
}

class _BottomSheetState extends State<_BottomSheet> {
  int _dayIdx = 0;             // 0 = today, 1..6 = following days
  double _dragDy = 0;          // accumulated vertical drag for swipe-to-toggle
  bool get _expanded => widget.expanded;
  void _setExpanded(bool v) => widget.onExpandedChanged(v);
  @override
  Widget build(BuildContext context) {
    // PWA: `max-height:86vh` (index.html:79) — cap the expanded body so the sheet doesn't
    // swallow the whole screen, and wrap in a scroll view so the user can reach every row.
    final maxExpandedH = MediaQuery.sizeOf(context).height * 0.86;
    return GestureDetector(
      // PWA index.html:1974 swipe handler — dy<-40 opens, dy>40 closes.
      onVerticalDragStart: (_) => _dragDy = 0,
      onVerticalDragUpdate: (d) => _dragDy += d.delta.dy,
      onVerticalDragEnd: (_) {
        if (_dragDy < -40 && !_expanded) _setExpanded(true);
        else if (_dragDy > 40 && _expanded) _setExpanded(false);
        _dragDy = 0;
      },
      child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xE60F2A44), borderRadius: BorderRadius.circular(14)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Grab handle — mirrors the PWA #grab (index.html:81-82): 40×5 pill inside a 24 px
        // tap zone. PWA uses `rgba(15,42,68,.28)` on a light paper sheet; our sheet is dark
        // navy, so we bump the opacity so the pill is still readable.
        Center(child: InkWell(
          onTap: () => _setExpanded(!_expanded),
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(width: 60, height: 24, child: Center(
            child: Container(width: 40, height: 5,
              decoration: BoxDecoration(color: const Color(0x66FFFFFF),
                borderRadius: BorderRadius.circular(3))),
          )),
        )),
        _routeRow(),
        // header — "Set up your boat" / boat summary + Edit + expand/collapse
        InkWell(
          onTap: () => _setExpanded(!_expanded),
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
        if (widget.warningText != null) _BoatWarningBanner(
          text: widget.warningText!.text, severity: widget.warningText!.severity),
        // PWA index.html:79 `transition: transform .28s cubic-bezier(.2,.8,.2,1)`.
        AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
            ? ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxExpandedH),
                child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
                    children: _expandedBody()),
                ),
              )
            : const SizedBox.shrink(),
        ),
      ]),
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

  // PWA index.html:315-322 : LEFT compact one-line summary that ellipses,
  // RIGHT small buttons pinned. Never wraps to a second line.
  Widget _routeRow() {
    if (widget.waypointCount == 0) {
      return Text(widget.picking ? 'Tap the map to drop a waypoint' : 'No route — tap Go-to to plan one',
        style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 13));
    }
    final eta = widget.etaMin >= 60
      ? '${widget.etaMin ~/ 60}h ${widget.etaMin % 60}m'
      : '${math.max(1, widget.etaMin)} min';
    final fuel = widget.fuelGal > 0
      ? ' · ~${widget.fuelGal < 10 ? widget.fuelGal.toStringAsFixed(1) : widget.fuelGal.round()} gal'
      : '';
    final summary = '${widget.waypointCount} pts · '
      '${widget.routeNm.toStringAsFixed(1)} nm · $eta$fuel';
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        if (widget.unverified) const Padding(padding: EdgeInsets.only(right: 4),
          child: Text('⚠', style: TextStyle(color: Color(0xFFF2A93B), fontSize: 14))),
        Expanded(child: Text(summary,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700))),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        _bigBtn(widget.navigating ? 'Stop' : 'Start',
          widget.navigating ? const Color(0xFFD93A2B) : const Color(0xFF1F8A5B),
          widget.navigating ? widget.onStop : widget.onStart),
        const SizedBox(width: 6),
        Expanded(child: _smallBtn('Undo', widget.onUndoRoute)),
        const SizedBox(width: 6),
        Expanded(child: _smallBtn('GPX', widget.onGpx)),
        const SizedBox(width: 6),
        Expanded(child: _smallBtn('Clear', widget.onClearRoute)),
      ]),
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
      // PWA: temp 42 pt weight-700 + condition small top-right (index.html #wxhead).
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(icon, style: const TextStyle(fontSize: 38)),
        const SizedBox(width: 8),
        Baseline(baseline: 42, baselineType: TextBaseline.alphabetic,
          child: Text('${w.tempF?.round() ?? '—'}°',
            style: const TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.w800, height: 1))),
        const SizedBox(width: 2),
        const Baseline(baseline: 42, baselineType: TextBaseline.alphabetic,
          child: Text('F', style: TextStyle(color: Color(0xAAFFFFFF), fontSize: 15, fontWeight: FontWeight.w700))),
        const Spacer(),
        Padding(padding: const EdgeInsets.only(top: 2),
          child: Text(_condText(w.weatherCode),
            style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 14, fontWeight: FontWeight.w600))),
      ]),
      const SizedBox(height: 10),
      // PWA grid gap 12 px.
      Wrap(spacing: 12, runSpacing: 8, children: [
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
            child: Text(label, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
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
    // PWA: 8 px gap between pills; inactive text at ~55% opacity.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: List.generate(labels.length, (i) {
        final sel = i == selected;
        return Padding(padding: const EdgeInsets.only(right: 8),
          child: Material(color: sel ? const Color(0xFF1466C7) : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            child: InkWell(borderRadius: BorderRadius.circular(999), onTap: () => onSelect(i),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(labels[i], style: TextStyle(
                  color: sel ? Colors.white : const Color(0xFFFFFFFF).withOpacity(.55),
                  fontWeight: FontWeight.w700, fontSize: 13))))),
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

// PWA index.html:62-63 `#alert small{max-height:0}` collapses to a headline; `.open` reveals
// the full description. Tap toggles.
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
  Widget build(BuildContext context) {
    final bg = widget.alert.isSevere ? const Color(0xE6D93A2B) : const Color(0xE6F2A93B);
    return Material(color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _open = !_open),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(widget.alert.event, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
              if (widget.alert.headline.isNotEmpty)
                Text(widget.alert.headline,
                  maxLines: _open ? null : 2,
                  overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xEEFFFFFF), fontSize: 11)),
              if (_open && widget.alert.description.isNotEmpty) Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(widget.alert.description,
                  style: const TextStyle(color: Color(0xEEFFFFFF), fontSize: 11, height: 1.35)),
              ),
            ])),
            IconButton(icon: const Icon(Icons.close, color: Colors.white, size: 18),
              onPressed: widget.onDismiss, padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30)),
          ]),
        ),
      ),
    );
  }
}

class _BoatWarningBanner extends StatelessWidget {
  final String text;
  final String severity;   // 'over' → red (default), 'near' → amber (PWA `.a` class)
  const _BoatWarningBanner({required this.text, this.severity = 'over'});
  @override
  Widget build(BuildContext context) {
    // PWA index.html:224 `#boatwarn{background:var(--red)}`; amber only for the `.a` class.
    final bg = severity == 'near' ? const Color(0xE6F2A93B) : const Color(0xE6D93A2B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Icon(Icons.info_outline, color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12))),
      ]),
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
      Image.asset('assets/icons/mob-buoy.png', width: 36, height: 36, fit: BoxFit.contain),
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
// Batch B.6 — tide dashboard: SVG-style curve + sunrise/sunset icons + ocean band + Now pill + hi/lo cards.
// Ports index.html:865-963 (renderTide) and the visual language of the PWA screenshot.
// ==================================================================================================

class TidesSheet extends StatefulWidget {
  final TideStation? station;
  final List<TidePoint> tides;
  final DateTime? sunrise, sunset;
  final String initialUnit;
  final ValueChanged<String>? onUnitChanged;
  const TidesSheet({super.key, required this.station, required this.tides,
    this.sunrise, this.sunset, this.initialUnit = 'ft', this.onUnitChanged});
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
    return DraggableScrollableSheet(
      initialChildSize: 0.85, minChildSize: 0.5, maxChildSize: 0.95, expand: false,
      builder: (ctx, scroll) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment(0, -1), end: Alignment(0, 1),
            colors: [Color(0xFF0B2740), Color(0xFF061A2D)]),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: ListView(controller: scroll, children: [
          Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(color: const Color(0x66FFFFFF), borderRadius: BorderRadius.circular(2)))),
          _header(),
          const SizedBox(height: 10),
          _legend(),
          const SizedBox(height: 10),
          AspectRatio(
            aspectRatio: 360 / 220,
            child: CustomPaint(painter: _TidePainter(
              curve: windowCurve, hilo: windowHilo,
              t0: t0, t1: t1, now: now,
              sunrise: widget.sunrise, sunset: widget.sunset,
              sunriseImg: _sunrise, sunsetImg: _sunset, oceanImg: _ocean,
              unit: _unit,
            )),
          ),
          const SizedBox(height: 14),
          _hiLoCards(nextFour),
          const SizedBox(height: 12),
          _footer(),
        ]),
      ),
    );
  }

  Widget _header() {
    final s = widget.station;
    final today = DateTime.now();
    final dateStr = '${_dayName(today)}, ${_monthName(today.month)} ${today.day}, ${today.year}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 12, height: 12, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF1F8AE5))),
        const SizedBox(width: 8),
        Expanded(child: Text(s?.name ?? 'No station', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15))),
        _unitToggle(),
      ]),
      if (s != null) Padding(padding: const EdgeInsets.only(top: 2),
        child: Text('${s.lat.toStringAsFixed(4)}° N, ${s.lng.toStringAsFixed(4)}° W',
          style: const TextStyle(color: Color(0xAA9CC1DE), fontSize: 12))),
      Padding(padding: const EdgeInsets.only(top: 8),
        child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: const Color(0xFF1466C7), borderRadius: BorderRadius.circular(10)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Text('📅  ', style: TextStyle(fontSize: 13)),
            Text(dateStr, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
          ]))),
    ]);
  }

  Widget _unitToggle() {
    Widget chip(String u) {
      final on = _unit == u;
      return Material(color: on ? const Color(0xFF1466C7) : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(borderRadius: BorderRadius.circular(9), onTap: () => _setUnit(u),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Text(u, style: TextStyle(color: on ? Colors.white : const Color(0xFF9CC1DE),
              fontWeight: FontWeight.w800, fontSize: 12)))));
    }
    return Container(padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: const Color(0x22FFFFFF), borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [chip('ft'), chip('m')]));
  }

  Widget _legend() {
    Widget dot(Color c, String l, String sub) => Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: c)),
      const SizedBox(width: 6),
      Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l, style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 12)),
        Text(sub, style: const TextStyle(color: Color(0xAA9CC1DE), fontSize: 10)),
      ]),
    ]);
    return Wrap(spacing: 22, runSpacing: 6, children: [
      dot(const Color(0xFF22C55E), 'Calm', 'Good conditions'),
      dot(const Color(0xFFF2A93B), 'Fair', 'Use caution'),
      dot(const Color(0xFFD93A2B), 'Rough', 'Challenging'),
    ]);
  }

  Widget _hiLoCards(List<TidePoint> pts) {
    Widget card(TidePoint p) {
      final isHigh = p.type == 'H';
      final color = isHigh ? const Color(0xFF35E96A) : const Color(0xFFFF5A55);
      return Container(padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFF0B2C47),
          border: Border.all(color: const Color(0xFF194762)), borderRadius: BorderRadius.circular(16),
          boxShadow: const [BoxShadow(color: Color(0x38000000), blurRadius: 14, offset: Offset(0, 6))]),
        child: Row(children: [
          Container(width: 34, height: 34,
            decoration: BoxDecoration(shape: BoxShape.circle,
              border: Border.all(color: color, width: 2)),
            child: Icon(isHigh ? Icons.arrow_upward : Icons.arrow_downward, color: color, size: 18)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(isHigh ? 'High Tide' : 'Low Tide', style: const TextStyle(color: Color(0xAA9CC1DE), fontSize: 11, fontWeight: FontWeight.w600)),
            Text(_fmtTime(p.t), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
            Text('${_fmtV(p.v)} $_unit', style: const TextStyle(color: Color(0xEEFFFFFF), fontSize: 11)),
          ])),
        ]));
    }
    if (pts.isEmpty) return const Padding(padding: EdgeInsets.symmetric(vertical: 8),
      child: Text('No upcoming tide events', style: TextStyle(color: Color(0xAA9CC1DE), fontSize: 12)));
    return GridView.count(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2, crossAxisSpacing: 9, mainAxisSpacing: 9, childAspectRatio: 2.2,
      children: pts.map(card).toList());
  }

  Widget _footer() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('⚓ ', style: TextStyle(fontSize: 12)),
        const Text('Plan Better. Boat Safer.', style: TextStyle(color: Color(0xEEFFFFFF), fontSize: 12, fontWeight: FontWeight.w700)),
        const Spacer(),
        Text('≈ Tide Data · ${widget.station?.name ?? "—"}',
          style: const TextStyle(color: Color(0xAA9CC1DE), fontSize: 11)),
      ]),
      const SizedBox(height: 4),
      const Text('NOAA CO-OPS astronomical predictions · updates every 20 min',
        style: TextStyle(color: Color(0xAA9CC1DE), fontSize: 10)),
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
  final DateTime? sunrise, sunset;
  final ui.Image? sunriseImg, sunsetImg, oceanImg;
  final String unit;
  _TidePainter({required this.curve, required this.hilo, required this.t0, required this.t1, required this.now,
    this.sunrise, this.sunset, this.sunriseImg, this.sunsetImg, this.oceanImg, required this.unit});

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
    // Same margin geometry as the PWA (index.html:886).
    const mL = 30.0, mR = 10.0, mT = 42.0, mB = 26.0;
    final plotW = size.width - mL - mR;
    final plotH = size.height - mT - mB;
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

    // 2) Grid lines every 2 tide units.
    final grid = Paint()..color = const Color(0xFF1D4C6A).withOpacity(.5)..strokeWidth = 0.7;
    final vFirst = (vmin / 2).ceil() * 2.0;
    for (double v = vFirst; v <= vmax; v += 2) {
      final gy = y(v);
      canvas.drawLine(Offset(mL, gy), Offset(mL + plotW, gy), grid);
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
    void drawSun(ui.Image? img, DateTime? t) {
      if (img == null || t == null) return;
      if (t.isBefore(t0.add(const Duration(minutes: 3))) || t.isAfter(t1.subtract(const Duration(minutes: 3)))) return;
      const sw = 78.0;
      final sh = sw * img.height / img.width;
      final xc = x(t);
      // waterline at 80% down (PWA magic wl=0.80)
      final rect = Rect.fromLTWH(xc - sw / 2, horizonY - sh * 0.80, sw, sh);
      canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        rect, Paint()..color = Colors.white.withOpacity(.95));
    }
    drawSun(sunriseImg, sunrise);
    drawSun(sunsetImg, sunset);

    // 4) Ocean band under the horizon.
    if (oceanImg != null) {
      final rect = Rect.fromLTWH(mL, horizonY - 5, plotW, (base - horizonY) + 14);
      canvas.drawImageRect(oceanImg!,
        Rect.fromLTWH(0, 0, oceanImg!.width.toDouble(), oceanImg!.height.toDouble()),
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
      // labels (collision guard: skip if within 50 px of the previous label)
      if (lastLx == null || (px - lastLx).abs() >= 50) {
        _text(canvas, _fv(p.v), Offset(px, py - 22), 11, FontWeight.w700, color, center: true);
        _text(canvas, _fmtTime(p.t), Offset(px, py + 12), 10, FontWeight.w600, const Color(0xFF9CC1DE), center: true);
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
      // pill above the circle
      final tipX = nx.clamp(mL + 30, mL + plotW - 30).toDouble();
      final tipY = math.max<double>(mT + 16, ny - 34);
      final pillRect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(tipX, tipY), width: 66, height: 32),
        const Radius.circular(9));
      canvas.drawRRect(pillRect, Paint()..color = const Color(0xFF1271E7));
      canvas.drawRRect(pillRect, Paint()..color = const Color(0xFF58A7FF)
        ..style = PaintingStyle.stroke..strokeWidth = 1.2);
      _text(canvas, 'Now', Offset(tipX, tipY - 10), 8.5, FontWeight.w700, Colors.white, center: true);
      _text(canvas, _fv(nearest.v), Offset(tipX, tipY + 3), 11, FontWeight.w800, Colors.white, center: true);
    }

    // 9) Y-axis label and x-tick times.
    _text(canvas, 'Tide Height ($unit)', Offset(mL - 22, mT + plotH / 2), 9, FontWeight.w600, const Color(0xAA9CC1DE), center: true, rotate: -math.pi / 2);
    var tt = DateTime(t0.year, t0.month, t0.day, t0.hour < 12 ? 0 : 12);
    while (tt.isBefore(t1)) {
      if (!tt.isBefore(t0)) {
        final gx = x(tt);
        _text(canvas, tt.hour == 0 ? '12 AM' : '${tt.hour == 12 ? 12 : tt.hour % 12} ${tt.hour < 12 ? "AM" : "PM"}',
          Offset(gx, base + 12), 9, FontWeight.w600, const Color(0xFFA9CAE2), center: true);
      }
      tt = tt.add(const Duration(hours: 12));
    }
  }

  void _text(Canvas canvas, String text, Offset at, double size, FontWeight w, Color c,
      {bool center = false, double rotate = 0}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: c, fontSize: size, fontWeight: w)),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(at.dx, at.dy);
    if (rotate != 0) canvas.rotate(rotate);
    tp.paint(canvas, center ? Offset(-tp.width / 2, -tp.height / 2) : Offset.zero);
    canvas.restore();
  }

  void _drawPlaceholder(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: const TextSpan(text: 'Loading tide predictions…',
        style: TextStyle(color: Color(0xAA9CC1DE), fontSize: 12)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
  }

  @override
  bool shouldRepaint(covariant _TidePainter old) => old.curve != curve || old.now != now
    || old.unit != unit || old.sunriseImg != sunriseImg || old.sunsetImg != sunsetImg || old.oceanImg != oceanImg;
}

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
