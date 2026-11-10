import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/firestore/fs_kex.dart';
import '../app_logger.dart';
import '../key_service.dart';
import 'kex_source_controller.dart';
import 'kex_sync_channel.dart';
import 'segment_codec.dart';

/// Reader side of a key exchange, without any UI.
///
/// The screen feeds every payload it receives (scanned QR codes today) to
/// [onPayload]. Each new segment is stored and acknowledged on the
/// [KexSyncChannel]; when the source completes the session, [result] yields
/// the segments the source decided to keep.
class KexReaderController extends ChangeNotifier {
  final KexSyncChannel _sync;
  final KeyService _keyService;
  final SegmentCodec _codec;
  final String localId;
  final String conversationId;
  final _log = AppLogger();

  KexSessionReader? session;
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
    SegmentCodec codec = const Base45SegmentCodec(),
  })  : _sync = sync,
        _keyService = keyService,
        _codec = codec;

  Future<KexResult> get result => _result.future;

  int get segmentsRead => session?.readSegmentsCount ?? 0;

  int get totalSegments => syncState?.totalSegments ?? 0;

  bool get isCompleted => syncState?.status == KeyExchangeStatus.completed;

  bool get hasFinishedScanning => syncState?.hasParticipantFinishedScanning(localId) ?? false;

  /// Handles one received payload. Duplicates and payloads arriving while the
  /// previous one is processed are ignored.
  Future<void> onPayload(String payload) async {
    if (_processing || _finalizing || _disposed) return;
    _processing = true;
    try {
      final segment = _codec.decode(payload);
      if (session == null) await _join(segment.sessionId);
      if (session == null || segment.sessionId != session!.sessionId) return;
      if (session!.hasScannedSegment(segment.segmentIndex)) return;
      _keyService.recordReadSegment(session!, segment);
      _log.i('QR SCAN', 'Segment ${segment.segmentIndex} read ($segmentsRead read)');
      error = null;
      _notify();
      // Acknowledged in the background so the camera is not blocked by the network
      _pendingAcks.add(segment.segmentIndex);
      unawaited(_sendAcks());
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

  Future<void> _join(String sessionId) async {
    final state = await _sync.getSession(sessionId);
    if (state == null) throw StateError('Session not found');
    syncState = state;
    session = _keyService.createReaderSession(
      conversationId: conversationId,
      sessionId: sessionId,
      localPeerId: localId,
      peerIds: state.participants,
    );
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
