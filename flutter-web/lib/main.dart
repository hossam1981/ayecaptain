// Bayside — Flutter Web
//
// v0.2: extending the starter into a real (if minimal) chart plotter that mirrors the PWA on
// `main`: live GPS stream, boat marker rotating with heading, fading wake trail, tap-to-add
// waypoints with distance and ETA, current weather (Open-Meteo), and a Map/Chart/Sat basemap
// switcher matching the PWA's layers. Deliberately no smart-routes yet — that's the next slice.
//
// See NOTES-architecture.md on `main` for the broader "why PWA vs Flutter" note.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

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

// ------------------------------------------------------------------------------------------------
// basemap definitions (mirror the PWA's Map/Chart/Sat/Dark)
// ------------------------------------------------------------------------------------------------

enum Basemap { map, chart, sat, dark }

const _basemapNames = {
  Basemap.map: 'Map',
  Basemap.chart: 'Chart',
  Basemap.sat: 'Sat',
  Basemap.dark: 'Dark',
};

String _tileUrl(Basemap b) {
  switch (b) {
    case Basemap.map:
      return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}';
    case Basemap.chart:
      return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    case Basemap.sat:
      return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
    case Basemap.dark:
      return 'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png';
  }
}

// NOAA nautical chart overlay for Chart mode
const _noaaChartUrl = 'https://gis.charttools.noaa.gov/arcgis/rest/services/MarineChart_Services/NOAACharts/MapServer/tile/{z}/{y}/{x}';

// ------------------------------------------------------------------------------------------------
// weather (Open-Meteo, keyless)
// ------------------------------------------------------------------------------------------------

class Weather {
  final double? tempF;
  final double? windKt;
  final double? gustKt;
  final int? windDirDeg;
  final int? weatherCode;
  const Weather({this.tempF, this.windKt, this.gustKt, this.windDirDeg, this.weatherCode});
}

Future<Weather?> fetchWeather(LatLng at) async {
  final url = Uri.parse(
      'https://api.open-meteo.com/v1/forecast?latitude=${at.latitude}&longitude=${at.longitude}'
      '&temperature_unit=fahrenheit&wind_speed_unit=kn'
      '&current=temperature_2m,wind_speed_10m,wind_gusts_10m,wind_direction_10m,weather_code');
  try {
    final r = await http.get(url).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body);
    final c = j['current'] as Map<String, dynamic>?;
    if (c == null) return null;
    return Weather(
      tempF: (c['temperature_2m'] as num?)?.toDouble(),
      windKt: (c['wind_speed_10m'] as num?)?.toDouble(),
      gustKt: (c['wind_gusts_10m'] as num?)?.toDouble(),
      windDirDeg: (c['wind_direction_10m'] as num?)?.toInt(),
      weatherCode: (c['weather_code'] as num?)?.toInt(),
    );
  } catch (_) {
    return null;
  }
}

