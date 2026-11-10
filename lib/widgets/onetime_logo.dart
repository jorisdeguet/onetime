import 'package:flutter/material.dart';

/// The 1T monogram: a T whose bar also covers a 1 standing on its left.
///
/// Drawn on a 100 x 100 grid, so the same painter produces the in-app logo
/// and the launcher icons (tool/icons/generate_icons_test.dart).
class OneTimeLogo extends StatelessWidget {
  final double size;

  /// Defaults to the theme's foreground (black in light mode, white in dark).
  final Color? color;

  const OneTimeLogo({super.key, this.size = 48, this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: OneTimeLogoPainter(color ?? Theme.of(context).colorScheme.onSurface),
    );
  }
}

class OneTimeLogoPainter extends CustomPainter {
  final Color color;

  const OneTimeLogoPainter(this.color);

  /// Paints the monogram in a [size] square at the canvas origin.
  static void paintLogo(Canvas canvas, double size, Color color) {
    final u = size / 100;
    final paint = Paint()..color = color;
    // Bar of the T, over both letters
    canvas.drawRect(Rect.fromLTRB(16 * u, 18 * u, 84 * u, 31 * u), paint);
    // Stem of the T
    canvas.drawRect(Rect.fromLTRB(54 * u, 18 * u, 67 * u, 82 * u), paint);
    // Stem of the 1, starting a little below the bar
    canvas.drawRect(Rect.fromLTRB(33 * u, 38 * u, 46 * u, 82 * u), paint);
    // Flag of the 1, slanting down to the left
    canvas.drawPath(
      Path()
        ..moveTo(33 * u, 38 * u)
        ..lineTo(46 * u, 38 * u)
        ..lineTo(46 * u, 45 * u)
        ..lineTo(23 * u, 60 * u)
        ..lineTo(17 * u, 51 * u)
        ..close(),
      paint,
    );
  }

  @override
  void paint(Canvas canvas, Size size) => paintLogo(canvas, size.shortestSide, color);

  @override
  bool shouldRepaint(OneTimeLogoPainter old) => old.color != color;
}
