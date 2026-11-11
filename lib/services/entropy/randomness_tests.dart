import 'dart:math';
import 'dart:typed_data';

/// Statistical tests usually run on random number generators: those of the
/// `ent` tool and the first tests of NIST SP 800-22, plus the most-common-value
/// min-entropy estimate of NIST SP 800-90B for raw (unconditioned) sources.
///
/// Passing them does not prove randomness; failing one shows a defect.
class RandomnessReport {
  final int bytes;

  /// Shannon entropy, bits per byte (8 is the maximum).
  final double entropy;

  /// Min-entropy per byte, most-common-value estimate (SP 800-90B §6.3.1).
  final double minEntropy;

  /// Chi-square of the 256 byte frequencies (255 degrees of freedom) and its p-value.
  final double chiSquare;
  final double chiSquareP;

  /// SP 800-22 frequency (monobit) and runs tests: p-values.
  final double monobitP;
  final double runsP;

  /// Correlation between each byte and the next (0 when independent).
  final double serialCorrelation;

  /// Monte Carlo estimate of pi from pairs of 24-bit coordinates.
  final double monteCarloPi;

  RandomnessReport._(this.bytes, this.entropy, this.minEntropy, this.chiSquare, this.chiSquareP, this.monobitP,
      this.runsP, this.serialCorrelation, this.monteCarloPi);

  /// Thresholds of SP 800-22 (p ≥ 0.01) and of `ent` usage (|correlation| and
  /// pi error small for the sample size).
  bool get passes =>
      chiSquareP >= 0.01 &&
      chiSquareP <= 0.99 &&
      monobitP >= 0.01 &&
      runsP >= 0.01 &&
      serialCorrelation.abs() < 4 / sqrt(bytes) &&
      (monteCarloPi - pi).abs() < 20 / sqrt(bytes);

  factory RandomnessReport.of(Uint8List data) {
    final n = data.length;
    if (n < 1000) throw ArgumentError('At least 1000 bytes are needed');
    final counts = List<int>.filled(256, 0);
    var ones = 0;
    for (final b in data) {
      counts[b]++;
      ones += _popCount[b];
    }

    var entropy = 0.0;
    var chi = 0.0;
    final expected = n / 256;
    for (final c in counts) {
      if (c > 0) entropy -= c / n * log(c / n) / ln2;
      chi += (c - expected) * (c - expected) / expected;
    }

    // Most common value with its 99% upper confidence bound
    final pMax = counts.reduce(max) / n;
    final pUpper = min(1.0, pMax + 2.576 * sqrt(pMax * (1 - pMax) / (n - 1)));
    final minEntropy = -log(pUpper) / ln2;

    // Monobit
    final bits = n * 8;
    final s = (2 * ones - bits).abs();
    final monobitP = _erfc(s / sqrt(2 * bits));

    // Runs (only meaningful when the monobit test is near balanced)
    final prop = ones / bits;
    double runsP;
    if ((prop - 0.5).abs() >= 2 / sqrt(bits)) {
      runsP = 0;
    } else {
      var runs = 1;
      var previous = data[0] >> 7;
      for (int i = 0; i < n; i++) {
        for (int j = 7; j >= 0; j--) {
          if (i == 0 && j == 7) continue;
          final bit = (data[i] >> j) & 1;
          if (bit != previous) runs++;
          previous = bit;
        }
      }
      runsP = _erfc((runs - 2 * bits * prop * (1 - prop)).abs() / (2 * sqrt(2 * bits) * prop * (1 - prop)));
    }

    // Serial correlation, circular as in ent
    var sumXY = 0.0, sumX = 0.0, sumX2 = 0.0;
    for (int i = 0; i < n; i++) {
      final x = data[i].toDouble(), y = data[(i + 1) % n].toDouble();
      sumXY += x * y;
      sumX += x;
      sumX2 += x * x;
    }
    final serial = (n * sumXY - sumX * sumX) / (n * sumX2 - sumX * sumX);

    // Monte Carlo pi: 6 bytes give a point in a square
    var inside = 0, points = 0;
    const radius = 16777215.0;
    for (int i = 0; i + 6 <= n; i += 6) {
      final x = (data[i] << 16 | data[i + 1] << 8 | data[i + 2]).toDouble();
      final y = (data[i + 3] << 16 | data[i + 4] << 8 | data[i + 5]).toDouble();
      if (x * x + y * y <= radius * radius) inside++;
      points++;
    }

    return RandomnessReport._(n, entropy, minEntropy, chi, _chiSquareUpperP(chi, 255), monobitP, runsP, serial,
        4 * inside / points);
  }

  @override
  String toString() => [
        '$bytes bytes',
        'entropy ${entropy.toStringAsFixed(6)} bits/byte (min-entropy ${minEntropy.toStringAsFixed(3)})',
        'chi-square ${chiSquare.toStringAsFixed(1)} (p = ${chiSquareP.toStringAsFixed(3)})',
        'monobit p = ${monobitP.toStringAsFixed(3)}, runs p = ${runsP.toStringAsFixed(3)}',
        'serial correlation ${serialCorrelation.toStringAsFixed(5)}',
        'Monte Carlo pi ${monteCarloPi.toStringAsFixed(5)} (error ${((monteCarloPi - pi) / pi * 100).toStringAsFixed(3)}%)',
        passes ? 'PASS' : 'FAIL',
      ].join('\n');
}

final List<int> _popCount = List.generate(256, (b) {
  var c = 0;
  for (var v = b; v > 0; v >>= 1) {
    c += v & 1;
  }
  return c;
});

/// Complementary error function (Numerical Recipes erfcc, relative error < 1.2e-7).
double _erfc(double x) {
  final z = x.abs();
  final t = 1 / (1 + 0.5 * z);
  final r = t *
      exp(-z * z -
          1.26551223 +
          t *
              (1.00002368 +
                  t *
                      (0.37409196 +
                          t *
                              (0.09678418 +
                                  t *
                                      (-0.18628806 +
                                          t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277)))))))));
  return x >= 0 ? r : 2 - r;
}

/// P(X ≥ chi) for k degrees of freedom (Wilson–Hilferty, accurate for large k).
double _chiSquareUpperP(double chi, int k) {
  final z = (pow(chi / k, 1 / 3) - (1 - 2 / (9 * k))) / sqrt(2 / (9 * k));
  return 0.5 * _erfc(z / sqrt2);
}
