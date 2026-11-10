import 'dart:async';

import 'package:onetime/models/firestore/fs_kex.dart';
import 'package:onetime/services/key_transfer/kex_sync_channel.dart';

/// [KexSyncChannel] kept in memory, shared by the controllers of one test.
/// Every write publishes a fresh copy, like a Firestore snapshot.
class InMemoryKexSyncChannel implements KexSyncChannel {
  final Map<String, FsKex> sessions = {};
  final Map<String, StreamController<FsKex?>> _controllers = {};
  int _nextId = 0;

  FsKex _copy(FsKex s) => FsKex(
        id: s.id,
        conversationId: s.conversationId,
        sourceId: s.sourceId,
        segmentsByPeer: s.segmentsByPeer.map((k, v) => MapEntry(k, List<int>.from(v))),
        status: s.status,
        announcedSegments: s.announcedSegments,
        startIndex: s.startIndex,
        endIndex: s.endIndex,
      );

  StreamController<FsKex?> _controller(String id) =>
      _controllers.putIfAbsent(id, () => StreamController<FsKex?>.broadcast());

  void _publish(String id) => _controller(id).add(sessions[id] == null ? null : _copy(sessions[id]!));

  @override
  Future<FsKex> createSession({
    required String sourceId,
    required List<String> participants,
    required int totalKeyBytes,
    required int totalSegments,
    String? conversationId,
  }) async {
    final id = 'kex_test_${_nextId++}';
    sessions[id] = FsKex.createInitial(
      id: id,
      conversationId: conversationId,
      sourceId: sourceId,
      participants: {...participants, sourceId}.toList()..sort(),
      totalSegments: totalSegments,
    );
    return _copy(sessions[id]!);
  }

  @override
  Future<FsKex?> getSession(String sessionId) async =>
      sessions[sessionId] == null ? null : _copy(sessions[sessionId]!);

  @override
  Stream<FsKex?> watchSession(String sessionId) => _controller(sessionId).stream;

  @override
  Future<void> markSegmentScanned({
    required String sessionId,
    required String participantId,
    required int segmentIndex,
  }) async {
    sessions[sessionId]!.addScannedSegment(participantId: participantId, segmentIndex: segmentIndex);
    _publish(sessionId);
  }

  @override
  Future<void> updateTotalSegments(String sessionId, int totalSegments, int totalKeyBytes) async {
    sessions[sessionId] = FsKex(
      id: sessions[sessionId]!.id,
      conversationId: sessions[sessionId]!.conversationId,
      sourceId: sessions[sessionId]!.sourceId,
      segmentsByPeer: sessions[sessionId]!.segmentsByPeer,
      status: sessions[sessionId]!.status,
      announcedSegments: totalSegments,
    );
    _publish(sessionId);
  }

  @override
  Future<void> setConversationId(String sessionId, String conversationId) async {}

  @override
  Future<void> completeSession(String sessionId) async {
    sessions[sessionId]!.status = KeyExchangeStatus.completed;
    _publish(sessionId);
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    sessions.remove(sessionId);
    _publish(sessionId);
  }
}
