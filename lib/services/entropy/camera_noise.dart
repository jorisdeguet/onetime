import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';

import '../app_logger.dart';
import 'randomness_tests.dart';

/// Physical randomness from the camera sensor, mixed into the key.
///
/// The least significant bit of each pixel's brightness is mostly sensor noise
/// (photon shot noise, read noise), which no program can predict. Raw, it is
/// biased and correlated between neighbours, so it is conditioned as NIST SP
/// 800-90B prescribes: chunks of [rawChunkBytes] raw bytes (1024 pixel bits)
/// are hashed with SHA-256 into 32 bytes. Full entropy is credited only if a
/// chunk holds 256 + 64 bits of min-entropy, i.e. 0.31 bit per pixel; the raw
/// stream is checked against that bound continuously ([minEntropyPerBit]).
///
/// The key generator XORs these bytes with the system generator's, so a key
/// byte is unpredictable as long as either source is: a flaw in one does not
/// weaken the key below the other.
class CameraNoise {
  static const rawChunkBytes = 128;
  static const _outputPerChunk = 32;

  /// Required raw min-entropy per pixel bit for the conditioning to give full
  /// entropy: (256 + 64) / 1024.
  static const minEntropyPerBit = 0.3125;

  final _log = AppLogger();
  final Queue<int> _pool = Queue<int>();
  CameraController? _controller;
  final _ready = Completer<void>();
  bool _busy = false;

  /// Raw bytes kept for the health check and the reports (bounded).
  final BytesBuilder _rawSample = BytesBuilder(copy: false);
  static const _rawSampleLimit = 1 << 20;

  /// Frames dropped by the health check (too little noise: dark, saturated or
  /// heavily denoised image).
  int rejectedFrames = 0;
  int acceptedFrames = 0;

  /// Key bytes that received camera noise, and those that did not.
  int mixedBytes = 0;
  int unmixedBytes = 0;

  bool get isRunning => _controller != null;

  int get available => _pool.length;

  /// Completes once the first frames are conditioned (or the camera failed).
  Future<void> get ready => _ready.future;

  Future<void> start() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cameras.first);
      final controller = CameraController(back, ResolutionPreset.low,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await controller.initialize();
      _controller = controller;
      await controller.startImageStream(_onFrame);
      _log.i('CameraNoise', 'Collecting sensor noise from ${back.name}');
    } catch (e) {
      _log.w('CameraNoise', 'Camera unavailable, the key uses the system generator only: $e');
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  void _onFrame(CameraImage image) {
    if (_busy || _pool.length > 4 << 20) return;
    _busy = true;
    try {
      final raw = lsbPlane(image.planes.first.bytes);
      if (!healthy(raw)) {
        rejectedFrames++;
        return;
      }
      acceptedFrames++;
      if (_rawSample.length < _rawSampleLimit) _rawSample.add(raw);
      _pool.addAll(condition(raw));
      if (!_ready.isCompleted && _pool.length >= 4096) _ready.complete();
    } finally {
      _busy = false;
    }
  }

  /// Packs the least significant bit of each brightness sample, 8 per byte.
  static Uint8List lsbPlane(Uint8List luma) {
    final out = Uint8List(luma.length ~/ 8);
    for (int i = 0; i < out.length; i++) {
      var b = 0;
      final o = i * 8;
      for (int j = 0; j < 8; j++) {
        b = (b << 1) | (luma[o + j] & 1);
      }
      out[i] = b;
    }
    return out;
  }

  /// Online health test of a frame (SP 800-90B §4.4 in spirit): the
  /// proportion of ones and the most common byte must leave at least
  /// [minEntropyPerBit] of min-entropy per bit.
  static bool healthy(Uint8List raw) {
    if (raw.length < 1024) return false;
    final counts = List<int>.filled(256, 0);
    for (final b in raw) {
      counts[b]++;
    }
    var most = 0;
    for (final c in counts) {
      if (c > most) most = c;
    }
    // Min-entropy per byte from the most common value, per bit
    final p = most / raw.length;
    final perBit = -math.log(p) / math.ln2 / 8;
    return perBit >= minEntropyPerBit;
  }

  /// SHA-256 of each [rawChunkBytes] chunk.
  static Uint8List condition(Uint8List raw) {
    final out = BytesBuilder(copy: false);
    for (int o = 0; o + rawChunkBytes <= raw.length; o += rawChunkBytes) {
      out.add(sha256.convert(Uint8List.sublistView(raw, o, o + rawChunkBytes)).bytes.sublist(0, _outputPerChunk));
    }
    return out.takeBytes();
  }

  /// Up to [n] conditioned bytes (fewer when the pool runs low).
  Uint8List take(int n) {
    final k = n < _pool.length ? n : _pool.length;
    final out = Uint8List(k);
    for (int i = 0; i < k; i++) {
      out[i] = _pool.removeFirst();
    }
    return out;
  }

  /// Statistical reports of the raw noise and of the conditioned output.
  ({RandomnessReport? raw, RandomnessReport? conditioned}) reports() {
    final raw = _rawSample.toBytes();
    if (raw.length < 4096) return (raw: null, conditioned: null);
    return (raw: RandomnessReport.of(raw), conditioned: RandomnessReport.of(condition(raw)));
  }

  Future<void> stop() async {
    final c = _controller;
    _controller = null;
    if (!_ready.isCompleted) _ready.complete();
    if (c == null) return;
    try {
      await c.stopImageStream();
    } catch (_) {}
    await c.dispose();
  }
}
