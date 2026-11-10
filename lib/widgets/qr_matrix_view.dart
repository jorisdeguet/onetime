import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// Shows a QR code as one bitmap (one pixel per module, scaled up without
/// smoothing) instead of one shape per module, with a fixed mask pattern, so
/// it can change several times per second even on slow phones. Keeps showing
/// the previous code until the new one is ready.
class QrMatrixView extends StatefulWidget {
  final QrCode qr;

  const QrMatrixView({super.key, required this.qr});

  @override
  State<QrMatrixView> createState() => _QrMatrixViewState();
}

class _QrMatrixViewState extends State<QrMatrixView> {
  static const _quietZone = 4;
  ui.Image? _image;
  int _requested = 0;
  int _shown = 0;

  @override
  void initState() {
    super.initState();
    _render(widget.qr);
  }

  @override
  void didUpdateWidget(QrMatrixView old) {
    super.didUpdateWidget(old);
    if (!identical(old.qr, widget.qr)) _render(widget.qr);
  }

  Future<void> _render(QrCode qr) async {
    final request = ++_requested;
    final size = qr.moduleCount + 2 * _quietZone;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(_pixels(qr), size, size, ui.PixelFormat.rgba8888, completer.complete);
    final image = await completer.future;
    // Shown unless a newer code got there first: dropping every image that is
    // no longer the latest would show nothing when codes change faster than this
    if (!mounted || request < _shown) {
      image.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = image;
      _shown = request;
    });
  }

  /// RGBA pixels of the code with its quiet zone. Choosing the best mask
  /// pattern costs 8 full encodings (~200 ms on a slow phone); key bytes are
  /// random, so any mask reads as well.
  static Uint8List _pixels(QrCode qr) {
    final matrix = QrImage.withMaskPattern(qr, 0);
    final size = matrix.moduleCount + 2 * _quietZone;
    final pixels = Uint8List(size * size * 4)..fillRange(0, size * size * 4, 0xFF);
    for (int y = 0; y < matrix.moduleCount; y++) {
      for (int x = 0; x < matrix.moduleCount; x++) {
        if (!matrix.isDark(y, x)) continue;
        final o = ((y + _quietZone) * size + x + _quietZone) * 4;
        pixels[o] = pixels[o + 1] = pixels[o + 2] = 0;
      }
    }
    return pixels;
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: _image == null
          ? const ColoredBox(color: Colors.white)
          : RawImage(image: _image, fit: BoxFit.contain, filterQuality: FilterQuality.none),
    );
  }
}
