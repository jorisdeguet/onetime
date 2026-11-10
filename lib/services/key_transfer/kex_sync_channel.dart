import '../../models/firestore/fs_kex.dart';

/// Control channel of a key exchange: who scanned which segment, how many
/// segments are kept, and when the exchange is over. Key bytes never go
/// through this channel.
///
/// Implemented over Firestore today ([KeyExchangeSyncService]); a Bluetooth
/// implementation can replace it without touching the controllers.
abstract class KexSyncChannel {
  Future<FsKex> createSession({
    required String sourceId,
    required List<String> participants,
    required int totalKeyBytes,
    required int totalSegments,
    String? conversationId,
  });
  Future<FsKex?> getSession(String sessionId);
  Stream<FsKex?> watchSession(String sessionId);
  Future<void> markSegmentScanned({
    required String sessionId,
    required String participantId,
    required int segmentIndex,
  });
  /// Announces how many segments every participant keeps (early termination).
  Future<void> updateTotalSegments(String sessionId, int totalSegments, int totalKeyBytes);
  Future<void> setConversationId(String sessionId, String conversationId);
  Future<void> completeSession(String sessionId);
  Future<void> deleteSession(String sessionId);
}
