import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:onetime/models/firestore/fs_conversation_lock.dart';
import 'package:onetime/services/app_logger.dart';

/// Exception thrown when a lock cannot be acquired after several attempts
class LockAcquisitionException implements Exception {
  final String message;
  LockAcquisitionException(this.message);

  @override
  String toString() => message;
}

/// Service to manage conversation locks in Firestore
class LockService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final AppLogger _log = AppLogger();

  /// Maximum wait time to acquire a lock (in milliseconds)
  static const List<int> _retryDelaysMs = [1000, 2000, 4000, 10000];

  /// Global lock ID for conversation (constant for all attempts)
  static const String _globalLockId = 'conversation_lock';

  /// Global lock document for a conversation
  DocumentReference<Map<String, dynamic>> _lockRef(String conversationId) =>
      _firestore.collection('conversations')
          .doc(conversationId)
          .collection('locks')
          .doc(_globalLockId);

  /// Acquires a global lock on the conversation
  ///
  /// Retry strategy with exponential delays: 1s, 2s, 4s, 10s
  /// Throws [LockAcquisitionException] if lock cannot be acquired
  ///
  /// Returns the byteIndex that was in the lock (for information)
  Future<ConversationLock> acquireLock({
    required String conversationId,
    required String userId,
  }) async {
    _log.d('LockService', 'Attempting to acquire GLOBAL lock for conversation $conversationId');

    for (int attempt = 0; attempt < _retryDelaysMs.length; attempt++) {
      try {
        final lock = await _tryAcquireLock(
          conversationId: conversationId,
          userId: userId,
        );

        if (lock != null) {
          _log.i('LockService', 'Global lock acquired for conversation $conversationId (attempt ${attempt + 1})');
          return lock;
        }

        // Lock not acquired, wait before retrying
        if (attempt < _retryDelaysMs.length - 1) {
          final delay = _retryDelaysMs[attempt];
          _log.d('LockService', 'Lock busy, waiting ${delay}ms before retry...');
          await Future.delayed(Duration(milliseconds: delay));
        }
      } catch (e) {
        _log.e('LockService', 'Error during lock acquisition attempt ${attempt + 1}: $e');
        if (attempt == _retryDelaysMs.length - 1) {
          rethrow;
        }
      }
    }

    throw LockAcquisitionException(
      'Could not acquire lock after ${_retryDelaysMs.length} attempts. '
      'Another participant is sending, please wait.'
    );
  }

  /// Attempts to acquire the global lock (single attempt)
  /// Returns the lock if acquired, null otherwise
  Future<ConversationLock?> _tryAcquireLock({
    required String conversationId,
    required String userId,
  }) async {
    final lockDocRef = _lockRef(conversationId);

    try {
      // Use a transaction to guarantee atomicity
      return await _firestore.runTransaction<ConversationLock?>((transaction) async {
        final doc = await transaction.get(lockDocRef);

        if (doc.exists) {
          // A lock already exists
          final existingLock = ConversationLock.fromFirestore(doc.data()!);

          // Check if lock is expired
          if (existingLock.isExpired()) {
            _log.w('LockService', 'Global lock expired (was held by ${existingLock.lockerId}), stealing it');
            // Lock is expired, we can take it
            final newLock = ConversationLock(lockerId: userId);
            transaction.set(lockDocRef, newLock.toFirestore());
            return newLock;
          } else {
            // Lock is still valid
            _log.d('LockService', 'Global lock held by ${existingLock.lockerId}');
            return null;
          }
        } else {
          // No lock exists, we can create it
          final newLock = ConversationLock(lockerId: userId);
          transaction.set(lockDocRef, newLock.toFirestore());
          return newLock;
        }
      });
    } catch (e) {
      _log.e('LockService', 'Error in transaction: $e');
      rethrow;
    }
  }

  /// Releases the global lock
  Future<void> releaseLock({
    required String conversationId,
    required int byteIndex,
    required String userId,
  }) async {
    _log.d('LockService', 'Releasing GLOBAL lock for conversation $conversationId');

    final lockDocRef = _lockRef(conversationId);

    try {
      await _firestore.runTransaction((transaction) async {
        final doc = await transaction.get(lockDocRef);

        if (doc.exists) {
          final lock = ConversationLock.fromFirestore(doc.data()!);

          // Check that we own the lock
          if (lock.lockerId == userId) {
            transaction.delete(lockDocRef);
            _log.i('LockService', 'Global lock released for conversation $conversationId');
          } else {
            _log.w('LockService', 'Cannot release lock: owned by ${lock.lockerId}, not $userId');
          }
        } else {
          _log.w('LockService', 'Lock does not exist, nothing to release');
        }
      });
    } catch (e) {
      _log.e('LockService', 'Error releasing lock: $e');
      rethrow;
    }
  }

  /// Cleans up expired lock for a conversation
  /// Useful for periodic cleanup
  Future<void> cleanupExpiredLocks(String conversationId) async {
    _log.d('LockService', 'Cleaning up expired lock for conversation $conversationId');

    try {
      final lockDocRef = _lockRef(conversationId);
      final doc = await lockDocRef.get();

      if (doc.exists) {
        final lock = ConversationLock.fromFirestore(doc.data()!);

        if (lock.isExpired()) {
          await lockDocRef.delete();
          _log.d('LockService', 'Deleted expired lock (was held by ${lock.lockerId})');
        }
      }

      _log.i('LockService', 'Cleanup completed for conversation $conversationId');
    } catch (e) {
      _log.e('LockService', 'Error during cleanup: $e');
    }
  }
}
