import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:onetime/services/entropy/motion_noise.dart';
import 'package:onetime/services/entropy/randomness_tests.dart';

void main() {
  final random = Random(5);
  double gauss() => sqrt(-2 * log(1 - random.nextDouble())) * cos(2 * pi * random.nextDouble());
  List<List<double>> window(double noiseSteps) => List.generate(
      MotionNoise.windowSize, (_) => List.generate(3, (a) => ((a == 2 ? 9.81 : 0) / 0.01 + noiseSteps * gauss()).round() * 0.01));

  test('a noisy window is conditioned into random bytes', () {
    final out = BytesBuilder();
    for (int i = 0; i < 400; i++) {
      out.add(MotionNoise.condition(window(3), 0.01)!);
    }
    final bytes = out.takeBytes();
    // About 3.3 bits per axis, lowered by the 99% bound on a 256-reading
    // window, half credited: 2 or 3 outputs of 32 bytes per window
    expect(bytes.length / 400, inInclusiveRange(64, 96));
    final report = RandomnessReport.of(bytes);
    expect(report.passes, isTrue, reason: '$report');
  });

  test('a stuck or nearly stuck sensor is rejected', () {
    expect(MotionNoise.condition(List.generate(MotionNoise.windowSize, (_) => [0.0, 9.81, 0.0]), 0.01), isNull);
    // One axis moves, the others are pinned (a magnet against the compass)
    expect(
        MotionNoise.condition(
            List.generate(MotionNoise.windowSize, (_) => [(3 * gauss()).round() * 0.01, 0.5, 0.0]), 0.01),
        isNull);
  });
}
