import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:onetime/services/key_transfer/fountain.dart';

void main() {
  final random = Random(7);
  Uint8List randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => random.nextInt(256)));

  /// Streams packets, dropping each with [lossRate], until the reader has the
  /// whole key. Returns the packets shown.
  int transfer(Uint8List key, {double lossRate = 0, int symbolSize = 1024}) {
    final layout = FountainLayout(totalBytes: key.length, symbolSize: symbolSize);
    Uint8List? symbolAt(int i) => Uint8List.sublistView(key, i * symbolSize, min((i + 1) * symbolSize, key.length));
    final encoder = FountainEncoder(layout: layout, sessionId: 's1', symbolAt: symbolAt);
    final decoder = FountainDecoder(layout);
    const codec = FountainCodec();
    int shown = 0;
    while (!decoder.isComplete) {
      final packet = encoder.next(decoder.isBlockDecoded)!;
      shown++;
      if (random.nextDouble() < lossRate) continue;
      decoder.add(codec.decode(codec.encode(packet)));
      expect(shown, lessThan(layout.symbolCount * 3 + 100), reason: 'transfer does not converge');
    }
    final rebuilt = BytesBuilder();
    for (int b = 0; b < layout.blockCount; b++) {
      for (int i = 0; i < layout.symbolsInBlock(b); i++) {
        rebuilt.add(decoder.blockSymbol(b, i));
      }
    }
    expect(rebuilt.toBytes(), key);
    return shown;
  }

  test('without loss, every symbol is shown exactly once', () {
    expect(transfer(randomBytes(64 * 1024)), 64);
  });

  test('rebuilds a key whose size is not a multiple of the symbol size', () {
    transfer(randomBytes(70 * 1024 + 123));
    transfer(randomBytes(300));
  });

  test('rebuilds the key with losses, at little cost', () {
    for (final loss in [0.05, 0.2, 0.5]) {
      final shown = transfer(randomBytes(256 * 1024), lossRate: loss);
      final ideal = 256 / (1 - loss);
      // ignore: avoid_print
      print('loss ${(loss * 100).round()}%: $shown packets shown for 256 symbols (ideal ${ideal.round()})');
      expect(shown, lessThan(ideal * 1.25));
    }
  });

  test('repair packets of one block are different and never empty', () {
    const layout = FountainLayout(totalBytes: 32 * 1024, symbolSize: 1024);
    final masks = {for (int i = 32; i < 132; i++) layout.mask(0, i)};
    expect(masks.length, greaterThan(95));
    expect(masks.contains(0), isFalse);
    // A one-symbol block only ever repeats its symbol
    const tiny = FountainLayout(totalBytes: 33 * 1024, symbolSize: 1024);
    expect(tiny.mask(1, 5), 1);
  });
}
