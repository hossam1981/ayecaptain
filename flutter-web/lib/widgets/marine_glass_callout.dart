import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A compact, map-anchored marine POI callout.
///
/// No external packages or image assets are required. This is a *visual*
/// widget; [onRoute] is wired to the application's existing routing action.
/// Place it in the same Stack as your map and position it above a projected
/// map-marker coordinate.
class MarineGlassCallout extends StatelessWidget {
  const MarineGlassCallout({
    super.key,
    required this.onRoute,
    this.title = 'Boat ramp',
    this.subtitle = 'Boat ramp / slipway',
    this.width = 286,
    this.tipFraction = 0.5,
  });

  final VoidCallback onRoute;
  final String title;
  final String subtitle;
  final double width;

  /// Horizontal position of the little pointer (0 = left, 1 = right).
  /// Useful when the popup is clamped near the screen's edge.
  final double tipFraction;

  static const double bodyHeight = 185;
  static const double tipHeight = 21;
  static const double totalHeight = bodyHeight + tipHeight;

  @override
  Widget build(BuildContext context) {
    final available = MediaQuery.sizeOf(context).width - 24;
    final cardWidth = width.clamp(218.0, available > 218 ? available : 218.0).toDouble();

    return RepaintBoundary(
      child: SizedBox(
        width: cardWidth,
        height: totalHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // OUTER glow must be painted outside the clipped, blurred glass.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _CalloutRimPainter(
                    tipFraction: tipFraction,
                    glowOnly: true,
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: ClipPath(
                clipper: _CalloutClipper(tipFraction),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Real, translucent smoked-glass material.
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color(0xCB16486B),
                              Color(0xC70A2038),
                              Color(0xCF07192F),
                            ],
                            stops: [0, 0.45, 1],
                          ),
                        ),
                      ),
                      // Cold refracted light trapped toward the lower rim.
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: Alignment(0.73, 1.1),
                            radius: 1.15,
                            colors: [
                              Color(0x3B287FF2),
                              Color(0x0010569C),
                            ],
                          ),
                        ),
                      ),
                      // A broad curved *mirror* reflection, not a flat stripe.
                      IgnorePointer(
                        child: CustomPaint(painter: _MirrorReflectionPainter()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Draw a nonuniform refractive edge and small specular glints.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _CalloutRimPainter(tipFraction: tipFraction),
                ),
              ),
            ),
            Positioned(
              top: 19,
              left: 18,
              right: 18,
              bottom: tipHeight + 16,
              child: Column(
                children: [
                  Row(
                    children: [
                      const _BoatRampIcon(),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFF4FAFF),
                                fontSize: 22,
                                height: 1.1,
                                fontWeight: FontWeight.w700,
                                decoration: TextDecoration.none,
                                shadows: [
                                  Shadow(color: Color(0x6625B7FF), blurRadius: 8),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFB4C8DA),
                                fontSize: 13.5,
                                height: 1.1,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  _RouteHereButton(onPressed: onRoute),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Path _calloutPath(Size size, double tipFraction) {
  const radius = 23.0;
  const inset = 2.0;
  const tipHeight = MarineGlassCallout.tipHeight;
  final w = size.width;
  final bodyBottom = size.height - tipHeight;
  final cx = (w * tipFraction).clamp(radius + 19, w - radius - 19).toDouble();
  const halfTip = 17.0;

  return Path()
    ..moveTo(radius + inset, inset)
    ..lineTo(w - radius - inset, inset)
    ..quadraticBezierTo(w - inset, inset, w - inset, radius + inset)
    ..lineTo(w - inset, bodyBottom - radius)
    ..quadraticBezierTo(w - inset, bodyBottom - inset,
        w - radius - inset, bodyBottom - inset)
    ..lineTo(cx + halfTip, bodyBottom - inset)
    ..lineTo(cx, size.height - inset)
    ..lineTo(cx - halfTip, bodyBottom - inset)
    ..lineTo(radius + inset, bodyBottom - inset)
    ..quadraticBezierTo(inset, bodyBottom - inset, inset, bodyBottom - radius)
    ..lineTo(inset, radius + inset)
    ..quadraticBezierTo(inset, inset, radius + inset, inset)
    ..close();
}

class _CalloutClipper extends CustomClipper<Path> {
  const _CalloutClipper(this.tipFraction);
  final double tipFraction;

  @override
  Path getClip(Size size) => _calloutPath(size, tipFraction);

  @override
  bool shouldReclip(_CalloutClipper oldClipper) =>
      oldClipper.tipFraction != tipFraction;
}

class _CalloutRimPainter extends CustomPainter {
  const _CalloutRimPainter({
    required this.tipFraction,
    this.glowOnly = false,
  });

  final double tipFraction;
  final bool glowOnly;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _calloutPath(size, tipFraction);

    if (glowOnly) {
      canvas.drawShadow(
        path,
        const Color(0xB0001020),
        11,
        true,
      );
    }
    // Two differently sized blurred edge reflections.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..color = const Color(0x552AAEFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 13),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..color = const Color(0x6635BEFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    if (glowOnly) return;

    // The border is intentionally much brighter on the upper-left than right.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.45
        ..shader = ui.Gradient.linear(
          Offset(0, 0),
          Offset(size.width, size.height),
          const [
            Color(0xFFF1FEFF),
            Color(0xFF80E9FF),
            Color(0x882387F9),
            Color(0xFF64CFFF),
          ],
          const [0, 0.20, 0.67, 1],
        ),
    );

    // A second, almost-white rim highlight at the top-left only.
    final topGlint = Path()
      ..moveTo(23, 3.3)
      ..quadraticBezierTo(24, 2.1, 40, 2.1)
      ..lineTo(size.width * 0.65, 2.1);
    canvas.drawPath(
      topGlint,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15
        ..shader = ui.Gradient.linear(
          const Offset(20, 0),
          Offset(size.width * 0.65, 0),
          const [Color(0xFFFFFFFF), Color(0xBB8FEAFF), Color(0x008FEAFF)],
          const [0, 0.5, 1],
        ),
    );

    // Small optical hotspots, not stars or decorative sparkle sprites.
    _glint(canvas, const Offset(30, 2), 2.2, const Color(0xFFCCFAFF));
    _glint(
      canvas,
      Offset(size.width * 0.83, MarineGlassCallout.bodyHeight - 2),
      1.5,
      const Color(0xFF79EFFF),
    );
  }

  void _glint(Canvas canvas, Offset center, double radius, Color color) {
    canvas.drawCircle(
      center,
      radius * 3.2,
      Paint()
        ..color = color.withAlpha(87)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    canvas.drawCircle(center, radius, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _CalloutRimPainter oldDelegate) =>
      oldDelegate.tipFraction != tipFraction || oldDelegate.glowOnly != glowOnly;
}

class _MirrorReflectionPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Wide, soft diagonal reflection in the upper-left glass surface.
    final reflection = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width * 0.39, 0)
      ..quadraticBezierTo(
        size.width * 0.26,
        size.height * 0.11,
        size.width * 0.11,
        size.height * 0.25,
      )
      ..lineTo(0, size.height * 0.36)
      ..close();
    canvas.drawPath(
      reflection,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(size.width * 0.40, size.height * 0.44),
          const [
            Color(0x66FFFFFF),
            Color(0x2BCAEEFF),
            Color(0x00FFFFFF),
          ],
          const [0, 0.5, 1],
        ),
    );

    // Gentle curved highlight underneath the glossy top edge.
    final streak = Path()
      ..moveTo(19, 19)
      ..quadraticBezierTo(size.width * 0.51, 9, size.width - 23, 23);
    canvas.drawPath(
      streak,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = const Color(0x44E7FFFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
  }

  @override
  bool shouldRepaint(covariant _MirrorReflectionPainter oldDelegate) => false;
}

class _BoatRampIcon extends StatelessWidget {
  const _BoatRampIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3386CB), Color(0xFF0B3C7E)],
        ),
        border: Border.all(color: const Color(0xB38AE4FF), width: 1),
        boxShadow: const [
          BoxShadow(color: Color(0x6640BFFF), blurRadius: 14),
          BoxShadow(color: Color(0x66000000), blurRadius: 8, offset: Offset(0, 4)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: Stack(
          children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0x55FFFFFF), Color(0x00FFFFFF)],
                    stops: [0, 0.57],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: CustomPaint(painter: _RampGlyphPainter()),
            ),
          ],
        ),
      ),
    );
  }
}

