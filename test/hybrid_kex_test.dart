import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:onetime/models/firestore/fs_kex.dart';
import 'package:onetime/services/key_service.dart';
import 'package:onetime/services/key_transfer/fountain.dart';
import 'package:onetime/services/key_transfer/hybrid_kex_sync_channel.dart';
import 'package:onetime/services/key_transfer/kex_bluetooth_transfer.dart';
import 'package:onetime/services/key_transfer/kex_link.dart';
import 'package:onetime/services/key_transfer/kex_reader_controller.dart';
import 'package:onetime/services/key_transfer/kex_source_controller.dart';
import 'package:onetime/services/key_transfer/kex_wire.dart';

import 'support/in_memory_kex_sync_channel.dart';

/// Server channel counting the acknowledgements it carries.
class CountingRemote extends InMemoryKexSyncChannel {
  int acks = 0;
  @override
  Future<void> markSegmentsScanned({
    required String sessionId,
    required String participantId,
    required List<int> segmentIndexes,
  }) {
    acks++;
    return super.markSegmentsScanned(sessionId: sessionId, participantId: participantId, segmentIndexes: segmentIndexes);
  }
}

/// Radio shared by the fake links of one test.
class FakeAir {
  final Map<String, FakeHost> hosts = {};
  bool available = true;
}

class FakeHost implements KexHostLink {
  final FakeAir air;
  final List<FakeClient> clients = [];
  late void Function(KexReaderMessage) onMessage;
  FakeHost(this.air);

  @override
  Future<void> start(FsKex session, void Function(KexReaderMessage) onMessage) async {
    if (!air.available) throw StateError('Bluetooth poweredOff');
    this.onMessage = onMessage;
    air.hosts[session.id] = this;
  }

  @override
  void publish(FsKex state) {
    // Through the wire format, as over the radio
    final bytes = KexWire.encodeState(state);
    for (final c in clients) {
      scheduleMicrotask(() => c.controller.add(KexWire.decodeState(bytes)));
    }
  }

  @override
  int get dataReceivers => clients.length;

  /// Packets dropped on the way, as a radio may (every n-th one).
  int dropEvery = 0;
  int _sent = 0;

  @override
  Future<void> sendData(Uint8List message) async {
    await Future.delayed(Duration.zero);
    if (dropEvery > 0 && ++_sent % dropEvery == 0) return;
    for (final c in clients) {
      c.dataController.add(message);
    }
  }

  @override
  Future<void> stop() async => air.hosts.removeWhere((_, h) => h == this);
}

class FakeClient implements KexClientLink {
  final FakeAir air;
  final controller = StreamController<FsKex>.broadcast();
  final dataController = StreamController<Uint8List>.broadcast();
  FakeHost? host;
  FakeClient(this.air);

  @override
  Future<void> connect(String sessionId, String participantId, {Duration timeout = const Duration(seconds: 1)}) async {
    final h = air.hosts[sessionId];
    if (h == null) throw TimeoutException('Source not found');
    host = h..clients.add(this);
    await send(KexHello(participantId, sessionId));
  }

  @override
  Stream<FsKex> get states => controller.stream;

  @override
  Stream<Uint8List> get data => dataController.stream;

  @override
  bool get isConnected => host != null && air.hosts.containsValue(host);

  @override
  Future<void> send(KexReaderMessage message) async {
    if (!isConnected) throw StateError('Not connected');
    final bytes = KexWire.encodeReaderMessage(message);
    await Future.delayed(Duration.zero);
    host!.onMessage(KexWire.decodeReaderMessage(bytes));
  }

  @override
  Future<void> close() async => host?.clients.remove(this);
}

