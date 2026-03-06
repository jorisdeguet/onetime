import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/firestore/fs_conversation.dart';
import 'app_logger.dart';
import 'auth_service.dart';
import 'key_exchange_sync_service.dart';

/// Result of a single health check.
class HealthCheckResult {
  final String name;
  final bool passed;
  final String? message;

  const HealthCheckResult({
    required this.name,
    required this.passed,
    this.message,
  });
}

/// Service that runs startup health checks before the main app is shown.
///
/// Currently performs:
/// 1. Cleanup of stale key-exchange (kex) sessions (older than one hour –
///    threshold managed by [KeyExchangeSyncService.cleanupOldSessions]).
/// 2. Cleanup of conversations stuck in the "joining" state for more than
///    [_joiningMaxAge] (one day).
class StartupHealthCheckService {
  static const Duration _joiningMaxAge = Duration(days: 1);

  /// Maximum number of Firestore batch operations before committing.
  /// Firestore limits batches to 500; we use 400 to stay safely under that limit.
  static const int _maxBatchSize = 400;

  final _log = AppLogger();
  final _authService = AuthService();
  final _kexSyncService = KeyExchangeSyncService();

  /// Runs all health checks and returns the list of results.
  ///
  /// This method never throws; individual failures are captured as results
  /// with [HealthCheckResult.passed] set to `false`.
  Future<List<HealthCheckResult>> runAll() async {
    final userId = _authService.currentUserId;
    if (userId == null) {
      _log.d('HealthCheck', 'No user signed in – skipping startup checks');
      return const [];
    }

    final results = await Future.wait([
      _cleanupOldKexSessions(userId),
      _cleanupStaleJoiningConversations(userId),
    ]);

    for (final r in results) {
      if (r.passed) {
        _log.i('HealthCheck', '✓ ${r.name}: ${r.message ?? 'OK'}');
      } else {
        _log.w('HealthCheck', '✗ ${r.name}: ${r.message ?? 'failed'}');
      }
    }

    return results;
  }

  /// Delegates to [KeyExchangeSyncService.cleanupOldSessions] to delete
  /// kex sessions older than one hour.
  Future<HealthCheckResult> _cleanupOldKexSessions(String userId) async {
    try {
      await _kexSyncService.cleanupOldSessions(userId);
      return const HealthCheckResult(
        name: 'kex_session_cleanup',
        passed: true,
        message: 'Old key-exchange sessions cleaned up',
      );
    } catch (e) {
      return HealthCheckResult(
        name: 'kex_session_cleanup',
        passed: false,
        message: 'Error: $e',
      );
    }
  }

  /// Deletes Firestore conversations that are still in the "joining" state
  /// and were created more than [_joiningMaxAge] ago.
  Future<HealthCheckResult> _cleanupStaleJoiningConversations(
      String userId) async {
    try {
      final firestore = FirebaseFirestore.instance;
      final cutoff = DateTime.now().subtract(_joiningMaxAge);

      final snapshot = await firestore
          .collection('conversations')
          .where('peerIds', arrayContains: userId)
          .where('state', isEqualTo: ConversationState.joining.name)
          .where('createdAt', isLessThan: Timestamp.fromDate(cutoff))
          .get();

      if (snapshot.docs.isEmpty) {
        return const HealthCheckResult(
          name: 'stale_joining_conversations',
          passed: true,
          message: 'No stale joining conversations found',
        );
      }

      var batch = firestore.batch();
      int count = 0;

      for (final doc in snapshot.docs) {
        batch.delete(doc.reference);
        count++;
        if (count >= _maxBatchSize) {
          await batch.commit();
          batch = firestore.batch();
          count = 0;
        }
      }

      if (count > 0) {
        await batch.commit();
      }

      _log.i('HealthCheck',
          'Deleted ${snapshot.docs.length} stale joining conversation(s)');

      return HealthCheckResult(
        name: 'stale_joining_conversations',
        passed: true,
        message:
            'Cleaned up ${snapshot.docs.length} stale joining conversation(s)',
      );
    } catch (e) {
      return HealthCheckResult(
        name: 'stale_joining_conversations',
        passed: false,
        message: 'Error: $e',
      );
    }
  }
}
