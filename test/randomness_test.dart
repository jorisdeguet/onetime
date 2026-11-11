import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:onetime/services/entropy/randomness_tests.dart';

Uint8List _bytes(int n, int Function() next) => Uint8List.fromList(List.generate(n, (_) => next()));

void main() {
  test('the system generator passes the usual tests', () {
    final random = Random.secure();
    final report = RandomnessReport.of(_bytes(4 << 20, () => random.nextInt(256)));
    // ignore: avoid_print
    print(report);
    expect(report.passes, isTrue, reason: '$report');
    expect(report.entropy, greaterThan(7.999));
  });

  test('the tests catch biased, repeating and correlated data', () {
    final random = Random(1);
    // One bit in 100 forced to 1
    final biased = RandomnessReport.of(_bytes(1 << 20, () => random.nextInt(256) | (random.nextInt(100) == 0 ? 1 : 0)));
    expect(biased.passes, isFalse, reason: 'biased\n$biased');
    // A short pattern repeated
    var i = 0;
    final repeated = RandomnessReport.of(_bytes(1 << 20, () => (i++ * 37) & 0xFF));
    expect(repeated.passes, isFalse, reason: 'repeated\n$repeated');
    // Each byte close to the previous one, like neighbouring pixels
    var v = 128;
    final correlated = RandomnessReport.of(_bytes(1 << 20, () => v = (v + random.nextInt(9) - 4) & 0xFF));
    expect(correlated.passes, isFalse, reason: 'correlated\n$correlated');
  });
}
