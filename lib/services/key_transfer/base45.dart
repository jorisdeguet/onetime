import 'dart:typed_data';

/// Base45 (RFC 9285): bytes as text made only of the QR alphanumeric
/// charset, so a QR code can carry them in alphanumeric mode (5.5 bits per
/// character instead of 8 in byte mode).
class Base45 {
  static const charset = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ \$%*+-./:';
  static final Map<int, int> _values = {
    for (int i = 0; i < charset.length; i++) charset.codeUnitAt(i): i,
  };

  static String encode(Uint8List bytes) {
    final out = StringBuffer();
    int i = 0;
    for (; i + 1 < bytes.length; i += 2) {
      int n = bytes[i] * 256 + bytes[i + 1];
      out
        ..writeCharCode(charset.codeUnitAt(n % 45))
        ..writeCharCode(charset.codeUnitAt((n ~/ 45) % 45))
        ..writeCharCode(charset.codeUnitAt(n ~/ 2025));
    }
    if (i < bytes.length) {
      out
        ..writeCharCode(charset.codeUnitAt(bytes[i] % 45))
        ..writeCharCode(charset.codeUnitAt(bytes[i] ~/ 45));
    }
    return out.toString();
  }

  static Uint8List decode(String text) {
    if (text.length % 3 == 1) throw const FormatException('Invalid Base45 length');
    final out = BytesBuilder(copy: false);
    int digit(int i) {
      final v = _values[text.codeUnitAt(i)];
      if (v == null) throw FormatException('Invalid Base45 character', text, i);
      return v;
    }

    int i = 0;
    for (; i + 2 < text.length; i += 3) {
      final n = digit(i) + digit(i + 1) * 45 + digit(i + 2) * 2025;
      if (n > 0xFFFF) throw FormatException('Invalid Base45 group', text, i);
      out.add([n >> 8, n & 0xFF]);
    }
    if (i < text.length) {
      final n = digit(i) + digit(i + 1) * 45;
      if (n > 0xFF) throw FormatException('Invalid Base45 group', text, i);
      out.addByte(n);
    }
    return out.toBytes();
  }

  /// True when [text] can be put in a QR code in alphanumeric mode.
  static bool isAlphanumeric(String text) {
    for (int i = 0; i < text.length; i++) {
      if (!_values.containsKey(text.codeUnitAt(i))) return false;
    }
    return true;
  }
}
