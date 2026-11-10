import '../key_service.dart';

/// Turns a key segment into the payload carried by the data channel (a QR
/// code today) and back.
abstract class SegmentCodec {
  String encode(KeySegmentQrData segment);
  KeySegmentQrData decode(String payload);
}

/// Current format: JSON with the key bytes in base64.
class JsonSegmentCodec implements SegmentCodec {
  const JsonSegmentCodec();
  @override
  String encode(KeySegmentQrData segment) => segment.toQrString();
  @override
  KeySegmentQrData decode(String payload) => KeySegmentQrData.fromQrString(payload);
}
