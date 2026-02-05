import 'package:cloud_firestore/cloud_firestore.dart';

/// Représente un lock sur un index d'octet dans une conversation.
/// Le lock est identifié par l'index d'octet qu'il verrouille.
class ConversationLock {

  /// ID de l'utilisateur qui détient le lock
  final String lockerId;

  /// Date de création du lock
  final DateTime createdAt;

  ConversationLock({
    required this.lockerId,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Vérifie si le lock est expiré (> 5 minutes)
  bool isExpired() {
    final now = DateTime.now();
    final diff = now.difference(createdAt);
    return diff.inMinutes >= 5;
  }

  /// Sérialise pour Firestore
   Map<String, dynamic> toFirestore() {
     return {
       'lockerId': lockerId,
       'createdAt': FieldValue.serverTimestamp(),
     };
   }

   /// Désérialise depuis Firestore
   factory ConversationLock.fromFirestore(Map<String, dynamic> data) {
    final createdRaw = data['createdAt'];
    DateTime created;
    if (createdRaw is Timestamp) {
      created = createdRaw.toDate();
    } else {
      created = DateTime.now();
    }
    return ConversationLock(
      lockerId: data['lockerId'] as String,
      createdAt: created,
    );
  }
}
