import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/firestore/fs_kex.dart';
import '../../models/local/shared_key.dart';
import '../app_logger.dart';
import '../key_service.dart';
import 'fountain.dart';
import 'kex_bluetooth_transfer.dart';
import 'kex_link.dart';
import 'kex_sync_channel.dart';

/// Key bytes produced by an exchange, identical on every participant.
class KexResult {
  final SharedKey newKey;
  final FsKex syncState;

  KexResult({required this.newKey, required this.syncState});
}

/// Source side of a key exchange, without any UI.
///
/// Generates the key segments and streams them as fountain packets
/// ([FountainEncoder]): every segment once, then repair packets for the
/// blocks some reader still misses. Readers acknowledge whole blocks on the
/// [KexSyncChannel]; the exchange ends once every reader holds every segment.
/// The screen renders [currentPayload] (as a QR code) and listens for [result].
///
/// In Bluetooth mode the same packets go over [KexDataLink], encrypted with
/// a one-time secret, and the only QR code is the [KexInvite] carrying it.
class KexSourceController extends ChangeNotifier {
  final KexSyncChannel _sync;
  final KexDataLink? _data;
  final KeyService _keyService;
  final FountainCodec _codec = const FountainCodec();
  final String localId;
  final String conversationId;
  final List<String> peerIds;
  final bool autoRotate;
  final _log = AppLogger();

  KexSessionSource? session;
  FsKex? syncState;
  FountainPacket? currentPacket;

  /// Continuous mode: streams up to the requested size until someone stops;
  /// the key is then the prefix every reader holds.
  bool continuous = false;
  Duration rotationInterval;
  FountainEncoder? _encoder;
  String? error;

  /// Bluetooth mode: the code readers scan, and the cipher of the stream.
  KexInvite? invite;
  KexPacketCipher? _cipher;

  /// Bluetooth was asked for but is unavailable: the exchange uses QR codes.
  bool bluetoothUnavailable = false;
  int packetsSent = 0;
  DateTime? _rateSince;

  bool get usesBluetooth => _cipher != null;

  final Completer<KexResult> _result = Completer<KexResult>();
  StreamSubscription<FsKex?>? _syncSubscription;
  Timer? _rotationTimer;
  bool _terminating = false;
  bool _disposed = false;

  KexSourceController({
    required KexSyncChannel sync,
    KexDataLink? data,
    required KeyService keyService,
    required this.localId,
    required this.conversationId,
    required this.peerIds,
    this.rotationInterval = const Duration(milliseconds: 100),
    this.autoRotate = true,
  })  : _sync = sync,
        _data = data,
        _keyService = keyService;

  Future<KexResult> get result => _result.future;

  String? get currentPayload {
    if (usesBluetooth) return invite!.encode();
    return currentPacket == null ? null : _codec.encode(currentPacket!);
  }

  /// Short description of the packet on display, e.g. "12/32" or "bloc 2 +5".
  String get currentLabel {
    final p = currentPacket;
    if (p == null) return '';
    final k = _encoder!.layout.symbolsInBlock(p.block);
    if (p.index < k) return '${p.block * p.blockSymbols + p.index + 1}/${p.symbolCount}';
    return 'bloc ${p.block + 1} +${p.index - k + 1}';
  }

  int get totalSegments => session?.totalSegments ?? 0;

  /// Segments generated ahead of the display (a continuous exchange may stop
  /// long before its maximum size).
  static const _generationLead = 256;

  /// Bluetooth packets in flight (sent, not reported received yet).
  static const _bluetoothWindow = 16;

  /// Creates the shared session, shows the first segment and starts rotating.
  /// With [continuous], [totalBytes] is only a maximum: the exchange goes on
  /// until the source calls [terminate] or a reader asks to stop.
  /// With [bluetooth], the key goes over Bluetooth when it is available.
  Future<void> start(
    int totalBytes, {
    List<KeySegmentQrData>? preGeneratedSegments,
    bool continuous = false,
    bool bluetooth = false,
  }) async {
    this.continuous = continuous;
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
    if (bluetooth) await _openBluetooth(totalBytes);
    _encoder = FountainEncoder(
      layout: FountainLayout(totalBytes: totalBytes, symbolSize: KeyService.segmentSizeBytes),
      sessionId: syncState!.id,
      symbolAt: session!.getSegmentData,
      ackLagBlocks: usesBluetooth ? 4 : 0,
    );
    _syncSubscription = _sync.watchSession(syncState!.id).listen(onSyncUpdate);
    if (session!.getSegmentData(0) == null) _keyService.generateNextSegment(session!);
    if (usesBluetooth) {
      unawaited(_streamOverBluetooth());
    } else {
      tick();
      if (autoRotate) _startRotation();
    }
    unawaited(_generateRemainingSegments());
  }

