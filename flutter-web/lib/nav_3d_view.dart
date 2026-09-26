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

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart' as ll;
import 'package:maplibre_gl/maplibre_gl.dart';

LatLng _toMlLatLng(ll.LatLng p) => LatLng(p.latitude, p.longitude);

class Nav3DView extends StatefulWidget {
  final String styleUrl;
  final String basemap;
  final ValueChanged<ll.LatLng> onMapTap;
  final ll.LatLng boatPosition;
  final double headingDeg;
  final List<ll.LatLng> routeLine;
  final List<ll.LatLng> waypoints;
  const Nav3DView({
    super.key,
    required this.styleUrl,
    required this.basemap,
    required this.onMapTap,
    required this.boatPosition,
    required this.headingDeg,
    required this.routeLine,
    required this.waypoints,
  });

  @override
  State<Nav3DView> createState() => _Nav3DViewState();
}

class _Nav3DViewState extends State<Nav3DView> {
  static const _boatIconName = 'nav3d-boat-icon';
  static const _boatSymbolId = 'nav3d-boat';
  static const _routeLineId = 'nav3d-route';

  MapLibreMapController? _controller;
  SymbolManager? _symbolManager;
  LineManager? _lineManager;
  CircleManager? _circleManager;
  Symbol? _boatSymbol;
  Line? _routeLineAnnotation;
  final Map<int, Circle> _waypointCircles = {};
  bool _ready = false;
  bool _syncing = false;
  bool _needsSync = false;

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
        'https://gis.charttools.noaa.gov/arcgis/rest/services/MarineChart_Services/NOAACharts/MapServer/tile/{z}/{y}/{x}',
      ],
    };
    return jsonEncode({
      'version': 8,
      'sources': {
        for (var i = 0; i < urls.length; i++)
          'base-$i': {
            'type': 'raster',
            'tiles': [urls[i]],
            'tileSize': i == 1 && widget.basemap == 'chart' ? 1024 : 256,
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
    final symbols = SymbolManager(controller, iconAllowOverlap: true);
    final lines = LineManager(controller);
    final circles = CircleManager(controller);
    // These managers are created manually, so initialize their backing style
    // sources/layers before add or set. Constructor alone does not do this.
    await symbols.initialize();
    await lines.initialize();
    await circles.initialize();
    if (!mounted) return;
    _symbolManager = symbols;
    _lineManager = lines;
    _circleManager = circles;
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

  Future<void> _applyMapState() async {
    final symbolManager = _symbolManager,
        lineManager = _lineManager,
        circleManager = _circleManager;
    final controller = _controller;
    if (symbolManager == null ||
        lineManager == null ||
        circleManager == null ||
        controller == null)
      return;

    // Boat marker.
    final boatOptions = SymbolOptions(
      geometry: _toMlLatLng(widget.boatPosition),
      iconImage: _boatIconName,
      iconRotate: widget.headingDeg,
      iconSize: 0.35,
    );
    if (_boatSymbol == null) {
      _boatSymbol = Symbol(_boatSymbolId, boatOptions);
      await symbolManager.add(_boatSymbol!);
    } else {
      _boatSymbol = Symbol(_boatSymbol!.id, boatOptions);
      await symbolManager.set(_boatSymbol!);
    }

    // Active route line.
    if (widget.routeLine.length >= 2) {
      final lineOptions = LineOptions(
        geometry: widget.routeLine.map(_toMlLatLng).toList(),
        lineColor: '#2E6F9E',
        lineWidth: 4.0,
        lineOpacity: 0.85,
      );
      if (_routeLineAnnotation == null) {
        _routeLineAnnotation = Line(_routeLineId, lineOptions);
        await lineManager.add(_routeLineAnnotation!);
      } else {
        _routeLineAnnotation = Line(_routeLineAnnotation!.id, lineOptions);
        await lineManager.set(_routeLineAnnotation!);
      }
    } else if (_routeLineAnnotation != null) {
      await lineManager.remove(_routeLineAnnotation!);
      _routeLineAnnotation = null;
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
        final c = Circle('nav3d-wp-$i', options);
        await circleManager.add(c);
        _waypointCircles[i] = c;
      } else {
        final c = Circle(existing.id, options);
        await circleManager.set(c);
        _waypointCircles[i] = c;
      }
    }
    // Drop circles left over from a shorter waypoint list (e.g. after Undo).
    final stale = _waypointCircles.keys
        .where((i) => i >= widget.waypoints.length)
        .toList();
    for (final i in stale) {
      await circleManager.remove(_waypointCircles[i]!);
      _waypointCircles.remove(i);
    }

    // Camera follow — course-up bearing (mirrors the existing flutter_map
    // _controller.rotate(-heading) behavior) with a real pitch instead of the CSS-tilt hack.
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
      onMapCreated: _onMapCreated,
      onStyleLoadedCallback: _onStyleLoaded,
      onMapClick: (_, point) =>
          widget.onMapTap(ll.LatLng(point.latitude, point.longitude)),
    );
  }
}
