// Wind & Gusts map layer — a colour map of forecast wind (or gust) speed drawn on the map,
// over water only.
//
// DATA (real, but a forecast — not sensor measurements): Open-Meteo's free forecast API is asked
// for `wind_speed_10m` / `wind_gusts_10m` (knots) at a 6 x 7 grid of points covering the visible
// map plus a margin. The values between grid points are blended (bilinear), so the picture is
// smooth but only as detailed as the grid — it is coarser than a real weather-model render.
// The grid is refetched when the map moves outside it, zooms in a lot, or the data is 20 min old.
//
// WATER ONLY: the bundled NJ/NY land polygons (assets/land-njny.json, the same data Smart routes
// uses) are erased from the colour map, plus the inland blocks that file has no data for (see
// _inlandRows). Outside that file's area there is no land data, so the colours cover land too.
//
// This is net-new on the flutter branch — the PWA on `main` has no equivalent, so there is no
// index.html spec to match here.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
// `show LatLng` on purpose: latlong2 also exports a `Path<LatLng>` class that collides with
// dart:ui's Path (see CLAUDE.md, recurring Dart bug #1). Paths in this file are always ui.Path.
import 'package:latlong2/latlong.dart' show LatLng;

/// Top of the colour scale, in knots. Anything stronger shows the last colour.
const double windScaleMaxKt = 50;

// The colour scale: [knots, red, green, blue]. Calm blue -> green -> yellow -> red -> purple.
const List<List<double>> _ramp = [
  [0, 30, 75, 216],
  [6, 30, 155, 255],
  [11, 22, 214, 200],
  [16, 53, 208, 79],
  [21, 242, 226, 41],
  [27, 255, 154, 31],
  [34, 255, 59, 47],
  [42, 208, 32, 122],
  [50, 123, 47, 247],
];

/// The scale's colours and their positions (0..1), for drawing the legend bar. Same length.
final List<Color> windScaleColors = [
  for (final s in _ramp) Color.fromARGB(255, s[1].round(), s[2].round(), s[3].round()),
];
final List<double> windScaleStops = [for (final s in _ramp) s[0] / windScaleMaxKt];

/// The scale colour for a speed in knots (used by the map labels).
Color windScaleColor(double kt) {
  final px = Uint8List(4);
  _rampInto(kt, 1.0, px, 0);
  return Color.fromARGB(255, px[0], px[1], px[2]);
}

// Writes the colour for [kt] into [px] at offset [o] as premultiplied RGBA.
void _rampInto(double kt, double alpha, Uint8List px, int o) {
  final v = kt.isFinite ? math.min(windScaleMaxKt, math.max(0.0, kt)) : 0.0;
  var i = 0;
  while (i < _ramp.length - 2 && v > _ramp[i + 1][0]) {
    i++;
  }
  final a = _ramp[i], b = _ramp[i + 1];
  final t = math.min(1.0, math.max(0.0, (v - a[0]) / (b[0] - a[0])));
  px[o] = ((a[1] + (b[1] - a[1]) * t) * alpha).round();
  px[o + 1] = ((a[2] + (b[2] - a[2]) * t) * alpha).round();
  px[o + 2] = ((a[3] + (b[3] - a[3]) * t) * alpha).round();
  px[o + 3] = (255 * alpha).round();
}

// ---- web-mercator helpers (same projection the map uses) ----
double _mercX(double lon) => (lon + 180.0) / 360.0;
double _mercY(double lat) {
  final r = lat * math.pi / 180.0;
  return (1.0 - math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi) / 2.0;
}

double _latFromMercY(double my) {
  final x = math.pi * (1.0 - 2.0 * my);
  final sinh = (math.exp(x) - math.exp(-x)) / 2.0;
  return math.atan(sinh) * 180.0 / math.pi;
}

// Everything drawn by the layer (colour image + land) is laid out in "local" units: mercator
// offsets from a fixed anchor, scaled up so the numbers are a comfortable size for the renderer.
// One matrix per frame then maps local units to screen pixels (handles pan, zoom and rotation).
const double _anchorLat = 40.5, _anchorLon = -74.0;
const double _localScale = 1048576.0;
final double _anchorMx = _mercX(_anchorLon), _anchorMy = _mercY(_anchorLat);
double _localX(double lon) => (_mercX(lon) - _anchorMx) * _localScale;
double _localY(double lat) => (_mercY(lat) - _anchorMy) * _localScale;

