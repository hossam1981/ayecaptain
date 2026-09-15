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
  const Weather({this.tempF, this.windKt, this.gustKt, this.windDirDeg, this.weatherCode});
}

Future<Weather?> fetchWeather(LatLng at) async {
  final url = Uri.parse('https://api.open-meteo.com/v1/forecast?latitude=${at.latitude}&longitude=${at.longitude}'
      '&temperature_unit=fahrenheit&wind_speed_unit=kn'
      '&current=temperature_2m,wind_speed_10m,wind_gusts_10m,wind_direction_10m,weather_code');
  try {
    final r = await http.get(url).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return null;
    final c = (jsonDecode(r.body) as Map<String, dynamic>)['current'] as Map<String, dynamic>?;
    if (c == null) return null;
    return Weather(
      tempF: (c['temperature_2m'] as num?)?.toDouble(),
      windKt: (c['wind_speed_10m'] as num?)?.toDouble(),
      gustKt: (c['wind_gusts_10m'] as num?)?.toDouble(),
      windDirDeg: (c['wind_direction_10m'] as num?)?.toInt(),
      weatherCode: (c['weather_code'] as num?)?.toInt(),
    );
  } catch (_) { return null; }
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

  static const _homeCenter = LatLng(40.457, -74.15);

  @override
  void initState() {
    super.initState();
    _loadLand();
    _refreshWeather(_homeCenter);
    BoatProfile.load().then((p) { if (mounted) setState(() => _profile = p); });
    _wxTimer = Timer.periodic(const Duration(minutes: 20), (_) {
      _refreshWeather(_me ?? _homeCenter);
      _wxAt.clear();   // let stale grades fall through and refresh
      _gradeRouteWaypoints();
    });
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
    // follow the boat (and course-up rotate in nav mode)
    if (_follow) {
      _controller.move(here, math.max(_controller.camera.zoom, _navigating ? 16 : 14));
      if (_navigating) _controller.rotate(-h);   // rotate so heading is up
    }
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
                MarkerLayer(markers: [
                  for (int i = 0; i < _waypoints.length; i++)
                    Marker(
                      point: _waypoints[i],
                      width: 32, height: 32,
                      child: _WaypointPin(isDest: i == _waypoints.length - 1),
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
          Positioned(top: 12, left: 12, right: 12, child: _TopHud(
            speedKt: _speedKt, status: _statusText, accuracyM: _accuracyM,
            base: _base, onBaseChange: (b) => setState(() => _base = b),
            boatName: _profile.name.isEmpty ? 'Set up your boat' : _profile.name,
            onEditBoat: _openBoatProfile,
          )),
          // Nav bar — only shown while navigating (mirrors the PWA's #nav)
          if (_navigating && _waypoints.isNotEmpty && _legIdx < _waypoints.length && _me != null)
            Positioned(top: 78, left: 12, right: 12, child: _NavBar(
              from: _me!, target: _waypoints[_legIdx],
              legIdx: _legIdx, totalWps: _waypoints.length,
              nmToFinal: _routeNm(), etaMin: _etaMin(),
              headingDeg: _heading,
            )),
          Positioned(right: 12, bottom: 140, child: _RightRail(
            follow: _follow, picking: _picking, gpsOn: _gpsSub != null, smart: _smart,
            onFollow: () => setState(() {
              _follow = !_follow;
              if (_follow && _me != null) _controller.move(_me!, math.max(_controller.camera.zoom, 14));
            }),
            onGoto: () => setState(() { _picking = !_picking; }),
            onLocate: _startGps,
            onSmart: () { setState(() => _smart = !_smart); _recomputeRoute(); },
          )),
          Positioned(left: 12, right: 12, bottom: 12, child: _BottomSheet(
            weather: _weather, routeNm: _routeNm(), etaMin: _etaMin(), fuelGal: _fuelGal(),
            waypointCount: _waypoints.length, picking: _picking,
            unverified: _routeUnverified, navigating: _navigating,
            onClearRoute: () async { setState(() { _waypoints.clear(); _picking = false; _routedPath = null; _legIdx = 0; }); await _stopRide(); },
            onUndoRoute: () { if (_waypoints.isEmpty) return; setState(() { _waypoints.removeLast(); if (_legIdx >= _waypoints.length) _legIdx = math.max(0, _waypoints.length - 1); }); _recomputeRoute(); },
            onStart: _startRide, onStop: _stopRide,
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
  const _NavBar({required this.from, required this.target, required this.legIdx, required this.totalWps,
      required this.nmToFinal, required this.etaMin, required this.headingDeg});
  @override
  Widget build(BuildContext context) {
    final brg = _bearingDeg(from, target);
    final dm = _haversineM(from, target);
    final distStr = dm < 370 ? '${(dm * 3.28).round()} ft' : '${(dm/1852).toStringAsFixed(dm/1852<10?2:1)} nm';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: const Color(0xE60F2A44), borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
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

class _RightRail extends StatelessWidget {
  final bool follow, picking, gpsOn, smart;
  final VoidCallback onFollow, onGoto, onLocate, onSmart;
  const _RightRail({required this.follow, required this.picking, required this.gpsOn, required this.smart,
    required this.onFollow, required this.onGoto, required this.onLocate, required this.onSmart});
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        _btn(icon: Icons.navigation, active: follow, onTap: onFollow, tip: 'Follow my boat'),
        const SizedBox(height: 10),
        _btn(icon: Icons.add_location_alt, active: picking, onTap: onGoto, tip: 'Go to a point'),
        const SizedBox(height: 10),
        _btn(icon: Icons.route, active: smart, onTap: onSmart, tip: 'Smart routes (bend around land)'),
        const SizedBox(height: 10),
        _btn(icon: gpsOn ? Icons.my_location : Icons.location_searching, active: gpsOn, onTap: onLocate, tip: 'Track my location'),
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

class _BottomSheet extends StatelessWidget {
  final Weather? weather;
  final double routeNm;
  final int etaMin, waypointCount;
  final double fuelGal;
  final bool picking, unverified, navigating;
  final VoidCallback onClearRoute, onUndoRoute, onStart, onStop;
  const _BottomSheet({required this.weather, required this.routeNm, required this.etaMin, required this.fuelGal,
    required this.waypointCount, required this.picking, required this.unverified, required this.navigating,
    required this.onClearRoute, required this.onUndoRoute, required this.onStart, required this.onStop});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xE60F2A44), borderRadius: BorderRadius.circular(14)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (weather != null) Row(children: [
          _stat('Temp', '${weather!.tempF?.round() ?? '—'}°F'),
          const SizedBox(width: 14),
          _stat('Wind', '${weather!.windKt?.round() ?? '—'} kn'),
          const SizedBox(width: 14),
          _stat('Gust', '${weather!.gustKt?.round() ?? '—'} kn'),
          const SizedBox(width: 14),
          _stat('Dir', _dirName(weather!.windDirDeg?.toDouble() ?? 0)),
        ]),
        if (weather != null) const SizedBox(height: 10),
        Row(children: [
          Expanded(child: waypointCount == 0
              ? Text(picking ? 'Tap the map to drop a waypoint' : 'No route — tap Go-to to plan one',
                  style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 13))
              : Row(children: [
                  _stat('Route${unverified ? ' ⚠' : ''}', '${routeNm.toStringAsFixed(1)} nm'),
                  const SizedBox(width: 14),
                  _stat('ETA', etaMin >= 60 ? '${etaMin ~/ 60}h ${etaMin % 60}m' : '${math.max(1, etaMin)} min'),
                  const SizedBox(width: 14),
                  _stat('Points', '$waypointCount'),
                  if (fuelGal > 0) ...[
                    const SizedBox(width: 14),
                    _stat('Fuel', fuelGal < 10 ? '${fuelGal.toStringAsFixed(1)} gal' : '${fuelGal.round()} gal'),
                  ],
                ]),
          ),
          if (waypointCount > 0) ...[
            _bigBtn(navigating ? 'Stop' : 'Start', navigating ? const Color(0xFFD93A2B) : const Color(0xFF1F8A5B), navigating ? onStop : onStart),
            const SizedBox(width: 8),
            _smallBtn('Undo', onUndoRoute),
            const SizedBox(width: 8),
            _smallBtn('Clear', onClearRoute),
          ],
        ]),
      ]),
    );
  }
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
