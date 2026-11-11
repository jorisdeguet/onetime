import 'dart:async';
import 'dart:typed_data';

import '../../models/firestore/fs_kex.dart';
import '../app_logger.dart';
import '../test_events.dart';
import 'kex_link.dart';
import 'kex_sync_channel.dart';
import 'kex_wire.dart';

/// [KexSyncChannel] that carries acknowledgements over a local link
/// (Bluetooth) when the phones can reach each other, and over the server
/// ([remote], Firestore) otherwise.
///
/// The session itself is still created and completed on the server; the link
/// only shortens the loop "reader rebuilds a block → source stops showing it"
/// and spares one server write per batch of acknowledgements. Each side merges
/// what it learns from both paths ([mergeKex]), so a reader may switch from
/// one to the other at any time. Key bytes never go through either path.
class HybridKexSyncChannel implements KexSyncChannel, KexDataLink {
  final KexSyncChannel _remote;
  final KexHostLink Function()? _hostFactory;
  final KexClientLink Function()? _clientFactory;
  final String localId;
  final Duration discoveryTimeout;
  final _log = AppLogger();

  // Source side
  KexHostLink? _host;
  final Map<String, int> _received = {};
  Future<void> _hostReady = Future<void>.error(StateError('No Bluetooth exchange started'))..ignore();
  FsKex? _hostState;
  final StreamController<FsKex?> _hostStates = StreamController.broadcast();
  StreamSubscription<FsKex?>? _hostRemoteSubscription;

  // Reader side
  KexClientLink? _client;
  Future<void> _clientConnection = Future<void>.error(StateError('Bluetooth not available'))..ignore();
  final StreamController<Uint8List> _data = StreamController.broadcast();
  StreamSubscription<Uint8List>? _dataSubscription;
  String? _readerSessionId;
  FsKex? _remoteView;
  FsKex? _linkView;
  final StreamController<FsKex?> _readerStates = StreamController.broadcast();
  StreamSubscription<FsKex>? _linkSubscription;
  StreamSubscription<FsKex?>? _readerRemoteSubscription;
  int _linkAcks = 0;
  int _remoteAcks = 0;

  HybridKexSyncChannel({
    required KexSyncChannel remote,
    required this.localId,
    KexHostLink Function()? hostLink,
    KexClientLink Function()? clientLink,
    this.discoveryTimeout = const Duration(seconds: 6),
  })  : _remote = remote,
        _hostFactory = hostLink,
        _clientFactory = clientLink;

  /// True while acknowledgements go over the local link.
  bool get usesLink => (_host != null) || (_client?.isConnected ?? false);

  // ---------------------------------------------------------------------------
  // Source
  // ---------------------------------------------------------------------------

  @override
  Future<FsKex> createSession({
    required String sourceId,
    required List<String> participants,
    required int totalKeyBytes,
    required int totalSegments,
    String? conversationId,
  }) async {
    final session = await _remote.createSession(
      sourceId: sourceId,
      participants: participants,
      totalKeyBytes: totalKeyBytes,
      totalSegments: totalSegments,
      conversationId: conversationId,
    );
    _hostState = session;
    final factory = _hostFactory;
    if (factory != null) {
      final host = factory();
      _hostReady = host.start(session, _onReaderMessage);
      unawaited(_hostReady.then((_) {
        _host = host;
        host.publish(_hostState!);
        _log.i('KeyExchange', 'Local link open for ${session.id}');
        TestEvents.emit('kex_link', {'role': 'source', 'state': 'open'});
      }).catchError((Object e) {
        _log.w('KeyExchange', 'Local link unavailable, acknowledgements go through the server: $e');
        TestEvents.emit('kex_link', {'role': 'source', 'state': 'unavailable', 'reason': '$e'});
      }));
    }
    return session;
  }

  bool _isHosted(String sessionId) => _hostState?.id == sessionId;