/// One fetched grid of forecast wind and gust speeds (knots), row by row from north to south.
class WindGrid {
  final double west, south, east, north;
  final int cols, rows;
  final List<double> wind, gust;
  final DateTime fetchedAt;
  const WindGrid({
    required this.west,
    required this.south,
    required this.east,
    required this.north,
    required this.cols,
    required this.rows,
    required this.wind,
    required this.gust,
    required this.fetchedAt,
  });
}

// Replaces missing values with the average of the others. False if there is nothing usable.
bool _fillGaps(List<double> v) {
  var sum = 0.0;
  var n = 0;
  for (final x in v) {
    if (x.isFinite) {
      sum += x;
      n++;
    }
  }
  if (n == 0) return false;
  final mean = sum / n;
  for (var i = 0; i < v.length; i++) {
    if (!v[i].isFinite) v[i] = mean;
  }
  return true;
}

/// Asks Open-Meteo for wind + gust at a cols x rows grid over the given box. Null on any failure.
Future<WindGrid?> fetchWindGrid({
  required double west,
  required double south,
  required double east,
  required double north,
  int cols = 6,
  int rows = 7,
}) async {
  // rows are evenly spaced in mercator (screen) space, so the image maps straight onto the map
  final myN = _mercY(north), myS = _mercY(south);
  final lats = <String>[], lons = <String>[];
  for (var r = 0; r < rows; r++) {
    final lat = _latFromMercY(myN + (myS - myN) * r / (rows - 1));
    for (var c = 0; c < cols; c++) {
      lats.add(lat.toStringAsFixed(3));
      lons.add((west + (east - west) * c / (cols - 1)).toStringAsFixed(3));
    }
  }
  final url = Uri.parse('https://api.open-meteo.com/v1/forecast'
      '?latitude=${lats.join(',')}&longitude=${lons.join(',')}'
      '&current=wind_speed_10m,wind_gusts_10m&wind_speed_unit=kn');
  try {
    final res = await http.get(url).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return null;
    final dynamic body = jsonDecode(res.body);
    // several locations -> a JSON list (same order as asked); a single one -> a bare object
    final List<dynamic> list = body is List ? body : <dynamic>[body];
    if (list.length != rows * cols) return null;
    final wind = List<double>.filled(rows * cols, double.nan);
    final gust = List<double>.filled(rows * cols, double.nan);
    for (var i = 0; i < list.length; i++) {
      final dynamic item = list[i];
      if (item is! Map) continue;
      final dynamic cur = item['current'];
      if (cur is! Map) continue;
      final dynamic w = cur['wind_speed_10m'];
      final dynamic g = cur['wind_gusts_10m'];
      if (w is num) wind[i] = w.toDouble();
      if (g is num) gust[i] = g.toDouble();
    }
    if (!_fillGaps(wind) || !_fillGaps(gust)) return null;
    return WindGrid(
      west: west,
      south: south,
      east: east,
      north: north,
      cols: cols,
      rows: rows,
      wind: wind,
      gust: gust,
      fetchedAt: DateTime.now(),
    );
  } catch (_) {
    return null;
  }
}

// Value at a fractional position in the grid: s = 0..1 west->east, t = 0..1 north->south.
double _sample(WindGrid g, List<double> v, double s, double t) {
  final gx = s * (g.cols - 1), gy = t * (g.rows - 1);
  final c0 = math.max(0, math.min(gx.floor(), g.cols - 2));
  final r0 = math.max(0, math.min(gy.floor(), g.rows - 2));
  final fx = gx - c0, fy = gy - r0;
  final a = v[r0 * g.cols + c0], b = v[r0 * g.cols + c0 + 1];
  final c = v[(r0 + 1) * g.cols + c0], d = v[(r0 + 1) * g.cols + c0 + 1];
  return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy;
}

// Is this point inside any land polygon? [boxes] are [west, south, east, north] per polygon.
bool _onLand(double lat, double lon, List<List<LatLng>> ways, List<List<double>> boxes) {
  for (var k = 0; k < ways.length; k++) {
    final bb = boxes[k];
    if (lon < bb[0] || lon > bb[2] || lat < bb[1] || lat > bb[3]) continue;
    final ring = ways[k];
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final yi = ring[i].latitude, yj = ring[j].latitude;
      if ((yi > lat) != (yj > lat)) {
        final xi = ring[i].longitude, xj = ring[j].longitude;
        if (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) inside = !inside;
      }
    }
    if (inside) return true;
  }
  return false;
}

