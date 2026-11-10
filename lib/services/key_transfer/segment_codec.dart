import 'dart:convert';
import 'dart:typed_data';

import '../key_service.dart';
import 'base45.dart';

/// Turns a key segment into the payload carried by the data channel (a QR
/// code today) and back.
abstract class SegmentCodec {
  String encode(KeySegmentQrData segment);
  KeySegmentQrData decode(String payload);
}

/// First format: JSON with the key bytes in base64.
class JsonSegmentCodec implements SegmentCodec {
  const JsonSegmentCodec();
  @override
  String encode(KeySegmentQrData segment) => segment.toQrString();
  @override
  KeySegmentQrData decode(String payload) => KeySegmentQrData.fromQrString(payload);
}

/// Compact format: a binary header followed by the raw key bytes, in Base45
/// so the QR code can use alphanumeric mode. About 30% fewer QR modules than
/// [JsonSegmentCodec] for the same segment.
///
/// Layout: version (1 byte), session id length (1), session id (ASCII),
/// segment index (2, big endian), start byte (4, big endian), key bytes.
///
/// [decode] also accepts the JSON format, so a reader can still scan a
/// source running an older version.
class Base45SegmentCodec implements SegmentCodec {
  static const _version = 1;

  const Base45SegmentCodec();

  @override
  String encode(KeySegmentQrData segment) {
    final id = ascii.encode(segment.sessionId);
    if (id.length > 255) throw ArgumentError('Session id too long');
    final header = ByteData(8 + id.length)
      ..setUint8(0, _version)
      ..setUint8(1, id.length);
    for (int i = 0; i < id.length; i++) {
      header.setUint8(2 + i, id[i]);
    }
    header
      ..setUint16(2 + id.length, segment.segmentIndex)
      ..setUint32(4 + id.length, segment.startByte);
    final bytes = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(segment.keyData);
    return Base45.encode(bytes.toBytes());
  }

  @override
  KeySegmentQrData decode(String payload) {
    if (payload.startsWith('{')) return const JsonSegmentCodec().decode(payload);
    final bytes = Base45.decode(payload);
    final data = ByteData.sublistView(bytes);
    if (bytes.length < 8 || data.getUint8(0) != _version) {
      throw const FormatException('Unknown segment format');
    }
    final idLength = data.getUint8(1);
    if (bytes.length < 8 + idLength) throw const FormatException('Truncated segment');
    final startByte = data.getUint32(4 + idLength);
    final keyData = Uint8List.fromList(bytes.sublist(8 + idLength));
    return KeySegmentQrData(
      sessionId: ascii.decode(bytes.sublist(2, 2 + idLength)),
      segmentIndex: data.getUint16(2 + idLength),
      startByte: startByte,
      endByte: startByte + keyData.length,
      keyData: keyData,
    );
  }
}
