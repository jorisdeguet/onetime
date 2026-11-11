import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../app_logger.dart';
import 'sensor_noise.dart';

/// Physical randomness from the motion and orientation sensors (accelerometer,
/// gyroscope, magnetometer), mixed into the key next to the camera's.
///
/// They need no permission and show no indicator, but give about a hundred
/// times less than the camera (a few hundred bytes per second): they cover
/// the start of each segment, not the whole key.
///
/// Readings are taken in windows of [windowSize]. Each window is checked on
/// its own: the min-entropy of the step between readings, worst axis, must
/// reach [minBitsPerReading], or the window is dropped (phone on a vibrating
/// motor, magnet against the compass, sensor stuck). Successive readings are
/// correlated, which the estimate does not see, so only half of it is
/// credited. Readings are then hashed with SHA-256 in groups holding 320
/// credited bits, 32 bytes out per group, as for the camera.
class MotionNoise {
  static const sensors = ['accelerometer', 'gyroscope', 'magnetometer'];
  static const windowSize = 256;
  static const minBitsPerReading = 0.5;
  static const _creditFactor = 0.5;
  static const _bitsPerOutput = 320;

  final _log = AppLogger();
  final Queue<int> _pool = Queue<int>();
  final List<StreamSubscription<List<double>>> _subs = [];
  final Map<String, List<List<double>>> _windows = {};

  /// Smallest step seen so far per sensor (its resolution).
  final Map<String, double> _resolution = {};

  int acceptedWindows = 0;
  int rejectedWindows = 0;

  /// Key bytes that received sensor noise.
  int mixedBytes = 0;

  /// Bytes produced per sensor.
  final Map<String, int> produced = {};

  bool get isRunning => _subs.isNotEmpty;

  int get available => _pool.length;

  void start() {
    for (final sensor in sensors) {
      try {
        _windows[sensor] = [];
        _subs.add(SensorNoise.stream(sensor).listen((r) => _onReading(sensor, r), onError: (Object e) {
          _log.w('MotionNoise', '$sensor unavailable: $e');
        }, cancelOnError: true));
      } catch (e) {
        _log.w('MotionNoise', '$sensor unavailable: $e');
      }
    }
  }

  void _onReading(String sensor, List<double> reading) {
    final window = _windows[sensor]!..add(reading);
    if (window.length < windowSize) return;
    _windows[sensor] = [];
    if (_pool.length > 1 << 20) return;
    final windowResolution = SensorNoise.resolutionOf(window);
    final resolution = math.min(_resolution[sensor] ?? double.infinity, windowResolution);
    _resolution[sensor] = resolution;
    final out = condition(window, resolution);
    if (out == null) {
      rejectedWindows++;
      return;
    }
    acceptedWindows++;
    produced[sensor] = (produced[sensor] ?? 0) + out.length;
    _pool.addAll(out);
  }

  /// Health test and conditioning of one window; null when it fails the test.
  static Uint8List? condition(List<List<double>> window, double resolution) {
    final minEntropy = SensorNoise.minEntropyOf(window, resolution);
    if (minEntropy < minBitsPerReading) return null;
    final axes = window.first.length;
    final credited = minEntropy * _creditFactor * axes;
    final perOutput = (_bitsPerOutput / credited).ceil();
    final out = BytesBuilder(copy: false);
    for (int i = 0; i + perOutput <= window.length; i += perOutput) {
      final chunk = ByteData(perOutput * axes * 4);
      for (int j = 0; j < perOutput; j++) {
        for (int a = 0; a < axes; a++) {
          chunk.setInt32((j * axes + a) * 4, (window[i + j][a] / resolution).round());
        }
      }
      out.add(sha256.convert(chunk.buffer.asUint8List()).bytes);
    }
    return out.takeBytes();
  }

  /// Up to [n] conditioned bytes (fewer when the pool runs low).
  Uint8List take(int n) {
    final k = math.min(n, _pool.length);
    final out = Uint8List(k);
    for (int i = 0; i < k; i++) {
      out[i] = _pool.removeFirst();
    }
    return out;
  }

  Future<void> stop() async {
    final subs = List.of(_subs);
    _subs.clear();
    for (final s in subs) {
      await s.cancel();
    }
  }
}
