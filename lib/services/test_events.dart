import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Debug-only milestone events for the testbench (tool/testbench/ot.sh).
///
/// Each event is one logcat line: `OT_TEST {"event": ..., ...}`.
/// Nothing is emitted in release builds.
class TestEvents {
  static void emit(String event, [Map<String, Object?> data = const {}]) {
    if (!kDebugMode) return;
    debugPrint('OT_TEST ${jsonEncode({'event': event, 't': DateTime.now().toIso8601String(), ...data})}');
  }

  /// Short fingerprint so the testbench can check every device holds the same key bytes.
  static String keyFingerprint(Uint8List keyData) => sha256.convert(keyData).toString().substring(0, 16);
}
