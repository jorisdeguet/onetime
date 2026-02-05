import '../key_exchange/key_interval.dart';

/// Représente une demande de lock sur un segment de clé.
/// Utilisé pour la synchronisation transactionnelle avant envoi.
class KeySegmentLock {
  /// ID unique du lock
  final String lockId;
  
  /// Intervalle sur lequel le lock est demandé
  final KeyInterval interval;

  /// Timestamp d'expiration du lock
  final DateTime expiresAt;
  
  /// Statut du lock
  final KeySegmentLockStatus status;

  KeySegmentLock({
    required this.lockId,
    required this.interval,
    required this.expiresAt,
    this.status = KeySegmentLockStatus.pending,
  });

  /// Vérifie si le lock est expiré
  bool get isExpired => DateTime.now().isAfter(expiresAt);

}

/// Statut d'un lock sur un segment de clé
enum KeySegmentLockStatus {
  /// Lock en attente de confirmation
  pending,
  
  /// Lock acquis avec succès
  acquired,
  
  /// Lock refusé (segment déjà utilisé ou locké)
  denied,
  
  /// Lock libéré
  released,
  
  /// Lock expiré
  expired,
}
