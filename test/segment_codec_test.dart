import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:onetime/services/key_service.dart';
import 'package:onetime/services/key_transfer/base45.dart';
import 'package:onetime/services/key_transfer/qr_payload.dart';
import 'package:onetime/services/key_transfer/segment_codec.dart';
import 'package:qr/qr.dart';

void main() {
  final random = Random(42);
  Uint8List randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => random.nextInt(256)));

  KeySegmentQrData segment(int index, int length) => KeySegmentQrData(
        sessionId: 'Ab3dEfGh1jKlMn0pQrSt',
        segmentIndex: index,
        startByte: index * KeyService.segmentSizeBytes,
        endByte: index * KeyService.segmentSizeBytes + length,
        keyData: randomBytes(length),
      );

  group('Base45', () {
    test('matches the RFC 9285 examples', () {
      expect(Base45.encode(Uint8List.fromList('AB'.codeUnits)), 'BB8');
      expect(Base45.encode(Uint8List.fromList('Hello!!'.codeUnits)), '%69 VD92EX0');
      expect(Base45.encode(Uint8List.fromList('base-45'.codeUnits)), 'UJCLQE7W581');
      expect(String.fromCharCodes(Base45.decode('QED8WEX0')), 'ietf!');
    });

    test('round-trips every length, including odd ones', () {
      for (int n = 0; n < 40; n++) {
        final bytes = randomBytes(n);
        expect(Base45.decode(Base45.encode(bytes)), bytes);
      }
    });

    test('rejects malformed text', () {
      expect(() => Base45.decode('GGW'), throwsFormatException); // 65535 + 1
      expect(() => Base45.decode('ab'), throwsFormatException);
      expect(() => Base45.decode('ABCD'), throwsFormatException);
    });
  });

  group('Base45SegmentCodec', () {
    const codec = Base45SegmentCodec();

    test('round-trips a full and a short segment', () {
      for (final s in [segment(0, 1024), segment(37, 300)]) {
        final decoded = codec.decode(codec.encode(s));
        expect(decoded.sessionId, s.sessionId);
        expect(decoded.segmentIndex, s.segmentIndex);
        expect(decoded.startByte, s.startByte);
        expect(decoded.endByte, s.endByte);
        expect(decoded.keyData, s.keyData);
      }
    });

    test('still reads the JSON format', () {
      final s = segment(3, 1024);
      expect(codec.decode(const JsonSegmentCodec().encode(s)).keyData, s.keyData);
    });

    test('needs a smaller QR code than JSON', () {
      final s = segment(0, 1024);
      final base45 = QrPayload.build(codec.encode(s));
      final json = QrPayload.build(const JsonSegmentCodec().encode(s));
      // ignore: avoid_print
      print('1 KB segment: QR version ${base45.typeNumber} (${base45.moduleCount} modules) '
          'vs ${json.typeNumber} (${json.moduleCount}) with JSON');
      expect(base45.moduleCount, lessThan(json.moduleCount));
      expect(QrImage(base45).moduleCount, base45.moduleCount);
    });
  });
}
