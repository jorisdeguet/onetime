import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:onetime/services/key_service.dart';

void main() {
  const seg = KeyService.segmentSizeBytes;

  Uint8List segment(int fill) => Uint8List(seg)..fillRange(0, seg, fill);

  KexSessionReader reader() => KexSessionReader(
        conversationId: 'conv',
        sessionId: 'kex',
        role: KeyExchangeRole.reader,
        peerIds: ['alice', 'bob'],
        localPeerId: 'bob',
      );

  group('KexSessionReader.buildSharedKey', () {
    test('assembles contiguous segments in order', () {
      final r = reader()
        ..addSegmentData(seg, segment(2))
        ..addSegmentData(0, segment(1));

      final key = r.buildSharedKey();

      expect(key.keyData.length, 2 * seg);
      expect(key.keyData.first, 1);
      expect(key.keyData.last, 2);
    });

    test('refuses a key with a missing segment', () {
      final r = reader()
        ..addSegmentData(0, segment(1))
        ..addSegmentData(2 * seg, segment(3));

      expect(r.buildSharedKey, throwsStateError);
    });

    test('refuses a key whose first segment is missing', () {
      final r = reader()..addSegmentData(seg, segment(2));

      expect(r.buildSharedKey, throwsStateError);
    });
  });

  group('KexSessionReader.limitSegments', () {
    test('keeps only the announced prefix', () {
      final r = reader()
        ..addSegmentData(0, segment(1))
        ..addSegmentData(seg, segment(2))
        ..addSegmentData(2 * seg, segment(3));

      r.limitSegments(2);

      expect(r.totalSegments, 2);
      expect(r.buildSharedKey().keyData.length, 2 * seg);
    });

    test('leaves a gap visible when the prefix itself is incomplete', () {
      final r = reader()
        ..addSegmentData(0, segment(1))
        ..addSegmentData(2 * seg, segment(3));

      r.limitSegments(3);

      expect(r.totalSegments, 2);
      expect(r.buildSharedKey, throwsStateError);
    });
  });
}
