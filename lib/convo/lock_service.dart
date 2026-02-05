import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:onetime/convo/conversation_lock.dart';
import 'package:onetime/services/app_logger.dart';

/// Exception lancée quand un lock ne peut pas être acquis après plusieurs tentatives
class LockAcquisitionException implements Exception {
  final String message;
  LockAcquisitionException(this.message);

  @override
  String toString() => message;
}

/// Service pour gérer les locks sur les conversations dans Firestore
class LockService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final AppLogger _log = AppLogger();

  /// Durée maximale d'attente pour acquérir un lock (en millisecondes)
  static const List<int> _retryDelaysMs = [1000, 2000, 4000, 10000];

  /// ID du lock global pour la conversation (constant pour toutes les tentatives)
  static const String _globalLockId = 'conversation_lock';

  /// Document du lock global pour une conversation
  DocumentReference<Map<String, dynamic>> _lockRef(String conversationId) =>
      _firestore.collection('conversations')
          .doc(conversationId)
          .collection('locks')
          .doc(_globalLockId);

  /// Acquiert un lock global sur la conversation
  ///
  /// Stratégie de retry avec délais exponentiels : 1s, 2s, 4s, 10s
  /// Lance une [LockAcquisitionException] si le lock ne peut pas être acquis
  ///
  /// Retourne le byteIndex qui était dans le lock (pour information)
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

        // Lock non acquis, attendre avant de réessayer
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
      'Impossible d\'acquérir le lock après ${_retryDelaysMs.length} tentatives. '
      'Un autre participant est en cours d\'envoi, veuillez patienter.'
    );
  }

  /// Tente d'acquérir le lock global (une seule tentative)
  /// Retourne le lock si acquis, null sinon
  Future<ConversationLock?> _tryAcquireLock({
    required String conversationId,
    required String userId,
  }) async {
    final lockDocRef = _lockRef(conversationId);

    try {
      // Utiliser une transaction pour garantir l'atomicité
      return await _firestore.runTransaction<ConversationLock?>((transaction) async {
        final doc = await transaction.get(lockDocRef);

        if (doc.exists) {
          // Un lock existe déjà
          final existingLock = ConversationLock.fromFirestore(
            doc.data()!,
          );

          // Vérifier si le lock est expiré
          if (existingLock.isExpired()) {
            _log.w('LockService', 'Global lock expired (was held by ${existingLock.lockerId}), stealing it');
            // Le lock est expiré, on peut le prendre
            final newLock = ConversationLock(
              lockerId: userId,
            );
            transaction.set(lockDocRef, newLock.toFirestore());
            return newLock;
          } else {
            // Le lock est toujours valide
            _log.d('LockService', 'Global lock held by ${existingLock.lockerId}');
            return null;
          }
        } else {
          // Aucun lock n'existe, on peut le créer
          final newLock = ConversationLock(
            lockerId: userId,
          );
          transaction.set(lockDocRef, newLock.toFirestore());
          return newLock;
        }
      });
    } catch (e) {
      _log.e('LockService', 'Error in transaction: $e');
      rethrow;
    }
  }

  /// Libère le lock global
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

          // Vérifier que c'est bien nous qui détenons le lock
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

  /// Nettoie le lock expiré d'une conversation
  /// Utile pour le nettoyage périodique
  Future<void> cleanupExpiredLocks(String conversationId) async {
    _log.d('LockService', 'Cleaning up expired lock for conversation $conversationId');

    try {
      final lockDocRef = _lockRef(conversationId);
      final doc = await lockDocRef.get();

      if (doc.exists) {
        final lock = ConversationLock.fromFirestore(
          doc.data()!,
        );

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