// INLAND FILL. The land file comes from NOAA harbour charts, which only cover a strip near the
// coast — further inland there are no land shapes at all, so the colours used to show there.
// This table marks the 0.075-degree blocks of the file's area (lon -75..-73.5, lat 38.85..40.95)
// that have no chart data and are land. Each row is one block-row from north to south, each
// character one block from west to east, '1' = inland land. It was worked out offline from
// assets/land-njny.json (a block with no data takes the land/water state of the charted edge
// next to it) — see tool/inland_tiles_proto.py. Regenerate it if the land file is rebuilt.
// Outside the file's area nothing is known, so the colours still cover land there.
const double _tileDeg = 0.075;
const int _tileIx0 = -1000; // west edge = _tileIx0 * _tileDeg = -75.0
const int _tileIyTop = 545; // first row covers lat 40.875..40.95
const List<String> _inlandRows = [
  '00000000000000000000',
  '11111111111000000000',
  '11111111111000000011',
  '11111111110000001100',
  '11111111110000000000',
  '11111111000000000000',
  '11111111000000000000',
  '11111111111100000000',
  '11111111111100000000',
  '11001111111100000000',
  '11001111111100000000',
  '00001111111000000000',
  '00111111111000000000',
  '11111111110000000000',
  '11111111110000000000',
  '11111111110000000000',
  '11111111110000000000',
  '11111111100000000000',
  '11111100000000000000',
  '11111110000000000000',
  '11101100000000000000',
  '11100000000000000000',
  '11100000000000000000',
  '11100000000000000000',
  '11000000000000000000',
  '10000000000000000000',
  '00000000000000000000',
  '00000000000000000000',
];

// One value tag on the map: position in local units + the forecast wind and gust there.
class _WindLabel {
  const _WindLabel(this.x, this.y, this.wind, this.gust);
  final double x, y, wind, gust;
}

const int _upsample = 16; // image pixels per grid cell

// Turns one grid of knots into a small colour image (values blended between grid points,
// outer edge faded out so the layer never ends in a hard line).
Future<ui.Image> _fieldImage(WindGrid g, List<double> v) {
  final w = (g.cols - 1) * _upsample + 1, h = (g.rows - 1) * _upsample + 1;
  final px = Uint8List(w * h * 4);
  for (var j = 0; j < h; j++) {
    final gy = j / _upsample;
    final r0 = math.min(gy.floor(), g.rows - 2);
    final fy = gy - r0;
    for (var i = 0; i < w; i++) {
      final gx = i / _upsample;
      final c0 = math.min(gx.floor(), g.cols - 2);
      final fx = gx - c0;
      final a = v[r0 * g.cols + c0], b = v[r0 * g.cols + c0 + 1];
      final c = v[(r0 + 1) * g.cols + c0], d = v[(r0 + 1) * g.cols + c0 + 1];
      final kt = (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy;
      final edge = math.min(math.min(i, w - 1 - i), math.min(j, h - 1 - j));
      final alpha = edge >= 8 ? 1.0 : edge / 8.0;
      _rampInto(kt, alpha, px, (j * w + i) * 4);
    }
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, (ui.Image img) => done.complete(img));
  return done.future;
}

/// The legend bar for the colour scale: gradient + 0..50 kn ticks.
class WindScaleBar extends StatelessWidget {
  const WindScaleBar({super.key});
  @override
  Widget build(BuildContext context) {
    const tick = TextStyle(color: Color(0xFFBBD6EC), fontSize: 11, fontWeight: FontWeight.w600);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        height: 8,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          // 9 colours => explicit, equal-length stops
          gradient: LinearGradient(colors: windScaleColors, stops: windScaleStops),
        ),
      ),
      const SizedBox(height: 3),
      const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('0', style: tick),
        Text('10', style: tick),
        Text('20', style: tick),
        Text('30', style: tick),
        Text('40', style: tick),
        Text('50 kn', style: tick),
      ]),
    ]);
  }
}