  void _onReaderMessage(KexReaderMessage message) {
    final state = _hostState;
    if (state == null || !state.participants.contains(message.participantId)) return;
    switch (message) {
      case KexHello():
        if (message.sessionId != state.id) return;
        _log.i('KeyExchange', 'Reader ${message.participantId} connected over the local link');
      case KexAck():
        _updateHost(mergeKex(state, _copy(state, segmentsByPeer: {message.participantId: message.segments})));
      case KexStop():
        _updateHost(_copy(state, stopRequestedBy: {...state.stopRequestedBy, message.participantId}.toList()));
      case KexReceived():
        _received[message.participantId] = message.packets;
    }
  }

  void _updateHost(FsKex state) {
    _hostState = state;
    _hostStates.add(state);
    _host?.publish(state);
  }

  // ---------------------------------------------------------------------------
  // Shared
  // ---------------------------------------------------------------------------

  @override
  Future<FsKex?> getSession(String sessionId) async {
    if (_isHosted(sessionId)) return _hostState;
    _startReader(sessionId);
    // Whichever answers first: the server, or the source over the link
    final result = Completer<FsKex?>();
    var pending = 1;
    void fail(Object e) {
      if (--pending == 0 && !result.isCompleted) result.completeError(e);
    }

    void succeed(FsKex? s) {
      if (s == null) return fail(StateError('Session not found'));
      if (!result.isCompleted) result.complete(s);
    }

    _remote.getSession(sessionId).then(succeed, onError: fail);
    final client = _client;
    if (client != null) {
      pending++;
      final linked = _linkView != null
          ? Future.value(_linkView)
          : client.states.first.timeout(discoveryTimeout + const Duration(seconds: 4));
      linked.then(succeed, onError: fail);
    }
    return result.future;
  }

  @override
  Stream<FsKex?> watchSession(String sessionId) {
    if (_isHosted(sessionId)) {
      _hostRemoteSubscription ??= _remote.watchSession(sessionId).listen((remote) {
        if (remote == null) return _hostStates.add(null);
        _updateHost(mergeKex(remote, _hostState!));
      }, onError: _hostStates.addError);
      return _hostStates.stream;
    }
    if (_readerSessionId == sessionId) {
      _readerRemoteSubscription ??= _remote.watchSession(sessionId).listen((remote) {
        _remoteView = remote;
        _emitReaderView();
      }, onError: (Object e) => _log.w('KeyExchange', 'Server view of the session failed: $e'));
      return _readerStates.stream;
    }
    return _remote.watchSession(sessionId);
  }

  @override
  Future<void> updateTotalSegments(String sessionId, int totalSegments, int totalKeyBytes) async {
    if (_isHosted(sessionId)) _updateHost(_copy(_hostState!, announcedSegments: totalSegments));
    await _remote.updateTotalSegments(sessionId, totalSegments, totalKeyBytes);
  }

  @override
  Future<void> setConversationId(String sessionId, String conversationId) async {
    if (_isHosted(sessionId)) _updateHost(_copy(_hostState!, conversationId: conversationId));
    await _remote.setConversationId(sessionId, conversationId);
  }

  @override
  Future<void> completeSession(String sessionId) async {
    if (_isHosted(sessionId)) _updateHost(_copy(_hostState!, status: KeyExchangeStatus.completed));
    await _remote.completeSession(sessionId);
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    if (_isHosted(sessionId)) await _stopHost();
    await _remote.deleteSession(sessionId);
  }

  // ---------------------------------------------------------------------------
  // Reader
  // ---------------------------------------------------------------------------

  void _startReader(String sessionId) {
    if (_readerSessionId == sessionId) return;
    _readerSessionId = sessionId;
    final factory = _clientFactory;
    if (factory == null) return;
    final client = factory();
    _client = client;
    _linkSubscription = client.states.listen((state) {
      _linkView = state;
      _emitReaderView();
    });
    _dataSubscription = client.data.listen(_data.add);
    _clientConnection = client.connect(sessionId, localId, timeout: discoveryTimeout);
    unawaited(_clientConnection.then((_) {
      _log.i('KeyExchange', 'Connected to the source over the local link');
      TestEvents.emit('kex_link', {'role': 'reader', 'state': 'open'});
    }).catchError((Object e) {
      _log.w('KeyExchange', 'Local link unavailable, acknowledgements go through the server: $e');
      TestEvents.emit('kex_link', {'role': 'reader', 'state': 'unavailable', 'reason': '$e'});
    }));
  }

