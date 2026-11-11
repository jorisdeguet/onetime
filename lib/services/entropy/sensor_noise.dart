import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'randomness_tests.dart';

/// Measures how much unpredictable signal a motion or orientation sensor
/// gives, to compare it with the camera as a randomness source.
///
/// A phone lying still is the worst case and the honest one: only the
/// sensor's own noise moves the readings. Each axis is quantized by the chip
/// (its resolution is the smallest step seen); the min-entropy is estimated on
/// the step from one reading to the next, which cancels slow drift (heating,
/// a passing car) that an attacker could also observe or cause.
class SensorNoiseReport {
  final String sensor;
  final Duration duration;
  final int samples;
  final double rateHz;

  /// Smallest step between two readings of one axis (chip resolution).
  final double resolution;

  /// Min-entropy per reading and per axis, bits (most common step, SP 800-90B).
  final double minEntropyPerAxis;
  final int axes;

  /// Raw least significant bits of the quantized readings, and those bits
  /// hashed with SHA-256 at the credited rate.
  final RandomnessReport? raw;
  final RandomnessReport? conditioned;

  SensorNoiseReport(this.sensor, this.duration, this.samples, this.rateHz, this.resolution, this.minEntropyPerAxis,
      this.axes, this.raw, this.conditioned);

  /// Extractable randomness, bits per second.
  double get bitsPerSecond => minEntropyPerAxis * axes * rateHz;

  Map<String, Object?> toJson() => {
        'sensor': sensor,
        'seconds': duration.inSeconds,
        'samples': samples,
        'rateHz': rateHz,
        'resolution': resolution,
        'minEntropyPerAxis': minEntropyPerAxis,
        'axes': axes,
        'bitsPerSecond': bitsPerSecond,
        'raw': raw?.toString(),
        'conditioned': conditioned?.toString(),
      };
}

class SensorNoise {
  static Future<SensorNoiseReport> measure(String sensor, {Duration duration = const Duration(seconds: 60)}) async {
    final readings = <List<double>>[];
    final watch = Stopwatch()..start();
    final sub = stream(sensor).listen(readings.add);
    await Future.delayed(duration);
    await sub.cancel();
    watch.stop();
    return analyse(sensor, readings, watch.elapsed);
  }

  /// The sensor's readings, x y z, at the fastest rate the phone allows.
  static Stream<List<double>> stream(String sensor) => switch (sensor) {
        'accelerometer' => accelerometerEventStream(samplingPeriod: SensorInterval.fastestInterval).map((e) => [e.x, e.y, e.z]),
        'gyroscope' => gyroscopeEventStream(samplingPeriod: SensorInterval.fastestInterval).map((e) => [e.x, e.y, e.z]),
        'magnetometer' => magnetometerEventStream(samplingPeriod: SensorInterval.fastestInterval).map((e) => [e.x, e.y, e.z]),
        _ => throw ArgumentError(sensor),
      };

  static SensorNoiseReport analyse(String sensor, List<List<double>> readings, Duration elapsed) {
    final axes = readings.isEmpty ? 3 : readings.first.length;
    final rate = readings.length / (elapsed.inMicroseconds / 1e6);
    if (readings.length < 10) {
      return SensorNoiseReport(sensor, elapsed, readings.length, rate, 0, 0, axes, null, null);
    }
    final resolution = resolutionOf(readings);
    final minEntropy = minEntropyOf(readings, resolution);
    final lsb = <int>[];
    for (final r in readings) {
      for (int a = 0; a < axes; a++) {
        lsb.add((r[a] / resolution).round() & 1);
      }
    }
    final raw = _pack(lsb);
    RandomnessReport? rawReport, conditioned;
    if (raw.length >= 1000) rawReport = RandomnessReport.of(raw);
    // Hash chunks holding 320 bits of min-entropy into 32 bytes, as for the camera
    if (minEntropy > 0) {
      final readingsPerChunk = (320 / (minEntropy * axes)).ceil();
      final out = BytesBuilder(copy: false);
      for (int i = 0; i + readingsPerChunk <= readings.length; i += readingsPerChunk) {
        final chunk = ByteData(readingsPerChunk * axes * 4);
        for (int j = 0; j < readingsPerChunk; j++) {
          for (int a = 0; a < axes; a++) {
            chunk.setInt32((j * axes + a) * 4, (readings[i + j][a] / resolution).round());
          }
        }
        out.add(sha256.convert(chunk.buffer.asUint8List()).bytes);
      }
      final bytes = out.takeBytes();
      if (bytes.length >= 1000) conditioned = RandomnessReport.of(bytes);
    }
    return SensorNoiseReport(sensor, elapsed, readings.length, rate, resolution, minEntropy, axes, rawReport, conditioned);
  }

  /// Chip resolution: the smallest nonzero step on any axis (1 if none).
  static double resolutionOf(List<List<double>> readings) {
    var resolution = double.infinity;
    for (int i = 1; i < readings.length; i++) {
      for (int a = 0; a < readings[i].length; a++) {
        final d = (readings[i][a] - readings[i - 1][a]).abs();
        if (d > 1e-9 && d < resolution) resolution = d;
      }
    }
    return resolution.isFinite ? resolution : 1;
  }

  /// Min-entropy of the step between successive quantized readings, bits per
  /// reading on the worst axis (most common value with its 99% upper bound).
  static double minEntropyOf(List<List<double>> readings, double resolution) {
    if (readings.length < 3) return 0;
    var minEntropy = double.infinity;
    for (int a = 0; a < readings.first.length; a++) {
      final counts = <int, int>{};
      for (int i = 1; i < readings.length; i++) {
        final step = ((readings[i][a] - readings[i - 1][a]) / resolution).round();
        counts[step] = (counts[step] ?? 0) + 1;
      }
      final n = readings.length - 1;
      final pMax = counts.values.reduce(math.max) / n;
      final pUpper = math.min(1.0, pMax + 2.576 * math.sqrt(pMax * (1 - pMax) / (n - 1)));
      minEntropy = math.min(minEntropy, -math.log(pUpper) / math.ln2);
    }
    return minEntropy.isFinite ? minEntropy : 0;
  }

  static Uint8List _pack(List<int> bits) {
    final out = Uint8List(bits.length ~/ 8);
    for (int i = 0; i < out.length; i++) {
      var b = 0;
      for (int j = 0; j < 8; j++) {
        b = (b << 1) | bits[i * 8 + j];
      }
      out[i] = b;
    }
    return out;
  }
}