/// Map layer: put it in FlutterMap's `children`. Keep it in the list all the time and switch it
/// with [enabled] (so toggling never shifts the layers after it).
class WindFieldLayer extends StatefulWidget {
  const WindFieldLayer({
    super.key,
    required this.enabled,
    required this.gusts,
    this.landWays,
    this.opacity = 0.6,
  });

  final bool enabled;

  /// true = colour by gust speed, false = by sustained wind speed.
  final bool gusts;

  /// Returns the land polygons once they are loaded (null before that).
  final List<List<LatLng>>? Function()? landWays;
  final double opacity;

  @override
  State<WindFieldLayer> createState() => _WindFieldLayerState();
}

class _WindFieldLayerState extends State<WindFieldLayer> {
  WindGrid? _grid;
  ui.Image? _windImg, _gustImg;
  ui.Path? _landPath;
  ui.Path? _inlandPath; // the no-data inland blocks, kept apart from the polygons (see _buildLand)
  List<List<LatLng>>? _landWays;
  List<List<double>>? _landBoxes;
  List<_WindLabel>? _labels; // picked once per grid (and again when the land data arrives)
  Timer? _debounce;
  LatLngBounds? _pending;
  String _pendingKey = '';
  bool _busy = false;
  DateTime? _retryAfter;

  @override
  void dispose() {
    _debounce?.cancel();
    _windImg?.dispose();
    _gustImg?.dispose();
    super.dispose();
  }

  ui.Path? _buildLand(List<List<LatLng>>? ways) {
    if (ways == null || ways.isEmpty) return null;
    final p = ui.Path();
    final boxes = <List<double>>[];
    final all = List<List<LatLng>>.of(ways); // copy: the inland blocks are added to it below
    for (final way in ways) {
      var w = 180.0, s = 90.0, e = -180.0, n = -90.0;
      for (final pt in way) {
        if (pt.longitude < w) w = pt.longitude;
        if (pt.longitude > e) e = pt.longitude;
        if (pt.latitude < s) s = pt.latitude;
        if (pt.latitude > n) n = pt.latitude;
      }
      boxes.add([w, s, e, n]);
      if (way.length < 3) continue;
      p.moveTo(_localX(way[0].longitude), _localY(way[0].latitude));
      for (var i = 1; i < way.length; i++) {
        p.lineTo(_localX(way[i].longitude), _localY(way[i].latitude));
      }
      p.close();
    }
    // inland blocks with no chart data (see _inlandRows). Grown by a hair so no thin line of
    // colour is left where a block meets the charted land next to it.
    // They go in their own path: in one shared path, a block overlapping a polygon wound the
    // other way would cancel out and leave an unfilled sliver.
    final blocks = ui.Path();
    const grow = 0.0004;
    for (var r = 0; r < _inlandRows.length; r++) {
      final row = _inlandRows[r];
      for (var c = 0; c < row.length; c++) {
        if (row.codeUnitAt(c) != 0x31) continue; // '1'
        final w = (_tileIx0 + c) * _tileDeg - grow, e = (_tileIx0 + c + 1) * _tileDeg + grow;
        final s = (_tileIyTop - r) * _tileDeg - grow, n = (_tileIyTop - r + 1) * _tileDeg + grow;
        blocks.addRect(Rect.fromLTRB(_localX(w), _localY(n), _localX(e), _localY(s)));
        all.add([LatLng(n, w), LatLng(n, e), LatLng(s, e), LatLng(s, w)]);
        boxes.add([w, s, e, n]);
      }
    }
    _inlandPath = blocks;
    _landWays = all;
    _landBoxes = boxes;
    _labels = null; // re-pick now that land is known, so no tag sits on land
    return p;
  }

