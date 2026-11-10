import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:onetime/services/key_transfer/base45.dart';
import 'package:onetime/services/key_transfer/qr_payload.dart';
import 'package:onetime/services/key_transfer/fountain.dart';
import 'package:qr/qr.dart';

void main() {
  final random = Random(42);
  Uint8List randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => random.nextInt(256)));

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

  test('a 1 KB fountain packet fits a QR code of 109 modules', () {
    final packet = FountainPacket(
      sessionId: 'Ab3dEfGh1jKlMn0pQrSt',
      totalBytes: 512 * 1024,
      symbolSize: 1024,
      blockSymbols: 32,
      block: 3,
      index: 40,
      data: randomBytes(1024),
    );
    final payload = const FountainCodec().encode(packet);
    final decoded = const FountainCodec().decode(payload);
    expect(decoded.data, packet.data);
    expect([decoded.block, decoded.index, decoded.totalBytes], [3, 40, 512 * 1024]);
    final qr = QrPayload.build(payload);
    expect(qr.moduleCount, 109);
    expect(QrImage(qr).moduleCount, 109);
  });
}
