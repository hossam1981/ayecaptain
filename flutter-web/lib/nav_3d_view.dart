// Nav-only real 3D camera view — MapLibre GL, not the flutter_map/CSS-tilt trick used
// everywhere else in this app. Deliberately scoped down (see the approved plan,
// 2026-09-26): this widget renders ONLY the boat, the active route line, and remaining
// waypoints, with a real GL camera (position/bearing/pitch). It replaces the existing
// flutter_map view ONLY while navigating (gated in main.dart on _navigating, a non-empty
// map style URL, and no active MOB/anchor-watch — those overlays aren't ported here).
//
// Every maplibre_gl API used below (MapLibreMap/MapLibreMapController/CameraPosition/
// CameraUpdate/SymbolManager/LineManager/CircleManager + their Options classes, including
// Line's and Circle's constructor shape and CircleOptions' exact field names) was
// independently confirmed against the actual pub.dev docs for the pinned version (0.27.1)
// before writing this — not guessed — per this session's established practice for
// unfamiliar interop. Code-reviewed against the live docs a second time; nothing flagged.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart' as ll;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:web/web.dart' as web;

import 'widgets/wind_layer.dart';

LatLng _toMlLatLng(ll.LatLng p) => LatLng(p.latitude, p.longitude);

class Nav3DRouteSegment {
  final ll.LatLng from, to;
  final Color color;
  final double width;
  const Nav3DRouteSegment(this.from, this.to, this.color, this.width);
}

class Nav3DView extends StatefulWidget {
  final String styleUrl;
  final String basemap;
  final ValueChanged<ll.LatLng> onMapTap;
  final ll.LatLng boatPosition;
  final double headingDeg;
  final bool follow;
  final List<Nav3DRouteSegment> routeSegments;
  final List<ll.LatLng> waypoints;
  // Wind & Gusts colour map (same data and colours as WindFieldLayer on the 2D map). Here it
  // is one pre-rendered image with the land already cut out, added to the map as an image
  // layer under the route. No value tags in this view.
  final bool windOn, windGusts;
  final List<List<ll.LatLng>>? Function()? landWays;
  // Height (px) of the app's bottom panels. The map's credit "i" button is lifted by this much
  // so it sits just above the panels instead of on top of them.
  final double bottomInset;
  const Nav3DView({
    super.key,
    required this.styleUrl,
    required this.basemap,
    required this.onMapTap,
    required this.boatPosition,
    required this.headingDeg,
    required this.follow,
    required this.routeSegments,
    required this.waypoints,
    this.windOn = false,
    this.windGusts = true,
    this.landWays,
    this.bottomInset = 0,
  });

  @override
  State<Nav3DView> createState() => _Nav3DViewState();
}

class _Nav3DViewState extends State<Nav3DView> {
  static const _boatIconName = 'nav3d-boat-icon';

  MapLibreMapController? _controller;
  Symbol? _boatSymbol;
  final List<Line> _routeAnnotations = [];
  final Map<int, Circle> _waypointCircles = {};
  bool _ready = false;
  bool _syncing = false;
  bool _needsSync = false;

  // wind overlay state
  WindGrid? _windGrid;
  bool _windBusy = false;
  DateTime? _windRetryAfter;
  String _windShown = ''; // what is on the map now: grid time | wind-or-gust | land loaded
  int _windSeq = 0;
  String? _windLayerId, _windSourceId;

