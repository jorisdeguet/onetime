import 'package:flutter_test/flutter_test.dart';
import 'package:onetime/services/key_service.dart';
import 'package:onetime/services/key_transfer/kex_reader_controller.dart';
import 'package:onetime/services/key_transfer/kex_source_controller.dart';
import 'package:onetime/services/key_transfer/segment_codec.dart';

import 'support/in_memory_kex_sync_channel.dart';

void main() {
  const seg = KeyService.segmentSizeBytes;
  late InMemoryKexSyncChannel sync;
  late KexSourceController source;
  late KexReaderController reader;

  Future<void> settle() => pumpEventQueue(times: 50);

  /// Payload for segment [index], as the reader's camera would receive it.
  String payload(int index) {
    final data = source.session!.getSegmentData(index)!;
    return const JsonSegmentCodec().encode(KeySegmentQrData(
      sessionId: source.session!.sessionId,
      segmentIndex: index,
      startByte: index * seg,
      endByte: index * seg + data.length,
      keyData: data,
    ));
  }

  Future<void> startExchange(int segments) async {
    await source.start(segments * seg);
    await settle();
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
    await startExchange(8);
    for (int i = 0; i < 8; i++) {
      await reader.onPayload(payload(i));
    }
    final sourceResult = await source.result;
    await source.complete('conv');
    final readerResult = await reader.result;

    expect(sourceResult.newKey.keyData.length, 8 * seg);
    expect(readerResult.newKey.keyData, sourceResult.newKey.keyData);
  });

  test('segments received out of order and repeated still give the same key', () async {
    await startExchange(5);
    for (final i in [3, 0, 3, 4, 1, 0, 2]) {
      await reader.onPayload(payload(i));
    }
    final sourceResult = await source.result;
    await source.complete('conv');
    final readerResult = await reader.result;

    expect(readerResult.newKey.keyData, sourceResult.newKey.keyData);
  });

  test('keeps every segment received by all, whatever segment is on display', () async {
    await startExchange(8);
    // The display has moved on to segment 4 when the last acknowledgements arrive
    for (int i = 0; i < 4; i++) {
      source.tick();
    }
    expect(source.currentSegment!.segmentIndex, 4);
    for (int i = 0; i < 8; i++) {
      await reader.onPayload(payload(i));
    }

    expect((await source.result).newKey.keyData.length, 8 * seg);
  });

  test('early termination keeps the prefix every reader holds, on both sides', () async {
    await startExchange(6);
    for (final i in [0, 1, 3, 4]) {
      await reader.onPayload(payload(i));
    }
    await settle();
    await source.terminate();
    final sourceResult = await source.result;
    await source.complete('conv');
    final readerResult = await reader.result;

    expect(sourceResult.newKey.keyData.length, 2 * seg);
    expect(readerResult.newKey.keyData, sourceResult.newKey.keyData);
  });

  test('rotation slows down only when a reader missed a whole round', () async {
    await startExchange(8);
    final initial = source.rotationInterval;
    // Round with no acknowledgement: 0 -> 7 -> wraps to 0 (8 x 300 ms)
    for (int i = 0; i < 8; i++) {
      source.tick();
    }
    expect(source.rotationInterval, initial * 1.5);
    // Round where the reader acknowledged a segment: no further slow-down
    await reader.onPayload(payload(1));
    await settle();
    for (int i = 0; i < 7; i++) {
      source.tick();
    }
    expect(source.rotationInterval, initial * 1.5);
  });

  test('a short round is judged together with the next one', () async {
    await startExchange(8);
    for (final i in [1, 2, 3, 4, 5]) {
      await reader.onPayload(payload(i));
    }
    await settle();
    final initial = source.rotationInterval;
    // Only 0, 6 and 7 remain: a 900 ms round, shorter than an acknowledgement may take
    for (int i = 0; i < 3; i++) {
      source.tick();
    }
    expect(source.rotationInterval, initial);
    await reader.onPayload(payload(6));
    await settle();
    // Two more short rounds with an acknowledgement in between: still no slow-down
    for (int i = 0; i < 4; i++) {
      source.tick();
    }
    expect(source.rotationInterval, initial);
  });

  test('rotation skips segments everyone already holds', () async {
    await startExchange(4);
    await reader.onPayload(payload(1));
    await reader.onPayload(payload(2));
    await settle();
    source.tick();

    expect(source.currentSegment!.segmentIndex, 3);
  });

  test('reader ignores segments from another exchange', () async {
    await startExchange(2);
    await reader.onPayload(payload(0));
    final foreign = const JsonSegmentCodec().encode(KeySegmentQrData(
      sessionId: 'other_session',
      segmentIndex: 1,
      startByte: seg,
      endByte: 2 * seg,
      keyData: source.session!.getSegmentData(1)!,
    ));
    await reader.onPayload(foreign);

    expect(reader.segmentsRead, 1);
  });
}
