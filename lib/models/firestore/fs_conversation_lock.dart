import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents a lock on a byte index in a conversation.
/// The lock is identified by the byte index it locks.
class ConversationLock {
  /// ID of the user holding the lock
  final String lockerId;
  /// Lock creation date
  final DateTime createdAt;

  ConversationLock({
    required this.lockerId,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Checks if lock is expired (> 5 minutes)
  bool isExpired() {
    final now = DateTime.now();
    final diff = now.difference(createdAt);
    return diff.inMinutes >= 5;
  }

  /// Serializes for Firestore
  Map<String, dynamic> toFirestore() {
    return {
      'lockerId': lockerId,
      'createdAt': FieldValue.serverTimestamp(),
    };
  }

  /// Deserializes from Firestore
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
