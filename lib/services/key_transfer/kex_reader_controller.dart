import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/firestore/fs_kex.dart';
import '../app_logger.dart';
import '../key_service.dart';
import 'kex_source_controller.dart';
import 'fountain.dart';
import 'kex_sync_channel.dart';

/// Reader side of a key exchange, without any UI.
///
/// The screen feeds every payload it receives (scanned QR codes) to
/// [onPayload]. Fountain packets are decoded block by block; each rebuilt
/// block is stored and acknowledged on the [KexSyncChannel]. When the source
/// completes the session, [result] yields the segments the source kept.
class KexReaderController extends ChangeNotifier {
  final KexSyncChannel _sync;
  final KeyService _keyService;
  final FountainCodec _codec = const FountainCodec();
  final String localId;
  final String conversationId;
  final _log = AppLogger();

  KexSessionReader? session;
  FountainDecoder? _decoder;
  FsKex? syncState;
  String? error;

  final Completer<KexResult> _result = Completer<KexResult>();
  StreamSubscription<FsKex?>? _syncSubscription;
  bool _processing = false;
  final Set<int> _pendingAcks = {};
  bool _sendingAcks = false;
  bool _finalizing = false;
  bool _disposed = false;

  KexReaderController({
    required KexSyncChannel sync,
    required KeyService keyService,
    required this.localId,
    required this.conversationId,
  })  : _sync = sync,
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
    if (_processing || _finalizing || _disposed) return;
    _processing = true;
    try {
      final packet = _codec.decode(payload);
      if (session == null) await _join(packet);
      if (session == null || packet.sessionId != session!.sessionId) return;
      final block = _decoder!.add(packet);
      error = null;
      _log.d('QR SCAN', 'Packet ${packet.block}/${packet.index} read ($segmentsRead known)');
      if (block != null) _onBlockDecoded(block);
      _notify();
    } catch (e) {
      _log.e('QR SCAN', 'Payload rejected: $e');
      error = e.toString();
      _notify();
    } finally {
      _processing = false;
    }
  }

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

  Future<void> _join(FountainPacket packet) async {
    final sessionId = packet.sessionId;
    final state = await _sync.getSession(sessionId);
    if (state == null) throw StateError('Session not found');
    syncState = state;
    session = _keyService.createReaderSession(
      conversationId: conversationId,
      sessionId: sessionId,
      localPeerId: localId,
      peerIds: state.participants,
    );
    _decoder = FountainDecoder(FountainLayout(
      totalBytes: packet.totalBytes,
      symbolSize: packet.symbolSize,
      blockSymbols: packet.blockSymbols,
    ));
    _syncSubscription = _sync.watchSession(sessionId).listen(onSyncUpdate);
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
    super.dispose();
  }
}