class _RampGlyphPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 64, size.height / 64);
    final glow = Paint()
      ..color = const Color(0x773BE4FF)
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    final white = Paint()
      ..color = const Color(0xFFF3FBFF)
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // Boat hull pointing to the right on an angled launching slipway.
    final hull = Path()
      ..moveTo(14, 23)
      ..lineTo(45, 27)
      ..lineTo(39, 33)
      ..lineTo(19, 30)
      ..close();
    canvas.drawPath(hull, Paint()..color = const Color(0xFFE9FAFF));
    canvas.drawPath(hull, glow);
    final cabin = Path()
      ..moveTo(24, 22)
      ..lineTo(30, 18)
      ..lineTo(38, 21);
    canvas.drawPath(cabin, white);

    final ramp = Path()
      ..moveTo(12, 35)
      ..lineTo(45, 43)
      ..moveTo(10, 40)
      ..lineTo(42, 49);
    canvas.drawPath(ramp, glow);
    canvas.drawPath(ramp, white);
    canvas.drawCircle(const Offset(35, 43), 3.0, Paint()..color = const Color(0xFFC9F7FF));

    for (var i = 0; i < 2; i++) {
      final y = 48.0 + i * 5.0;
      final wave = Path()
        ..moveTo(10, y)
        ..quadraticBezierTo(14, y - 3, 18, y)
        ..quadraticBezierTo(22, y + 3, 26, y)
        ..quadraticBezierTo(30, y - 3, 34, y)
        ..quadraticBezierTo(38, y + 3, 42, y);
      canvas.drawPath(wave, white);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RampGlyphPainter oldDelegate) => false;
}