// ------------------------------------------------------------------------------------------------
// main map screen
// ------------------------------------------------------------------------------------------------

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
  final List<_TrailPoint> _trail = [];
  final List<LatLng> _waypoints = [];
  Weather? _weather;
  Timer? _wxTimer;
  String _statusText = 'Not tracking';

  static const _homeCenter = LatLng(40.457, -74.15); // Raritan Bay

  @override
  void initState() {
    super.initState();
    _refreshWeather(_homeCenter);
    _wxTimer = Timer.periodic(const Duration(minutes: 20), (_) {
      final at = _me ?? _homeCenter;
      _refreshWeather(at);
    });
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _wxTimer?.cancel();
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
      ).listen(_onFix, onError: (e) {
        if (mounted) setState(() => _statusText = 'GPS error');
      });
      setState(() => _statusText = 'Searching for GPS…');
    } catch (e) {
      setState(() => _statusText = 'GPS unavailable');
    }
  }

  void _onFix(Position p) {
    final here = LatLng(p.latitude, p.longitude);
    // heading: prefer GPS heading; fall back to bearing between fixes if the boat has actually moved
    double h = _heading;
    if (p.heading > 0) {
      h = p.heading;
    } else if (_me != null) {
      final d = _distanceMeters(_me!, here);
      if (d > 3) h = _bearingDeg(_me!, here);
    }
    // speed: prefer GPS speed; fall back to derived (mirrors the PWA's onFix)
    double s = _speedKt;
    final gpsSpd = p.speed;
    if (gpsSpd.isFinite && gpsSpd >= 0) {
      s = gpsSpd * 1.943844; // m/s -> knots
    } else if (_trail.isNotEmpty && _me != null) {
      final prev = _trail.last;
      final dtSec = (DateTime.now().millisecondsSinceEpoch - prev.tMs) / 1000.0;
      final dm = _distanceMeters(_me!, here);
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
    if (_follow) _controller.move(here, math.max(_controller.camera.zoom, 14));
  }

  void _handleMapTap(TapPosition _, LatLng ll) {
    if (!_picking) return;
    setState(() => _waypoints.add(ll));
  }

  double _routeNm() {
    if (_waypoints.isEmpty) return 0;
    final start = _me ?? _homeCenter;
    double m = _distanceMeters(start, _waypoints.first);
    for (int i = 1; i < _waypoints.length; i++) {
      m += _distanceMeters(_waypoints[i - 1], _waypoints[i]);
    }
    return m / 1852.0;
  }

  int _etaMin() {
    final nm = _routeNm();
    if (nm <= 0) return 0;
    final cruise = _speedKt > 1.5 ? _speedKt : 20.0;
    return (nm / cruise * 60).round();
  }

  @override
  Widget build(BuildContext context) {
    final routeLine = <LatLng>[
      if (_me != null) _me!,
      ..._waypoints,
    ];
    return Scaffold(
      body: SafeArea(
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
              TileLayer(
                urlTemplate: _tileUrl(_base),
                userAgentPackageName: 'net.bayside.flutter',
              ),
              if (_base == Basemap.chart)
                TileLayer(
                  urlTemplate: _noaaChartUrl,
                  userAgentPackageName: 'net.bayside.flutter',
                ),
              if (_trail.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _trail.map((t) => t.p).toList(),
                      color: const Color(0xAAFFFFFF),
                      strokeWidth: 4,
                    ),
                  ],
                ),
              if (routeLine.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: routeLine,
                      color: const Color(0xFFF2A93B),
                      strokeWidth: 4,
                      pattern: const StrokePattern.dashed(segments: [10, 8]),
                    ),
                  ],
                ),
              MarkerLayer(markers: [
                for (int i = 0; i < _waypoints.length; i++)
                  Marker(
                    point: _waypoints[i],
                    width: 32,
                    height: 32,
                    child: _WaypointPin(isDest: i == _waypoints.length - 1),
                  ),
                if (_me != null)
                  Marker(
                    point: _me!,
                    width: 44,
                    height: 44,
                    child: BoatMarker(headingDeg: _heading),
                  ),
              ]),
            ],
          ),
          // top HUD: speed + status + basemap switcher
          Positioned(top: 12, left: 12, right: 12, child: _TopHud(
            speedKt: _speedKt,
            status: _statusText,
            accuracyM: _accuracyM,
            base: _base,
            onBaseChange: (b) => setState(() => _base = b),
          )),
          // right rail: follow / go-to / locate
          Positioned(right: 12, bottom: 120, child: _RightRail(
            follow: _follow,
            picking: _picking,
            gpsOn: _gpsSub != null,
            onFollow: () => setState(() { _follow = !_follow; if (_follow && _me != null) _controller.move(_me!, math.max(_controller.camera.zoom, 14)); }),
            onGoto: () => setState(() { _picking = !_picking; }),
            onLocate: _startGps,
          )),
          // bottom sheet: weather + route summary
          Positioned(left: 12, right: 12, bottom: 12, child: _BottomSheet(
            weather: _weather,
            routeNm: _routeNm(),
            etaMin: _etaMin(),
            waypointCount: _waypoints.length,
            picking: _picking,
            onClearRoute: () => setState(() { _waypoints.clear(); _picking = false; }),
            onUndoRoute: () { if (_waypoints.isEmpty) return; setState(() => _waypoints.removeLast()); },
          )),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------
