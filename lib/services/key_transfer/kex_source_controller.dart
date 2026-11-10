import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/firestore/fs_kex.dart';
import '../../models/local/shared_key.dart';
import '../app_logger.dart';
import '../key_service.dart';
import 'kex_sync_channel.dart';
import 'segment_codec.dart';

/// Key bytes produced by an exchange, identical on every participant.
class KexResult {
  final SharedKey newKey;
  final FsKex syncState;

  KexResult({required this.newKey, required this.syncState});
}

/// Source side of a key exchange, without any UI.
///
/// Generates the key segments, rotates the one on display ("torrent" mode),
/// follows the readers' acknowledgements on the [KexSyncChannel] and ends
/// the exchange once every reader holds every segment. The screen renders
/// [currentPayload] (as a QR code today) and listens for [result].
class KexSourceController extends ChangeNotifier {
  final KexSyncChannel _sync;
  final KeyService _keyService;
  final SegmentCodec _codec;
  final String localId;
  final String conversationId;
  final List<String> peerIds;
  final bool autoRotate;
  final _log = AppLogger();

  KexSessionSource? session;
  FsKex? syncState;
  KeySegmentQrData? currentSegment;
  Duration rotationInterval;
  String? error;

  final Completer<KexResult> _result = Completer<KexResult>();
  StreamSubscription<FsKex?>? _syncSubscription;
  Timer? _rotationTimer;
  bool _terminating = false;
  bool _disposed = false;
  // Segments each reader had acknowledged when the current rotation round started
  final Map<String, int> _progressAtRoundStart = {};

  KexSourceController({
    required KexSyncChannel sync,
    required KeyService keyService,
    required this.localId,
    required this.conversationId,
    required this.peerIds,
    SegmentCodec codec = const JsonSegmentCodec(),
    this.rotationInterval = const Duration(milliseconds: 600),
    this.autoRotate = true,
  })  : _sync = sync,
        _keyService = keyService,
        _codec = codec;

  Future<KexResult> get result => _result.future;

  String? get currentPayload => currentSegment == null ? null : _codec.encode(currentSegment!);

  int get totalSegments => session?.totalSegments ?? 0;

  /// Creates the shared session, shows the first segment and starts rotating.
  Future<void> start(int totalBytes, {List<KeySegmentQrData>? preGeneratedSegments}) async {
    final segmentCount = (totalBytes + KeyService.segmentSizeBytes - 1) ~/ KeyService.segmentSizeBytes;
    syncState = await _sync.createSession(
      sourceId: localId,
      participants: peerIds,
      totalKeyBytes: totalBytes,
      totalSegments: segmentCount,
    );
    session = _keyService.createSourceSession(
      conversationId: conversationId,
      totalBytes: totalBytes,
      peerIds: peerIds,
      sourceId: localId,
      sessionId: syncState!.id,
      preGeneratedSegments: preGeneratedSegments,
    );
    for (final peer in syncState!.otherParticipants) {
      _progressAtRoundStart[peer] = 0;
    }
    _syncSubscription = _sync.watchSession(syncState!.id).listen(onSyncUpdate);
    if (session!.getSegmentData(0) == null) _keyService.generateNextSegment(session!);
    _showSegment(0);
    if (autoRotate) _startRotation();
    unawaited(_generateRemainingSegments());
  }

  /// Applies a new snapshot of the shared session; ends the exchange when complete.
  void onSyncUpdate(FsKex? state) {
    if (state == null || _disposed) return;
    syncState = state;
    _notify();
    if (_terminating || session == null) return;
    for (int i = 0; i < session!.totalSegments; i++) {
      if (!state.allParticipantsScannedSegment(i)) return;
    }
    _log.i('KeyExchange', 'All segments complete - auto terminating');
    unawaited(terminate());
  }

  /// One rotation step: shows the next segment some reader still misses.
  void tick() {
    if (session == null || syncState == null || _terminating) return;
    final total = session!.totalSegments;
    final displayed = currentSegment?.segmentIndex ?? 0;
    for (int offset = 1; offset <= total; offset++) {
      final index = (displayed + offset) % total;
      if (syncState!.allParticipantsScannedSegment(index)) continue;
      if (index < displayed) _onRoundCompleted();
      if (index != displayed) _showSegment(index);
      return;
    }
    _stopRotation();
  }

  /// Ends the exchange, keeping the longest prefix of segments every reader holds.
  Future<void> terminate() async {
    if (_terminating || session == null || syncState == null) return;
    _terminating = true;
    _stopRotation();
    await _syncSubscription?.cancel();
    try {
      int kept = 0;
      while (kept < session!.currentSegmentIndex && syncState!.allParticipantsScannedSegment(kept)) {
        kept++;
      }
      if (kept == 0) throw StateError('No segment was received by every participant');
      _log.d('KeyExchange', 'Keeping $kept of ${session!.totalSegments} segments');
      await _sync.updateTotalSegments(syncState!.id, kept, kept * KeyService.segmentSizeBytes);
      // Keep exactly the segments announced to the readers, otherwise the source's
      // key would be longer than theirs and shifted at the next extension.
      session!.limitSegments(kept);
      final newKey = _keyService.finalizeExchange(session!, force: true);
      _result.complete(KexResult(newKey: newKey, syncState: syncState!));
    } catch (e) {
      _fail(e);
    }
  }

  /// Tells the readers the exchange is over; they finalize on this signal.
  Future<void> complete(String conversationId) async {
    final id = syncState?.id;
    if (id == null) return;
    await _sync.setConversationId(id, conversationId);
    await _sync.completeSession(id);
  }

  /// Removes the shared session (the source is in charge of cleanup).
  Future<void> cleanup() async {
    final id = syncState?.id;
    if (id != null) await _sync.deleteSession(id);
  }

  void _showSegment(int index) {
    final data = session!.getSegmentData(index);
    if (data == null) return;
    final start = index * KeyService.segmentSizeBytes;
    currentSegment = KeySegmentQrData(
      sessionId: session!.sessionId,
      segmentIndex: index,
      startByte: start,
      endByte: start + data.length,
      keyData: data,
    );
    _log.d('Torrent', 'Displaying segment $index');
    _notify();
  }

  /// Slows the rotation when some reader acknowledged nothing during a whole round.
  void _onRoundCompleted() {
    bool someoneMissedRound = false;
    for (final peer in syncState!.otherParticipants) {
      final progress = syncState!.getParticipantProgress(peer);
      if (progress == (_progressAtRoundStart[peer] ?? 0)) someoneMissedRound = true;
      _progressAtRoundStart[peer] = progress;
    }
    if (!someoneMissedRound) return;
    rotationInterval += const Duration(seconds: 1);
    _log.d('Torrent', 'A reader missed a whole round, interval now ${rotationInterval.inMilliseconds}ms');
    if (autoRotate) _startRotation();
  }

  Future<void> _generateRemainingSegments() async {
    while (!_disposed && session!.currentSegmentIndex < session!.totalSegments) {
      _keyService.generateNextSegment(session!);
      await Future.delayed(Duration.zero);
    }
  }

  void _startRotation() {
    _rotationTimer?.cancel();
    _rotationTimer = Timer.periodic(rotationInterval, (_) => tick());
  }

  void _stopRotation() {
    _rotationTimer?.cancel();
    _rotationTimer = null;
  }

  void _fail(Object e) {
    _log.e('KeyExchange', 'Source exchange failed: $e');
    error = e.toString();
    if (!_result.isCompleted) _result.completeError(e);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopRotation();
    _syncSubscription?.cancel();
    super.dispose();
  }
}
