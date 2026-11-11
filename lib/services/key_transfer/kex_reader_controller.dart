import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/firestore/fs_kex.dart';
import '../app_logger.dart';
import '../key_service.dart';
import 'kex_source_controller.dart';
import 'fountain.dart';
import 'kex_bluetooth_transfer.dart';
import 'kex_link.dart';
import 'kex_sync_channel.dart';

/// Reader side of a key exchange, without any UI.
///
/// The screen feeds every payload it receives (scanned QR codes) to
/// [onPayload]. Fountain packets are decoded block by block; each rebuilt
/// block is stored and acknowledged on the [KexSyncChannel]. When the source
/// completes the session, [result] yields the segments the source kept.
///
/// When the scanned code is a [KexInvite] (Bluetooth mode), the packets come
/// encrypted over [KexDataLink] instead and the camera is no longer needed.
class KexReaderController extends ChangeNotifier {
  final KexSyncChannel _sync;
  final KexDataLink? _data;
  final KeyService _keyService;
  final FountainCodec _codec = const FountainCodec();
  final String localId;
  final String conversationId;
  final _log = AppLogger();

  KexSessionReader? session;
  FountainDecoder? _decoder;
  String? _sessionId;
  bool _joining = false;
  // Blocks rebuilt before the session was joined, stored once it is
  final List<int> _blocksAwaitingSession = [];
  FsKex? syncState;
  String? error;

  /// Bluetooth mode, from the moment the invite is scanned.
  bool usesBluetooth = false;
  bool bluetoothConnected = false;
  KexPacketCipher? _cipher;
  StreamSubscription<Uint8List>? _dataSubscription;
  Future<void> _dataQueue = Future.value();
  int rejectedPackets = 0;
  int _packetsSinceNotify = 0;
  int _bluetoothPackets = 0;
  int _highestSequence = 0;

  final Completer<KexResult> _result = Completer<KexResult>();
  StreamSubscription<FsKex?>? _syncSubscription;
  bool _processing = false;
  final Set<int> _pendingAcks = {};
  bool _sendingAcks = false;
  bool _finalizing = false;
  bool _disposed = false;

  KexReaderController({
    required KexSyncChannel sync,
    KexDataLink? data,
    required KeyService keyService,
    required this.localId,
    required this.conversationId,
  })  : _sync = sync,
        _data = data,
        _keyService = keyService;

  Future<KexResult> get result => _result.future;

  /// Segments known so far, including those of blocks not fully rebuilt yet.
  int get segmentsRead => _decoder?.symbolsKnown ?? 0;

  int get totalSegments => syncState?.totalSegments ?? 0;

  bool get isCompleted => syncState?.status == KeyExchangeStatus.completed;

  bool get hasFinishedScanning => syncState?.hasParticipantFinishedScanning(localId) ?? false;

  /// Handles one received payload. Payloads arriving while the previous one
  /// is processed are ignored; duplicates add nothing.
  Future<void> onPayload(String payload) async {
    if (_processing || _finalizing || _disposed || usesBluetooth) return;
    final invite = _decoder == null ? KexInvite.tryDecode(payload) : null;
    if (invite != null) return _startBluetooth(invite);
    _processing = true;
    try {
      _onPacket(_codec.decode(payload));
    } catch (e) {
      _log.e('QR SCAN', 'Payload rejected: $e');
      error = e.toString();
      _notify();
    } finally {
      _processing = false;
    }
  }

  /// Bluetooth mode: joins the session and receives the packets over the
  /// link, encrypted with the invite's secret.
  Future<void> _startBluetooth(KexInvite invite) async {
    final data = _data;
    if (data == null) {
      error = 'Bluetooth non disponible sur cet appareil';
      _notify();
      return;
    }
    usesBluetooth = true;
    _sessionId = invite.sessionId;
    _cipher = KexPacketCipher(invite);
    _dataSubscription = data.data.listen((message) {
      _dataQueue = _dataQueue.then((_) => _onEncrypted(message));
    });
    _notify();
    unawaited(_join(invite.sessionId));
    try {
      await data.connectReader(invite.sessionId);
      bluetoothConnected = true;
      error = null;
    } catch (e) {
      _log.e('KeyExchange', 'Bluetooth connection failed: $e');
      error = 'Connexion Bluetooth impossible. Rapprochez les téléphones ou choisissez le mode QR.';
    }
    _notify();
  }

  Future<void> _onEncrypted(Uint8List message) async {
    if (_finalizing || _disposed) return;
    try {
      final packet = _codec.decodeBytes(await _cipher!.decrypt(message));
      // Reported by sequence number, so lost packets do not hold the source back
      final next = KexPacketCipher.sequenceOf(message) + 1;
      if (next > _highestSequence) _highestSequence = next;
      if (++_bluetoothPackets % 4 == 0) _data!.reportReceived(_highestSequence);
      _onPacket(packet);
    } catch (e) {
      // Lost frame or forged packet: the fountain code makes up for it
      rejectedPackets++;
      _log.d('KeyExchange', 'Bluetooth packet rejected: $e');
    }
  }