  void _emitReaderView() {
    final r = _remoteView, l = _linkView;
    _readerStates.add(r == null ? l : l == null ? r : mergeKex(r, l));
  }

  @override
  Future<void> markSegmentsScanned({
    required String sessionId,
    required String participantId,
    required List<int> segmentIndexes,
  }) async {
    final client = _client;
    if (client != null && client.isConnected) {
      try {
        await client.send(KexAck(participantId, segmentIndexes));
        _linkAcks++;
        return;
      } catch (e) {
        _log.w('KeyExchange', 'Acknowledgement over the local link failed, using the server: $e');
      }
    }
    await _remote.markSegmentsScanned(sessionId: sessionId, participantId: participantId, segmentIndexes: segmentIndexes);
    _remoteAcks++;
  }

  @override
  Future<void> requestStop(String sessionId, String participantId) async {
    final client = _client;
    if (client != null && client.isConnected) {
      try {
        await client.send(KexStop(participantId));
        // Also recorded on the server, in case the link drops right now
        unawaited(_remote.requestStop(sessionId, participantId).catchError((Object e) {
          _log.w('KeyExchange', 'Stop request on the server failed: $e');
        }));
        return;
      } catch (e) {
        _log.w('KeyExchange', 'Stop request over the local link failed, using the server: $e');
      }
    }
    await _remote.requestStop(sessionId, participantId);
  }

  // ---------------------------------------------------------------------------
  // Bluetooth mode: the key itself
  // ---------------------------------------------------------------------------

  @override
  Future<void> get hostReady => _hostReady;

  @override
  int get dataReceivers => _host?.dataReceivers ?? 0;

  @override
  Future<void> sendData(Uint8List message) async {
    final host = _host;
    if (host == null) throw StateError('Bluetooth host not ready');
    await host.sendData(message);
  }

  @override
  int get packetsReceivedBySlowest => _received.isEmpty ? 0 : _received.values.reduce((a, b) => a < b ? a : b);

  bool _reporting = false;
  int? _pendingReport;

  /// Sends the latest count only: reports never queue up behind each other.
  @override
  void reportReceived(int packets) {
    final client = _client;
    if (client == null || !client.isConnected) return;
    if (_reporting) {
      _pendingReport = packets;
      return;
    }
    _reporting = true;
    client.send(KexReceived(localId, packets)).catchError((Object e) {
      _log.d('KeyExchange', 'Progress report failed: $e');
    }).whenComplete(() {
      _reporting = false;
      final next = _pendingReport;
      _pendingReport = null;
      if (next != null) reportReceived(next);
    });
  }

  @override
  Future<void> connectReader(String sessionId) {
    _startReader(sessionId);
    return _clientConnection;
  }

  @override
  Stream<Uint8List> get data => _data.stream;

  /// Closes the local link (the screen calls this when it goes away).
  Future<void> close() async {
    if (_readerSessionId != null) {
      TestEvents.emit('kex_link_acks', {'link': _linkAcks, 'server': _remoteAcks});
    }
    await _linkSubscription?.cancel();
    await _dataSubscription?.cancel();
    await _readerRemoteSubscription?.cancel();
    await _hostRemoteSubscription?.cancel();
    await _client?.close();
    _client = null;
    await _stopHost();
  }

  Future<void> _stopHost() async {
    final host = _host;
    _host = null;
    if (host != null) await host.stop();
  }

  static FsKex _copy(
    FsKex s, {
    Map<String, List<int>>? segmentsByPeer,
    KeyExchangeStatus? status,
    int? announcedSegments,
    List<String>? stopRequestedBy,
    String? conversationId,
  }) =>
      FsKex(
        id: s.id,
        conversationId: conversationId ?? s.conversationId,
        sourceId: s.sourceId,
        segmentsByPeer: segmentsByPeer ?? s.segmentsByPeer,
        status: status ?? s.status,
        announcedSegments: announcedSegments ?? s.announcedSegments,
        stopRequestedBy: stopRequestedBy ?? s.stopRequestedBy,
        startIndex: s.startIndex,
        endIndex: s.endIndex,
      );
}