  // The map's own on-page controls. maplibre_gl's web build cannot set the credit button's
  // margins ("setAttributionButtonMargins not available in web" in its source), so the corner
  // box that holds it is nudged up directly, and the credit text — which MapLibre opens by
  // default on a narrow screen — is closed once so only the "i" shows. Tapping the "i" still
  // opens it. The credit itself must stay: it is the map data's licence condition.
  bool _creditClosed = false;
  Timer? _tidyTimer;
  void _tidyMapControls() {
    try {
      final corners = web.document.querySelectorAll('.maplibregl-ctrl-bottom-left');
      for (var i = 0; i < corners.length; i++) {
        final el = corners.item(i) as web.Element?;
        el?.setAttribute('style', 'margin-bottom: ${widget.bottomInset.round()}px');
      }
      if (_creditClosed) return;
      final credits = web.document.querySelectorAll('.maplibregl-ctrl-attrib');
      for (var i = 0; i < credits.length; i++) {
        final el = credits.item(i) as web.Element?;
        final cls = el?.getAttribute('class') ?? '';
        if (el == null || !cls.contains('maplibregl-compact-show')) continue;
        el.setAttribute('class', cls.replaceAll('maplibregl-compact-show', '').trim());
        el.removeAttribute('open');
        _creditClosed = true;
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _tidyTimer?.cancel();
    super.dispose();
  }

  // MapLibre takes a complete style, not a flutter_map TileLayer. The selected
  // basemap needs a matching raster style while the navigation view is mounted.
  String get _style {
    if (widget.basemap == 'map') return widget.styleUrl;
    final urls = switch (widget.basemap) {
      'sat' => <String>[
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
        'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Transportation/MapServer/tile/{z}/{y}/{x}',
        'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
      ],
      'dark' => <String>[
        'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}',
        'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}',
      ],
      _ => <String>[
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}',
        // NOAA's cached tile grid starts at a different zoom/origin from XYZ.
        // Export by Web Mercator bounds so the chart aligns with this map.
        'https://gis.charttools.noaa.gov/arcgis/rest/services/MarineChart_Services/NOAACharts/MapServer/export?bbox={bbox-epsg-3857}&bboxSR=3857&imageSR=3857&size=256,256&format=png32&transparent=true&f=image',
      ],
    };
    return jsonEncode({
      'version': 8,
      'sources': {
        for (var i = 0; i < urls.length; i++)
          'base-$i': {
            'type': 'raster',
            'tiles': [urls[i]],
            'tileSize': 256,
          },
      },
      'layers': [
        for (var i = 0; i < urls.length; i++)
          {'id': 'base-$i', 'type': 'raster', 'source': 'base-$i'},
      ],
    });
  }

  @override
  void didUpdateWidget(covariant Nav3DView old) {
    super.didUpdateWidget(old);
    if (old.bottomInset != widget.bottomInset || !_creditClosed) _tidyMapControls();
    if (_ready) _syncMap();
  }

  Future<void> _onMapCreated(MapLibreMapController controller) async {
    _controller = controller;
  }

  // Docs (MapLibreMap.onStyleLoadedCallback): "you should only add annotations ... after
  // onStyleLoadedCallback has been called" — annotation managers are constructed here, not
  // in onMapCreated, and the boat icon is registered before first use.
  Future<void> _onStyleLoaded() async {
    final controller = _controller;
    if (controller == null) return;
    final bd = await rootBundle.load('assets/icons/boat-3d_small.png');
    await controller.addImage(_boatIconName, bd.buffer.asUint8List());
    if (!mounted) return;
    // The controller's annotation managers are ready at this callback and
    // belong to the current style. A new map/style gets fresh managers.
    _boatSymbol = null;
    _routeAnnotations.clear();
    _waypointCircles.clear();
    // a new style has none of the old layers
    _windLayerId = null;
    _windSourceId = null;
    _windShown = '';
    _tidyMapControls();
    // the credit box is filled in a moment after the style loads — tidy once more then
    _tidyTimer?.cancel();
    _tidyTimer = Timer(const Duration(milliseconds: 900), () { if (mounted) _tidyMapControls(); });
    _ready = true;
    await _syncMap();
  }

  Future<void> _syncMap() async {
    if (_syncing) {
      _needsSync = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _needsSync = false;
        await _applyMapState();
      } while (_needsSync && mounted);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _removeWind(MapLibreMapController controller) async {
    final l = _windLayerId, s = _windSourceId;
    _windLayerId = null;
    _windSourceId = null;
    if (l != null) {
      try {
        await controller.removeLayer(l);
      } catch (_) {}
    }
    if (s != null) {
      try {
        await controller.removeSource(s);
      } catch (_) {}
    }
  }

  // Keeps the wind image in step with the switch, the Wind/Gusts choice and what is on screen.
  // Called often (every map sync and when the camera stops); does nothing unless something
  // changed. New data is fetched when the view leaves the fetched box, zooms in a lot, or the
  // data is 20 min old — same rules as the 2D layer.
  Future<void> _syncWind() async {
    final controller = _controller;
    if (controller == null || !_ready || !mounted || _windBusy) return;
    _windBusy = true;
    try {
      if (!widget.windOn) {
        if (_windLayerId != null) await _removeWind(controller);
        _windShown = '';
        return;
      }
      final now = DateTime.now();
      final vr = await controller.getVisibleRegion();
      final cLon = (vr.southwest.longitude + vr.northeast.longitude) / 2;
      final cLat = (vr.southwest.latitude + vr.northeast.latitude) / 2;
      // a tilted view can "see" to the horizon — cap what counts as on screen
      final vhw = math.min((vr.northeast.longitude - vr.southwest.longitude) / 2, 0.45);
      final vhh = math.min((vr.northeast.latitude - vr.southwest.latitude) / 2, 0.34);
      var g = _windGrid;
      var need = g == null;
      if (g != null) {
        final inside = cLon - vhw >= g.west && cLon + vhw <= g.east && cLat - vhh >= g.south && cLat + vhh <= g.north;
        final gridW = g.east - g.west;
        final zoomedIn = vhw * 2 < gridW * 0.28 && gridW > 0.08;
        final stale = now.difference(g.fetchedAt).inMinutes >= 20;
        need = !inside || zoomedIn || stale;
      }
      final retry = _windRetryAfter;
      if (need && vhw > 1e-6 && vhh > 1e-6 && (retry == null || now.isAfter(retry))) {
        final ng = await fetchWindGrid(
          west: math.max(-180.0, cLon - vhw * 1.35),
          south: math.max(-80.0, cLat - vhh * 1.35),
          east: math.min(180.0, cLon + vhw * 1.35),
          north: math.min(80.0, cLat + vhh * 1.35),
        );
        if (ng == null) {
          _windRetryAfter = DateTime.now().add(const Duration(seconds: 30));
        } else {
          _windRetryAfter = null;
          _windGrid = ng;
          g = ng;
        }
      }
      if (g == null || !mounted) return;
      final ways = widget.landWays?.call();
      final key = '${g.fetchedAt.microsecondsSinceEpoch}|${widget.windGusts}|${ways != null}';
      if (key == _windShown) return;
      final png = await renderWindOverlayPng(g, gusts: widget.windGusts, landWays: ways);
      if (png == null || !mounted) return;
      await _removeWind(controller);
      final n = ++_windSeq;
      final src = 'aye-wind-src-$n', layer = 'aye-wind-layer-$n';
      await controller.addSource(
        src,
        ImageSourceProperties(
          url: 'data:image/png;base64,${base64Encode(png)}',
          // corners: top-left, top-right, bottom-right, bottom-left as [lon, lat]
          coordinates: <List<double>>[
            [g.west, g.north],
            [g.east, g.north],
            [g.east, g.south],
            [g.west, g.south],
          ],
        ),
      );
      // under the route line / waypoints / boat (the line layers are the lowest of those)
      final lineIds = controller.lineManager?.layerIds;
      final below = (lineIds != null && lineIds.isNotEmpty) ? lineIds.first : null;
      await controller.addRasterLayer(
        src,
        layer,
        const RasterLayerProperties(rasterOpacity: 0.6, rasterFadeDuration: 0),
        belowLayerId: below,
      );
      _windSourceId = src;
      _windLayerId = layer;
      _windShown = key;
    } catch (_) {
      _windRetryAfter = DateTime.now().add(const Duration(seconds: 30));
    } finally {
      _windBusy = false;
    }
  }

  Future<void> _applyMapState() async {
    final controller = _controller;
    if (controller == null || !_ready || !mounted) return;
    _syncWind(); // not awaited: a slow wind fetch must never hold up the boat/route updates

    // Boat marker.
    final boatOptions = SymbolOptions(
      geometry: _toMlLatLng(widget.boatPosition),
      iconImage: _boatIconName,
      iconRotate: widget.headingDeg,
      iconSize: 0.35,
    );
    if (_boatSymbol == null) {
      _boatSymbol = await controller.addSymbol(boatOptions);
    } else {
      await controller.updateSymbol(_boatSymbol!, boatOptions);
    }

    // Use the existing route grading from main.dart. Each segment draws 3/13
    // of its length so both verified and unverified paths keep their dashes.
    final options = <LineOptions>[
      for (final segment in widget.routeSegments)
        LineOptions(
          geometry: [
            _toMlLatLng(segment.from),
            _toMlLatLng(
              ll.LatLng(
                segment.from.latitude +
                    (segment.to.latitude - segment.from.latitude) * 3 / 13,
                segment.from.longitude +
                    (segment.to.longitude - segment.from.longitude) * 3 / 13,
              ),
            ),
          ],
          lineColor:
              '#${segment.color.value.toRadixString(16).padLeft(8, '0').substring(2)}',
          lineOpacity: segment.color.alpha / 255,
          lineWidth: segment.width,
        ),
    ];
    if (_routeAnnotations.length != options.length) {
      if (_routeAnnotations.isNotEmpty)
        await controller.removeLines(_routeAnnotations);
      _routeAnnotations
        ..clear()
        ..addAll(
          options.isEmpty ? <Line>[] : await controller.addLines(options),
        );
    } else {
      for (var i = 0; i < options.length; i++) {
        await controller.updateLine(_routeAnnotations[i], options[i]);
      }
    }

    // Remaining waypoints — plain colored dots for this MVP pass (no teardrop-pin asset
    // registered yet); last one (destination) drawn larger/red, others amber.
    for (var i = 0; i < widget.waypoints.length; i++) {
      final isDest = i == widget.waypoints.length - 1;
      final options = CircleOptions(
        geometry: _toMlLatLng(widget.waypoints[i]),
        circleRadius: isDest ? 9.0 : 7.0,
        circleColor: isDest ? '#D93A2B' : '#F2A93B',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2.0,
      );
      final existing = _waypointCircles[i];
      if (existing == null) {
        _waypointCircles[i] = await controller.addCircle(options);
      } else {
        await controller.updateCircle(existing, options);
      }
    }
    // Drop circles left over from a shorter waypoint list (e.g. after Undo).
    final stale = _waypointCircles.keys
        .where((i) => i >= widget.waypoints.length)
        .toList();
    for (final i in stale) {
      await controller.removeCircle(_waypointCircles[i]!);
      _waypointCircles.remove(i);
    }

    // Camera follow — course-up bearing (mirrors the existing flutter_map
    // _controller.rotate(-heading) behavior) with a real pitch instead of the CSS-tilt hack.
    if (!widget.follow) return;
    await controller.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: _toMlLatLng(widget.boatPosition),
          zoom: 16,
          bearing: widget.headingDeg,
          tilt: 60,
        ),
      ),
      duration: const Duration(milliseconds: 400),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MapLibreMap(
      styleString: _style,
      initialCameraPosition: CameraPosition(
        target: _toMlLatLng(widget.boatPosition),
        zoom: 16,
        bearing: widget.headingDeg,
        tilt: 60,
      ),
      // No compass box: this view always turns the map to the boat's heading, so the button did
      // nothing useful and sat on top of the Map/Chart/Sat/Dark switcher.
      compassEnabled: false,
      // Credit "i" bottom-left, lifted above the app's panels by _tidyMapControls().
      attributionButtonPosition: AttributionButtonPosition.bottomLeft,
      onMapCreated: _onMapCreated,
      onStyleLoadedCallback: _onStyleLoaded,
      onCameraIdle: _syncWind,
      onMapClick: (_, point) =>
          widget.onMapTap(ll.LatLng(point.latitude, point.longitude)),
    );
  }
}
