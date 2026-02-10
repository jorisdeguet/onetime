import 'package:cloud_firestore/cloud_firestore.dart';

/// Conversation state
enum ConversationState {
  /// Waiting for participants to join
  joining,
  /// Key exchange in progress
  exchanging,
  /// Ready to use (key exchanged)
  ready,
}

/// Represents a conversation between multiple peers.
class Conversation {
  /// Unique conversation ID (= shared key ID)
  final String id;

  /// List of participant IDs
  final List<String> peerIds;

  /// Current conversation state
  ConversationState state;

  /// Creation date
  final DateTime createdAt;

  /// Debug info about local peer key
  final Map<String, dynamic> keyDebugInfo;

  Conversation({
    required this.id,
    required this.peerIds,
    this.state = ConversationState.joining,
    DateTime? createdAt,
    this.keyDebugInfo = const {},
  }) : createdAt = createdAt ?? DateTime.now();

  /// Is the conversation ready to use?
  bool get isReady => state == ConversationState.ready;

  /// Is key exchange in progress?
  bool get isExchanging => state == ConversationState.exchanging;

  /// Can participants still join?
  bool get isJoining => state == ConversationState.joining;

  /// Display name (peer list)
  String get displayName {
    // Use user IDs (shortened)
    final names = peerIds
        .map((id) => id.length > 8 ? id.substring(0, 8) : id)
        .toList();

    if (names.length <= 3) {
      return names.join(', ');
    }
    return '${names.take(2).join(', ')} +${names.length - 2}';
  }

  /// Serializes for Firebase
  Map<String, dynamic> toFirestore() {
    return {
      'id': id,
      'peerIds': peerIds,
      'state': state.name,
      'createdAt': FieldValue.serverTimestamp(),
      'keyDebugInfo': keyDebugInfo,
    };
  }

  /// Deserializes from Firebase
  factory Conversation.fromFirestore(Map<String, dynamic> data) {
    // createdAt is expected to be a Firestore Timestamp
    final createdRaw = data['createdAt'];
    DateTime created;
    if (createdRaw is Timestamp) {
      created = createdRaw.toDate();
    } else {
      created = DateTime.now();
    }

    return Conversation(
      id: data['id'] as String,
      peerIds: List<String>.from(data['peerIds'] as List),
      state: ConversationState.values.firstWhere(
        (s) => s.name == data['state'],
        orElse: () => ConversationState.joining,
      ),
      createdAt: created,
      keyDebugInfo: data['keyDebugInfo'] as Map<String, dynamic>? ?? {},
    );
  }

  /// Serializes for local storage
  Map<String, dynamic> toJson() => toFirestore();

  /// Deserializes from local storage
  factory Conversation.fromJson(Map<String, dynamic> json) =>
      Conversation.fromFirestore(json);
}