class _RouteHereButton extends StatelessWidget {
  const _RouteHereButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    const radius = 15.0;
    return Container(
      height: 55,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [
          BoxShadow(color: Color(0x6615D9AD), blurRadius: 18, spreadRadius: 1),
          BoxShadow(color: Color(0x55000000), blurRadius: 9, offset: Offset(0, 4)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            child: Stack(
              children: [
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xEC32B993), Color(0xD70E806F)],
                      ),
                    ),
                  ),
                ),
                const Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: _ButtonGlossPainter()),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 17),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.navigation_rounded,
                          color: Colors.white, size: 24),
                      const SizedBox(width: 12),
                      Container(width: 1, height: 25, color: const Color(0x6696FFE5)),
                      const SizedBox(width: 13),
                      const Flexible(
                        child: Text(
                          'Route here',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Color(0xFFFFFFFF),
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Icon(Icons.chevron_right_rounded,
                          color: Color(0xFFBCFFF0), size: 26),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ButtonGlossPainter extends CustomPainter {
  const _ButtonGlossPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final topSheen = Path()
      ..moveTo(6, 1)
      ..lineTo(size.width - 6, 1);
    canvas.drawPath(
      topSheen,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.9
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(size.width, 0),
          const [Color(0xE6E8FFF7), Color(0x6687FFE5), Color(0xE6E8FFF7)],
          const [0, 0.5, 1],
        ),
    );
    // A soft mirrored gloss across the upper quarter.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, 19),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          const Offset(0, 19),
          const [Color(0x3FFFFFFF), Color(0x00FFFFFF)],
        ),
    );
    // Mint perimeter, intentionally slim.
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.8, 0.8, size.width - 1.6, size.height - 1.6),
      const Radius.circular(14),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = const Color(0xB98BFFE2),
    );
    // Single specular hotspot at right edge.
    final pos = Offset(size.width - 20, 3);
    canvas.drawCircle(
      pos,
      6,
      Paint()
        ..color = const Color(0xB5D9FFF7)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawCircle(pos, 1.2, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _ButtonGlossPainter oldDelegate) => false;
}