  // Picks up to 5 spots on the water for value tags: the strongest gust first, then spots as
  // far apart from each other as possible. The values are the same forecast grid the colours
  // use, blended to that spot. Outside the land file's area nothing is known to be land, so a
  // tag can end up over land there.
  List<_WindLabel> _pickLabels(WindGrid g) {
    final ways = _landWays, boxes = _landBoxes;
    final myN = _mercY(g.north), myS = _mercY(g.south);
    final cand = <List<double>>[]; // [s, t, lat, lon, wind, gust]
    // 0.30..0.70 of the fetched box is the middle of the screen (the box is 1.7x the screen, and
    // a rotated map makes it bigger still); the first version used 0.22..0.78 and most tags
    // landed at the screen edges or under the HUD, so only one showed.
    for (var j = 0; j < 9; j++) {
      final t = 0.30 + 0.34 * j / 8;
      final lat = _latFromMercY(myN + (myS - myN) * t);
      for (var i = 0; i < 7; i++) {
        final s = 0.30 + 0.40 * i / 6;
        final lon = g.west + (g.east - g.west) * s;
        if (ways != null && boxes != null && _onLand(lat, lon, ways, boxes)) continue;
        cand.add([s, t, lat, lon, _sample(g, g.wind, s, t), _sample(g, g.gust, s, t)]);
      }
    }
    if (cand.isEmpty) return const <_WindLabel>[];
    var best = cand[0];
    for (final c in cand) {
      if (c[5] > best[5]) best = c;
    }
    final picked = <List<double>>[best];
    while (picked.length < 5) {
      List<double>? far;
      var farD = 0.0;
      for (final c in cand) {
        var d = double.infinity;
        for (final p in picked) {
          final dd = math.sqrt((c[0] - p[0]) * (c[0] - p[0]) + (c[1] - p[1]) * (c[1] - p[1]));
          if (dd < d) d = dd;
        }
        if (d > farD) {
          farD = d;
          far = c;
        }
      }
      if (far == null || farD < 0.13) break;
      picked.add(far);
    }
    return [for (final p in picked) _WindLabel(_localX(p[3]), _localY(p[2]), p[4], p[5])];
  }

