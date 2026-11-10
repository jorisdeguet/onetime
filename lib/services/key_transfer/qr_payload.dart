import 'package:qr/qr.dart';

import 'base45.dart';

/// Builds the QR code for a payload, in alphanumeric mode when the payload
/// allows it (Base45 payloads) and byte mode otherwise.
class QrPayload {
  // Smallest QR version that fits a payload, by (length, alphanumeric, level)
  static final Map<String, int> _versionCache = {};

  static QrCode build(String payload, {int errorCorrectLevel = QrErrorCorrectLevel.L}) {
    final alphanumeric = Base45.isAlphanumeric(payload);
    if (!alphanumeric) return QrCode.fromData(data: payload, errorCorrectLevel: errorCorrectLevel);
    final key = '${payload.length}/$errorCorrectLevel';
    final cached = _versionCache[key];
    if (cached != null) return QrCode(cached, errorCorrectLevel)..addAlphaNumeric(payload);
    for (int version = 1; version <= 40; version++) {
      final qr = QrCode(version, errorCorrectLevel)..addAlphaNumeric(payload);
      try {
        QrImage(qr);
      } on InputTooLongException {
        continue;
      }
      _versionCache[key] = version;
      return qr;
    }
    throw InputTooLongException(payload.length, 0);
  }
}
