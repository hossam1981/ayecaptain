// Bayside — Flutter Web preview
//
// This is a starter, not a rewrite. Goal: verify the "push a branch → Netlify serves a live URL"
// workflow works for Flutter Web, and give a visual baseline (map centered on Raritan Bay, a live
// GPS marker if the browser gives us one) before deciding whether to invest in feature parity with
// the PWA on `main`. Uses flutter_map (Leaflet-like) to keep the initial payload small; can be
// swapped for maplibre_gl later if we want real 3D pitch/tilt.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';

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
        ),
        home: const MapScreen(),
      );
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _controller = MapController();
  LatLng? _me;
  String _status = 'Tap the target to lock on my location';

  Future<void> _locate() async {
    setState(() => _status = 'Requesting location…');
    try {
      final perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        setState(() => _status = 'Location denied');
        return;
      }
      final p = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final me = LatLng(p.latitude, p.longitude);
      setState(() {
        _me = me;
        _status = 'Locked on ${me.latitude.toStringAsFixed(5)}, ${me.longitude.toStringAsFixed(5)}';
      });
      _controller.move(me, 14);
    } catch (e) {
      setState(() => _status = 'GPS error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(children: [
          FlutterMap(
            mapController: _controller,
            options: const MapOptions(
              initialCenter: LatLng(40.457, -74.15), // Raritan Bay
              initialZoom: 11,
              minZoom: 3,
              maxZoom: 19,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}',
                userAgentPackageName: 'net.bayside.flutter',
              ),
              if (_me != null)
                MarkerLayer(markers: [
                  Marker(
                    point: _me!,
                    width: 40,
                    height: 40,
                    child: const _BoatDot(),
                  ),
                ]),
            ],
          ),
          Positioned(top: 12, left: 12, right: 68, child: _Badge(status: _status)),
          Positioned(top: 12, right: 12, child: _LocateButton(onTap: _locate)),
        ]),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String status;
  const _Badge({required this.status});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xE60F2A44),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          const Text('Bayside — Flutter Web preview',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(height: 2),
          Text(status, style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12)),
        ]),
      );
}

class _LocateButton extends StatelessWidget {
  final VoidCallback onTap;
  const _LocateButton({required this.onTap});
  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFF2E6F9E),
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: const SizedBox(
            width: 46,
            height: 46,
            child: Icon(Icons.my_location, color: Colors.white),
          ),
        ),
      );
}

class _BoatDot extends StatelessWidget {
  const _BoatDot();
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFFF2A93B),
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
        ),
      );
}