  // A value tag: dark chip with the scale colour as its rim, a short stem and a dot on the spot.
  Widget _labelWidget(_WindLabel l, double sx, double sy) {
    final kt = widget.gusts ? l.gust : l.wind;
    final c = windScaleColor(kt);
    return Positioned(
      left: sx,
      top: sy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -1.0),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xE6071B2E),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: c, width: 1.4),
              boxShadow: [BoxShadow(color: c.withOpacity(.45), blurRadius: 10)],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.gusts ? 'Gust' : 'Wind',
                  style: const TextStyle(color: Color(0xFFBBD6EC), fontSize: 11, fontWeight: FontWeight.w600, height: 1.1)),
              Text('${kt.round()} kn',
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800, height: 1.15)),
            ]),
          ),
          Container(width: 1.5, height: 7, color: c),
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(shape: BoxShape.circle, color: c, border: Border.all(color: Colors.white, width: 1.5)),
          ),
        ]),
      ),
    );
  }

  // Decides whether new data is needed for what is on screen, and if so fetches it shortly
  // (debounced, so dragging the map does not fire a request per frame).
  void _schedule(LatLngBounds vb) {
    final now = DateTime.now();
    final retry = _retryAfter;
    if (retry != null && now.isBefore(retry)) return;
    final g = _grid;
    if (g != null) {
      final inside = vb.west >= g.west && vb.east <= g.east && vb.south >= g.south && vb.north <= g.north;
      final gridW = g.east - g.west;
      final zoomedIn = (vb.east - vb.west) < gridW * 0.28 && gridW > 0.08;
      final stale = now.difference(g.fetchedAt).inMinutes >= 20;
      if (inside && !zoomedIn && !stale) return;
    }
    final key = '${vb.west.toStringAsFixed(3)},${vb.south.toStringAsFixed(3)},'
        '${vb.east.toStringAsFixed(3)},${vb.north.toStringAsFixed(3)}';
    if (key == _pendingKey && (_debounce?.isActive ?? false)) return;
    _pendingKey = key;
    _pending = vb;
    _debounce?.cancel();
    _debounce = Timer(Duration(milliseconds: g == null ? 150 : 700), _fetchPending);
  }

  Future<void> _fetchPending() async {
    final vb = _pending;
    if (vb == null || _busy || !mounted) return;
    _busy = true;
    try {
      // fetch a box 35% bigger than the screen on every side, so small pans need no new request
      final w = vb.east - vb.west, h = vb.north - vb.south;
      final west = math.max(-180.0, vb.west - w * 0.35);
      final east = math.min(180.0, vb.east + w * 0.35);
      final south = math.max(-80.0, vb.south - h * 0.35);
      final north = math.min(80.0, vb.north + h * 0.35);
      if (east - west < 1e-6 || north - south < 1e-6) return;
      final g = await fetchWindGrid(west: west, south: south, east: east, north: north);
      if (g == null) {
        _retryAfter = DateTime.now().add(const Duration(seconds: 30));
        return;
      }
      final wi = await _fieldImage(g, g.wind);
      final gi = await _fieldImage(g, g.gust);
      if (!mounted) {
        wi.dispose();
        gi.dispose();
        return;
      }
      final oldW = _windImg, oldG = _gustImg;
      setState(() {
        _grid = g;
        _labels = null; // new data => pick the tags again
        _windImg = wi;
        _gustImg = gi;
        _retryAfter = null;
      });
      // free the previous images once the frame using the new ones has been drawn
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldW?.dispose();
        oldG?.dispose();
      });
    } catch (_) {
      _retryAfter = DateTime.now().add(const Duration(seconds: 30));
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    final camera = MapCamera.of(context);
    _landPath ??= _buildLand(widget.landWays?.call());
    _schedule(camera.visibleBounds);
    final img = widget.gusts ? _gustImg : _windImg;
    final g = _grid;
    if (img == null || g == null) return const SizedBox.shrink();

    // local units -> screen pixels, from three reference points (works with a rotated map)
    final sA = camera.latLngToScreenPoint(const LatLng(_anchorLat, _anchorLon));
    final sB = camera.latLngToScreenPoint(const LatLng(_anchorLat, _anchorLon + 1.0));
    final sC = camera.latLngToScreenPoint(const LatLng(_anchorLat - 1.0, _anchorLon));
    final bx = _localX(_anchorLon + 1.0), cy = _localY(_anchorLat - 1.0);
    final m = Float64List(16);
    m[0] = (sB.x - sA.x) / bx;
    m[1] = (sB.y - sA.y) / bx;
    m[4] = (sC.x - sA.x) / cy;
    m[5] = (sC.y - sA.y) / cy;
    m[10] = 1.0;
    m[12] = sA.x.toDouble();
    m[13] = sA.y.toDouble();
    m[15] = 1.0;

    // where the image goes, in local units (grid points sit at pixel centres => half a pixel out)
    final x0 = _localX(g.west), x1 = _localX(g.east), y0 = _localY(g.north), y1 = _localY(g.south);
    final hx = (x1 - x0) / (img.width - 1) / 2.0, hy = (y1 - y0) / (img.height - 1) / 2.0;
    final dst = Rect.fromLTRB(x0 - hx, y0 - hy, x1 + hx, y1 + hy);

    // value tags: local units -> screen with the same matrix; only the ones on screen are built
    final labels = _labels ??= _pickLabels(g);
    final sw = camera.nonRotatedSize.x, sh = camera.nonRotatedSize.y;
    final tags = <Widget>[];
    for (final l in labels) {
      final sx = m[0] * l.x + m[4] * l.y + m[12];
      final sy = m[1] * l.x + m[5] * l.y + m[13];
      if (sx < 30 || sx > sw - 30 || sy < 60 || sy > sh - 10) continue;
      tags.add(_labelWidget(l, sx, sy));
    }

    return IgnorePointer(
      child: SizedBox.expand(
        child: Stack(fit: StackFit.expand, children: [
          RepaintBoundary(
            child: CustomPaint(
              painter: _WindFieldPainter(
                  image: img, dst: dst, land: _landPath, inland: _inlandPath, m: m, opacity: widget.opacity),
            ),
          ),
          ...tags,
        ]),
      ),
    );
  }
}

class _WindFieldPainter extends CustomPainter {
  _WindFieldPainter({
    required this.image,
    required this.dst,
    required this.land,
    required this.inland,
    required this.m,
    required this.opacity,
  });
  final ui.Image image;
  final Rect dst;
  final ui.Path? land, inland;
  final Float64List m;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    // Draw into a layer so the land can be erased from the colours only (not from the map
    // underneath); the layer is then laid over the map at [opacity].
    canvas.saveLayer(Offset.zero & size, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    canvas.transform(m);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final erase = Paint()
      ..blendMode = BlendMode.dstOut
      ..color = const Color(0xFF000000);
    final l = land, b = inland;
    if (l != null) canvas.drawPath(l, erase);
    if (b != null) canvas.drawPath(b, erase);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WindFieldPainter old) {
    if (old.image != image || old.land != land || old.inland != inland || old.dst != dst || old.opacity != opacity) return true;
    for (var i = 0; i < 16; i++) {
      if (old.m[i] != m[i]) return true;
    }
    return false;
  }
}