  Future<void> _openBluetooth(int totalBytes) async {
    final data = _data;
    try {
      if (data == null) throw StateError('No Bluetooth link');
      await data.hostReady.timeout(const Duration(seconds: 8));
      invite = KexInvite.generate(sessionId: syncState!.id, totalBytes: totalBytes);
      _cipher = KexPacketCipher(invite!);
    } catch (e) {
      _log.w('KeyExchange', 'Bluetooth unavailable, showing the key as QR codes: $e');
      bluetoothUnavailable = true;
    }
  }

  /// Bluetooth mode: sends packets as fast as the radio takes them, while a
  /// reader is connected.
  Future<void> _streamOverBluetooth() async {
    final data = _data!;
    while (!_disposed && !_terminating) {
      if (data.dataReceivers == 0) {
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }
      // Stays a few packets ahead of the slowest reader: the radio accepts
      // far more than it can send, and a full queue stalls the whole link
      if (packetsSent - data.packetsReceivedBySlowest >= _bluetoothWindow) {
        await Future.delayed(const Duration(milliseconds: 10));
        continue;
      }
      final packet = _encoder!.next(_isBlockDoneByAll);
      if (packet == null) {
        // Next segment not generated yet, or waiting for the last acknowledgements
        await Future.delayed(const Duration(milliseconds: 20));
        continue;
      }
      currentPacket = packet;
      try {
        await data.sendData(await _cipher!.encrypt(_codec.encodeBytes(packet)));
      } catch (e) {
        _log.w('KeyExchange', 'Bluetooth send failed: $e');
        await Future.delayed(const Duration(milliseconds: 200));
      }
      if (++packetsSent % 8 == 0) _notify();
      if (packetsSent % 64 == 0) {
        final now = DateTime.now();
        final ms = now.difference(_rateSince ?? now).inMilliseconds;
        if (ms > 0) _log.i('KeyExchange', 'Bluetooth: ${(64 * 1000 / ms).toStringAsFixed(1)} packets/s');
        _rateSince = now;
      }
    }
  }

  /// Applies a new snapshot of the shared session; ends the exchange when complete.
  void onSyncUpdate(FsKex? state) {
    if (state == null || _disposed) return;
    syncState = state;
    _notify();
    if (_terminating || session == null) return;
    // A stop request waits until there is something to keep
    if (state.stopRequestedBy.isNotEmpty && canTerminate) {
      _log.i('KeyExchange', 'Stop requested by ${state.stopRequestedBy.length} reader(s)');
      unawaited(terminate());
      return;
    }
    for (int i = 0; i < session!.totalSegments; i++) {
      if (!state.allParticipantsScannedSegment(i)) return;
    }
    _log.i('KeyExchange', 'All segments complete - auto terminating');
    unawaited(terminate());
  }

  /// True once every reader holds the first segment: ending the exchange then
  /// keeps a key (the longest prefix everyone holds).
  bool get canTerminate => syncState?.allParticipantsScannedSegment(0) ?? false;

  /// One rotation step: shows the next packet useful to some reader.
  void tick() {
    if (_encoder == null || syncState == null || _terminating) return;
    final packet = _encoder!.next(_isBlockDoneByAll);
    if (packet == null) return; // next segment not generated yet, or all done
    currentPacket = packet;
    _notify();
  }

  bool _isBlockDoneByAll(int block) {
    final layout = _encoder!.layout;
    final first = layout.firstSymbol(block);
    for (int i = first; i < first + layout.symbolsInBlock(block); i++) {
      if (!syncState!.allParticipantsScannedSegment(i)) return false;
    }
    return true;
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

  Future<void> _generateRemainingSegments() async {
    while (!_disposed && !_terminating && session!.currentSegmentIndex < session!.totalSegments) {
      if (session!.currentSegmentIndex - (_encoder?.symbolsShown ?? 0) >= _generationLead) {
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }
      // Each segment waits for its share of camera noise
      if (_keyService.awaitsNoise(KeyService.segmentSizeBytes)) {
        await Future.delayed(const Duration(milliseconds: 50));
        continue;
      }
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
