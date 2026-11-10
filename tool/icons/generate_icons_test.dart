// Renders the 1T logo into the Android launcher icons and a preview.
// Run: flutter test tool/icons/generate_icons_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onetime/widgets/onetime_logo.dart';

Future<void> _writeIcon(String path, int px, {required Color background, required Color foreground, double inset = 0.12}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final s = px.toDouble();
  // Rounded square, the logo slightly inset
  canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, s, s), Radius.circular(s * 0.22)), Paint()..color = background);
  canvas.translate(s * inset, s * inset);
  OneTimeLogoPainter.paintLogo(canvas, s * (1 - 2 * inset), foreground);
  final image = await recorder.endRecording().toImage(px, px);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  test('generate launcher icons', () async {
    const sizes = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192};
    for (final e in sizes.entries) {
      await _writeIcon('android/app/src/main/res/mipmap-${e.key}/ic_launcher.png', e.value,
          background: Colors.black, foreground: Colors.white);
    }
    await _writeIcon('build/icons/preview_dark.png', 512, background: Colors.black, foreground: Colors.white);
    await _writeIcon('build/icons/preview_light.png', 512, background: Colors.white, foreground: Colors.black);
  });
}