  void _onPacket(FountainPacket packet) {
    // Packets describe the transfer themselves: decoding starts at once and
    // the session is joined meanwhile, so no code is lost while joining
    if (_decoder == null) {
      _sessionId = packet.sessionId;
      _decoder = FountainDecoder(FountainLayout(
        totalBytes: packet.totalBytes,
        symbolSize: packet.symbolSize,
        blockSymbols: packet.blockSymbols,
      ));
    }
    if (packet.sessionId != _sessionId) return;
    if (session == null && !_joining) unawaited(_join(packet.sessionId));
    final block = _decoder!.add(packet);
    error = null;
    // Bluetooth delivers dozens of packets per second: no log line for each
    if (!usesBluetooth) _log.d('QR SCAN', 'Packet ${packet.block}/${packet.index} read ($segmentsRead known)');
    if (block != null) {
      if (session == null) {
        _blocksAwaitingSession.add(block);
      } else {
        _onBlockDecoded(block);
      }
    }
    if (!usesBluetooth || block != null || ++_packetsSinceNotify % 8 == 0) _notify();
  }

  /// Asks the source to end the exchange now; every participant keeps what
  /// all of them received.
  Future<void> stop() async {
    final id = session?.sessionId;
    if (id == null) return;
    // Acknowledge every block rebuilt so far first: the source keeps only
    // what it knows everyone holds when it sees the stop request
    for (int i = 0; i < 50 && (_sendingAcks || _pendingAcks.isNotEmpty); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await _sync.requestStop(id, localId);
  }

  /// True once the first block is rebuilt: stopping then keeps a key.
  bool get canStop => _decoder?.isBlockDecoded(0) ?? false;

  /// Bytes rebuilt so far.
  int get bytesRead => segmentsRead * KeyService.segmentSizeBytes;

  /// Applies a new snapshot of the shared session; finalizes once the source completes it.
  void onSyncUpdate(FsKex? state) {
    if (state == null || _disposed) return;
    syncState = state;
    _notify();
    if (state.status == KeyExchangeStatus.completed) _finalize();
  }

  /// Sends every pending acknowledgement, several per write while one is in flight.
  Future<void> _sendAcks() async {
    if (_sendingAcks) return;
    _sendingAcks = true;
    try {
      while (_pendingAcks.isNotEmpty && !_disposed) {
        final batch = _pendingAcks.toList()..sort();
        _pendingAcks.clear();
        try {
          await _sync.markSegmentsScanned(
            sessionId: session!.sessionId,
            participantId: localId,
            segmentIndexes: batch,
          );
        } catch (e) {
          // Retried with the next batch; the source keeps showing these segments meanwhile
          _log.w('QR SCAN', 'Acknowledgement of $batch failed: $e');
          _pendingAcks.addAll(batch);
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
    } finally {
      _sendingAcks = false;
    }
  }

  /// Stores the segments of a rebuilt block and acknowledges them in the
  /// background, so the camera is not blocked by the network.
  void _onBlockDecoded(int block) {
    final layout = _decoder!.layout;
    final first = layout.firstSymbol(block);
    for (int i = 0; i < layout.symbolsInBlock(block); i++) {
      final data = _decoder!.blockSymbol(block, i);
      final start = (first + i) * layout.symbolSize;
      _keyService.recordReadSegment(
        session!,
        KeySegmentQrData(
          sessionId: session!.sessionId,
          segmentIndex: first + i,
          startByte: start,
          endByte: start + data.length,
          keyData: data,
        ),
      );
      _pendingAcks.add(first + i);
    }
    _log.i('QR SCAN', 'Block $block rebuilt (${_decoder!.decodedBlocks}/${layout.blockCount})');
    unawaited(_sendAcks());
  }

  /// Joins the shared session; a failure is retried with the next packet.
  Future<void> _join(String sessionId) async {
    _joining = true;
    try {
      final state = await _sync.getSession(sessionId);
      if (state == null) throw StateError('Session not found');
      if (_disposed) return;
      syncState = state;
      session = _keyService.createReaderSession(
        conversationId: conversationId,
        sessionId: sessionId,
        localPeerId: localId,
        peerIds: state.participants,
      );
      _syncSubscription = _sync.watchSession(sessionId).listen(onSyncUpdate);
      for (final block in _blocksAwaitingSession) {
        _onBlockDecoded(block);
      }
      _blocksAwaitingSession.clear();
      _notify();
    } catch (e) {
      _log.e('QR SCAN', 'Could not join session $sessionId: $e');
      error = e.toString();
      _notify();
    } finally {
      _joining = false;
    }
  }

  void _finalize() {
    if (_finalizing || session == null) return;
    _finalizing = true;
    try {
      // The source decides how many segments are kept (early termination possible)
      final expected = syncState!.segmentsToKeep;
      session!.limitSegments(expected);
      if (session!.totalSegments != expected) {
        throw StateError('Segments manquants: ${session!.totalSegments}/$expected reçus. Recommencez l\'échange.');
      }
      final newKey = _keyService.finalizeExchange(session!, force: true);
      _result.complete(KexResult(newKey: newKey, syncState: syncState!));
    } catch (e) {
      _log.e('KeyExchange', 'Reader exchange failed: $e');
      error = e.toString();
      if (!_result.isCompleted) _result.completeError(e);
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _syncSubscription?.cancel();
    _dataSubscription?.cancel();
    super.dispose();
  }
}
