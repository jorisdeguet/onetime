import 'package:flutter_test/flutter_test.dart';
import 'package:onetime/services/key_service.dart';
import 'package:onetime/services/key_transfer/fountain.dart';
import 'package:onetime/services/key_transfer/kex_reader_controller.dart';
import 'package:onetime/services/key_transfer/kex_source_controller.dart';

import 'support/in_memory_kex_sync_channel.dart';

void main() {
  const seg = KeyService.segmentSizeBytes;
  late InMemoryKexSyncChannel sync;
  late KexSourceController source;
  late KexReaderController reader;

  Future<void> settle() => pumpEventQueue(times: 50);

  /// Packet [index] of [block], as the reader's camera would receive it.
  String payload(int block, int index, {String? sessionId}) {
    final encoder = FountainEncoder(
      layout: FountainLayout(totalBytes: source.session!.totalSegments * seg, symbolSize: seg),
      sessionId: sessionId ?? source.session!.sessionId,
      symbolAt: source.session!.getSegmentData,
    );
    return const FountainCodec().encode(encoder.packet(block, index)!);
  }

  /// Every segment of the exchange, shown once.
  Iterable<String> systematic(int segments) sync* {
    for (int i = 0; i < segments; i++) {
      yield payload(i ~/ 32, i % 32);
    }
  }

  Future<void> startExchange(int segments) async {
    await source.start(segments * seg);
    while (source.session!.currentSegmentIndex < segments) {
      await settle();
    }
  }

  setUp(() {
    sync = InMemoryKexSyncChannel();
    source = KexSourceController(
      sync: sync,
      keyService: KeyService(),
      localId: 'alice',
      conversationId: 'conv',
      peerIds: ['bob'],
      autoRotate: false,
    );
    reader = KexReaderController(
      sync: sync,
      keyService: KeyService(),
      localId: 'bob',
      conversationId: 'conv',
    );
  });

  tearDown(() {
    source.dispose();
    reader.dispose();
  });

  test('both sides end with the same full key', () async {
    await startExchange(40);
    for (final p in systematic(40)) {
      await reader.onPayload(p);
    }
    final sourceResult = await source.result;
    await source.complete('conv');
    final readerResult = await reader.result;

    expect(sourceResult.newKey.keyData.length, 40 * seg);
    expect(readerResult.newKey.keyData, sourceResult.newKey.keyData);
  });

  test('repair packets make up for missed segments', () async {
    await startExchange(8);
    for (final i in [0, 2, 3, 5, 7]) {
      await reader.onPayload(payload(0, i));
    }
    // Repeats add nothing; repair packets fill the three gaps
    await reader.onPayload(payload(0, 3));
    for (int r = 8; !reader.isCompleted && r < 40; r++) {
      await reader.onPayload(payload(0, r));
      await settle();
    }
    final sourceResult = await source.result;
    await source.complete('conv');
    final readerResult = await reader.result;

    expect(readerResult.newKey.keyData, sourceResult.newKey.keyData);
    expect(readerResult.newKey.keyData.length, 8 * seg);
  });

  test('early termination keeps the blocks every reader rebuilt, as a prefix', () async {
    await startExchange(70);
    final all = systematic(70).toList();
    // Blocks 0 and 2 complete, block 1 missing its last segment
    for (int i = 0; i < 70; i++) {
      if (i != 63) await reader.onPayload(all[i]);
    }
    await settle();
    await source.terminate();
    final sourceResult = await source.result;
    await source.complete('conv');
    final readerResult = await reader.result;

    expect(sourceResult.newKey.keyData.length, 32 * seg);
    expect(readerResult.newKey.keyData, sourceResult.newKey.keyData);
  });

  test('rotation skips blocks everyone already holds', () async {
    await startExchange(40);
    expect(source.currentPacket!.block, 0);
    for (final p in systematic(32)) {
      await reader.onPayload(p);
    }
    await settle();
    source.tick();

    expect(source.currentPacket!.block, 1);
    expect(source.currentLabel, '33/40');
  });

  test('after the first pass, only incomplete blocks get repair packets', () async {
    await startExchange(40);
    for (final p in systematic(40).skip(32)) {
      await reader.onPayload(p);
    }
    await settle();
    for (int i = 0; i < 40; i++) {
      source.tick();
    }
    expect(source.currentPacket!.block, 0);
    expect(source.currentPacket!.index, greaterThanOrEqualTo(32));
  });

  test('reader ignores packets from another exchange', () async {
    await startExchange(2);
    await reader.onPayload(payload(0, 0));
    await reader.onPayload(payload(0, 1, sessionId: 'other_session'));

    expect(reader.segmentsRead, 1);
  });
}