void main() {
  const seg = KeyService.segmentSizeBytes;

  group('wire format', () {
    test('session state survives encoding', () {
      final s = FsKex(
        id: 'kex_1',
        conversationId: 'conv',
        sourceId: 'alice',
        segmentsByPeer: {'alice': List.generate(100, (i) => i), 'bob': [0, 1, 2, 5, 6, 64]},
        status: KeyExchangeStatus.completed,
        announcedSegments: 64,
        stopRequestedBy: ['bob'],
      );
      final d = KexWire.decodeState(KexWire.encodeState(s));
      expect(d.id, 'kex_1');
      expect(d.conversationId, 'conv');
      expect(d.segmentsByPeer['bob'], [0, 1, 2, 5, 6, 64]);
      expect(d.totalSegments, 100);
      expect(d.status, KeyExchangeStatus.completed);
      expect(d.segmentsToKeep, 64);
      expect(d.stopRequestedBy, ['bob']);
    });

    test('reader messages survive encoding', () {
      final ack = KexWire.decodeReaderMessage(KexWire.encodeReaderMessage(const KexAck('bob', [33, 32, 34, 70])));
      expect(ack, isA<KexAck>());
      expect((ack as KexAck).segments, [32, 33, 34, 70]);
      final hello = KexWire.decodeReaderMessage(KexWire.encodeReaderMessage(const KexHello('bob', 'kex_1')));
      expect((hello as KexHello).sessionId, 'kex_1');
      expect(KexWire.decodeReaderMessage(KexWire.encodeReaderMessage(const KexStop('bob'))), isA<KexStop>());
    });

    test('frames reassemble into the original message', () {
      final message = Uint8List.fromList(List.generate(1000, (i) => i % 251));
      for (final size in [2, 20, 244, 2000]) {
        final reader = KexFrameReader();
        Uint8List? out;
        for (final f in KexWire.frame(message, size)) {
          expect(f.length, lessThanOrEqualTo(size));
          expect(out, isNull);
          out = reader.add(f);
        }
        expect(out, message);
      }
    });

    test('merge keeps what either view knows', () {
      FsKex kex({List<int> bob = const [], KeyExchangeStatus status = KeyExchangeStatus.inProgress, int? announced}) => FsKex(
            id: 'k',
            sourceId: 'alice',
            segmentsByPeer: {'alice': [0, 1, 2, 3], 'bob': bob},
            status: status,
            announcedSegments: announced,
          );
      final m = mergeKex(kex(bob: [0, 1], announced: 4), kex(bob: [2], status: KeyExchangeStatus.completed, announced: 3));
      expect(m.segmentsByPeer['bob'], [0, 1, 2]);
      expect(m.status, KeyExchangeStatus.completed);
      expect(m.segmentsToKeep, 3);
    });
  });

  group('exchange over the hybrid channel', () {
    late CountingRemote remote;
    late FakeAir air;
    late HybridKexSyncChannel sourceSync, readerSync;
    late KexSourceController source;
    late KexReaderController reader;

    Future<void> settle() => pumpEventQueue(times: 50);

    String payload(int block, int index) {
      final encoder = FountainEncoder(
        layout: FountainLayout(totalBytes: source.session!.totalSegments * seg, symbolSize: seg),
        sessionId: source.session!.sessionId,
        symbolAt: source.session!.getSegmentData,
      );
      return const FountainCodec().encode(encoder.packet(block, index)!);
    }

    Future<void> showAll(int segments) async {
      while (source.session!.currentSegmentIndex < segments) {
        await settle();
      }
      for (int i = 0; i < segments; i++) {
        await reader.onPayload(payload(i ~/ 32, i % 32));
        await settle();
      }
    }

    setUp(() {
      remote = CountingRemote();
      air = FakeAir();
      sourceSync = HybridKexSyncChannel(remote: remote, localId: 'alice', hostLink: () => FakeHost(air), clientLink: () => FakeClient(air));
      readerSync = HybridKexSyncChannel(remote: remote, localId: 'bob', hostLink: () => FakeHost(air), clientLink: () => FakeClient(air));
      source = KexSourceController(
        sync: sourceSync,
        data: sourceSync,
        keyService: KeyService(),
        localId: 'alice',
        conversationId: 'conv',
        peerIds: ['bob'],
        autoRotate: false,
      );
      reader = KexReaderController(sync: readerSync, data: readerSync, keyService: KeyService(), localId: 'bob', conversationId: 'conv');
    });

    tearDown(() async {
      source.dispose();
      reader.dispose();
      await sourceSync.close();
      await readerSync.close();
    });

    test('acknowledgements go over the link, not the server', () async {
      await source.start(70 * seg);
      await settle();
      await showAll(70);
      final sourceResult = await source.result;
      await source.complete('conv');
      final readerResult = await reader.result;

      expect(readerResult.newKey.keyData, sourceResult.newKey.keyData);
      expect(sourceResult.newKey.keyData.length, 70 * seg);
      // The first block may be acknowledged on the server while the link opens
      expect(remote.acks, lessThanOrEqualTo(1));
      expect(readerSync.usesLink, isTrue);
    });

    test('without Bluetooth, the server carries everything', () async {
      air.available = false;
      await source.start(40 * seg);
      await settle();
      await showAll(40);
      final sourceResult = await source.result;
      await source.complete('conv');
      final readerResult = await reader.result;

      expect(readerResult.newKey.keyData, sourceResult.newKey.keyData);
      expect(remote.acks, greaterThan(0));
      expect(readerSync.usesLink, isFalse);
    });

    test('a continuous exchange stops on a request sent over the link', () async {
      await source.start(600 * seg, continuous: true);
      await settle();
      for (int i = 0; i < 64; i++) {
        while (source.session!.getSegmentData(i) == null) {
          await settle();
        }
        await reader.onPayload(payload(i ~/ 32, i % 32));
        await settle();
      }
      await reader.stop();
      final sourceResult = await source.result;
      await source.complete('conv');
      final readerResult = await reader.result;

      expect(sourceResult.newKey.keyData.length, 64 * seg);
      expect(readerResult.newKey.keyData, sourceResult.newKey.keyData);
    });

    test('the source ignores acknowledgements from strangers', () async {
      await source.start(40 * seg);
      await settle();
      final intruder = FakeClient(air);
      await intruder.connect(source.syncState!.id, 'mallory');
      await intruder.send(const KexAck('mallory', [0, 1, 2]));
      await intruder.send(const KexAck('bob', [0, 1, 2]));
      await settle();
      // A stranger may claim to be a participant: it only slows the exchange
      // (the source skips codes bob lacks), it never sees key bytes
      expect(source.syncState!.segmentsByPeer.containsKey('mallory'), isFalse);
    });

    Future<void> waitFor(bool Function() done) async {
      for (int i = 0; i < 2000 && !done(); i++) {
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }

    test('Bluetooth mode: one code, then the key over the link, encrypted', () async {
      await source.start(100 * seg, bluetooth: true);
      expect(source.usesBluetooth, isTrue);
      final invite = KexInvite.tryDecode(source.currentPayload!);
      expect(invite, isNotNull);
      await reader.onPayload(source.currentPayload!);
      expect(reader.usesBluetooth, isTrue);
      final sourceResult = await source.result.timeout(const Duration(seconds: 20));
      await source.complete('conv');
      final readerResult = await reader.result.timeout(const Duration(seconds: 5));

      expect(readerResult.newKey.keyData, sourceResult.newKey.keyData);
      expect(sourceResult.newKey.keyData.length, 100 * seg);
      expect(remote.acks, 0);
    });

    test('Bluetooth mode survives lost packets', () async {
      await source.start(70 * seg, bluetooth: true);
      air.hosts.values.single.dropEvery = 5;
      await reader.onPayload(source.currentPayload!);
      final sourceResult = await source.result.timeout(const Duration(seconds: 20));
      await source.complete('conv');
      final readerResult = await reader.result.timeout(const Duration(seconds: 5));
      expect(readerResult.newKey.keyData, sourceResult.newKey.keyData);
    });

    test('Bluetooth mode rejects packets not encrypted with the secret', () async {
      await source.start(40 * seg, bluetooth: true);
      final host = air.hosts.values.single;
      await reader.onPayload(source.currentPayload!);
      await waitFor(() => reader.bluetoothConnected);
      final forged = KexPacketCipher(KexInvite.generate(sessionId: source.syncState!.id, totalBytes: 40 * seg));
      final packet = FountainEncoder(
        layout: FountainLayout(totalBytes: 40 * seg, symbolSize: seg),
        sessionId: source.syncState!.id,
        symbolAt: (_) => Uint8List(seg),
      ).packet(0, 0)!;
      await host.sendData(await forged.encrypt(const FountainCodec().encodeBytes(packet)));
      await waitFor(() => reader.rejectedPackets > 0);
      expect(reader.rejectedPackets, greaterThan(0));
      final sourceResult = await source.result.timeout(const Duration(seconds: 20));
      await source.complete('conv');
      expect((await reader.result).newKey.keyData, sourceResult.newKey.keyData);
    });

    test('without Bluetooth, the Bluetooth mode falls back to QR codes', () async {
      air.available = false;
      await source.start(40 * seg, bluetooth: true);
      expect(source.usesBluetooth, isFalse);
      expect(source.bluetoothUnavailable, isTrue);
      expect(KexInvite.tryDecode(source.currentPayload!), isNull);
    });
  });
}
