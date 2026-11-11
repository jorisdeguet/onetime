import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:onetime/services/entropy/sensor_noise.dart';

void main() {
  test('a still sensor with a few steps of noise gives a few bits per reading', () {
    final random = Random(3);
    double gauss() => sqrt(-2 * log(1 - random.nextDouble())) * cos(2 * pi * random.nextDouble());
    // 0.01 resolution, noise of 3 steps, slow drift on top
    final readings = List.generate(20000, (i) => List.generate(3, (a) => ((9.81 * (a == 2 ? 1 : 0) + i * 1e-6 + 0.03 * gauss()) / 0.01).round() * 0.01));
    final r = SensorNoise.analyse('synthetic', readings, const Duration(seconds: 100));
    expect(r.resolution, closeTo(0.01, 1e-9));
    // Step of two Gaussian readings: sigma 3*sqrt(2) steps, min-entropy about 3.3 bits
    expect(r.minEntropyPerAxis, inInclusiveRange(2.8, 3.6));
    expect(r.rateHz, closeTo(200, 1));
    expect(r.conditioned!.passes, isTrue);
  });

  test('a stuck sensor gives nothing', () {
    final readings = List.generate(5000, (_) => [0.0, 9.81, 0.0]);
    final r = SensorNoise.analyse('stuck', readings, const Duration(seconds: 25));
    expect(r.minEntropyPerAxis, 0);
    expect(r.bitsPerSecond, 0);
  });
}