// widgets
// ------------------------------------------------------------------------------------------------

class BoatMarker extends StatelessWidget {
  final double headingDeg;
  const BoatMarker({super.key, required this.headingDeg});
  @override
  Widget build(BuildContext context) => Transform.rotate(
        angle: headingDeg * math.pi / 180,
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFF2A93B),
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
          ),
          child: const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Icon(Icons.navigation, color: Colors.white, size: 26),
          ),
        ),
      );
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
  const _TopHud({required this.speedKt, required this.status, required this.accuracyM, required this.base, required this.onBaseChange});
  @override
  Widget build(BuildContext context) => Row(children: [
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
        const Spacer(),
        _BaseSwitcher(base: base, onChange: onBaseChange),
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
          for (final b in Basemap.values)
            _basemapButton(b),
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
  final bool follow, picking, gpsOn;
  final VoidCallback onFollow, onGoto, onLocate;
  const _RightRail({required this.follow, required this.picking, required this.gpsOn, required this.onFollow, required this.onGoto, required this.onLocate});
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        _railButton(icon: Icons.navigation, active: follow, onTap: onFollow, tooltip: 'Follow my boat'),
        const SizedBox(height: 10),
        _railButton(icon: Icons.add_location_alt, active: picking, onTap: onGoto, tooltip: 'Go to a point'),
        const SizedBox(height: 10),
        _railButton(icon: gpsOn ? Icons.my_location : Icons.location_searching, active: gpsOn, onTap: onLocate, tooltip: 'Track my location'),
      ]);
  Widget _railButton({required IconData icon, required bool active, required VoidCallback onTap, required String tooltip}) => Material(
        color: active ? const Color(0xFF2E6F9E) : const Color(0xFFF4F8FA),
        shape: const CircleBorder(),
        elevation: 3,
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 46,
              height: 46,
              child: Icon(icon, color: active ? Colors.white : const Color(0xFF2E6F9E)),
            ),
          ),
        ),
      );
}

class _BottomSheet extends StatelessWidget {
  final Weather? weather;
  final double routeNm;
  final int etaMin;
  final int waypointCount;
  final bool picking;
  final VoidCallback onClearRoute, onUndoRoute;
  const _BottomSheet({required this.weather, required this.routeNm, required this.etaMin, required this.waypointCount, required this.picking, required this.onClearRoute, required this.onUndoRoute});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xE60F2A44), borderRadius: BorderRadius.circular(14)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        // weather row
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
        // route row
        Row(children: [
          Expanded(child: waypointCount == 0
              ? Text(picking ? 'Tap the map to drop a waypoint' : 'No route — tap Go-to to plan one',
                  style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 13))
              : Row(children: [
                  _stat('Route', '${routeNm.toStringAsFixed(1)} nm'),
                  const SizedBox(width: 14),
                  _stat('ETA', etaMin >= 60 ? '${etaMin ~/ 60}h ${etaMin % 60}m' : '${math.max(1, etaMin)} min'),
                  const SizedBox(width: 14),
                  _stat('Points', '$waypointCount'),
                ]),
          ),
          if (waypointCount > 0) ...[
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
  Widget _smallBtn(String label, VoidCallback onTap) => Material(
        color: const Color(0x33FFFFFF),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7), child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
        ),
      );
}

// ------------------------------------------------------------------------------------------------
// helpers
// ------------------------------------------------------------------------------------------------

class _TrailPoint {
  final LatLng p;
  final int tMs;
  _TrailPoint(this.p, this.tMs);
}

double _distanceMeters(LatLng a, LatLng b) {
  const R = 6371000.0;
  final la1 = a.latitude * math.pi / 180;
  final la2 = b.latitude * math.pi / 180;
  final dla = (b.latitude - a.latitude) * math.pi / 180;
  final dlo = (b.longitude - a.longitude) * math.pi / 180;
  final s = math.pow(math.sin(dla / 2), 2) + math.cos(la1) * math.cos(la2) * math.pow(math.sin(dlo / 2), 2);
  return 2 * R * math.asin(math.sqrt(s.toDouble()));
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
