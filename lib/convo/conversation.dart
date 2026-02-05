import 'package:cloud_firestore/cloud_firestore.dart';

/// État d'une conversation
enum ConversationState {
  /// En attente que les participants rejoignent
  joining,
  /// Échange de clé en cours
  exchanging,
  /// Prête à utiliser (clé échangée)
  ready,
}

/// Représente une conversation entre plusieurs pairs.
class Conversation {
  /// ID unique de la conversation (= ID de la clé partagée)
  final String id;
  
  /// Liste des IDs des participants
  final List<String> peerIds;
  
  /// État actuel de la conversation
  ConversationState state;

  /// Date de création
  final DateTime createdAt;

  /// Infos de debug sur la clé locale des pairs
  final Map<String, dynamic> keyDebugInfo;
  
  Conversation({
    required this.id,
    required this.peerIds,
    this.state = ConversationState.joining,
    DateTime? createdAt,
    this.keyDebugInfo = const {},
  }) : createdAt = createdAt ?? DateTime.now();

  /// La conversation est-elle prête à utiliser ?
  bool get isReady => state == ConversationState.ready;

  /// L'échange de clé est-il en cours ?
  bool get isExchanging => state == ConversationState.exchanging;

  /// Est-ce que des participants peuvent encore rejoindre ?
  bool get isJoining => state == ConversationState.joining;

  /// Nom à afficher (liste des pairs)
  String get displayName {
    // Utiliser les IDs utilisateur (raccourcis)
    final names = peerIds
        .map((id) => id.length > 8 ? id.substring(0, 8) : id)
        .toList();
    
    if (names.length <= 3) {
      return names.join(', ');
    }
    return '${names.take(2).join(', ')} +${names.length - 2}';
  }

  /// Sérialise pour Firebase
  Map<String, dynamic> toFirestore() {
    return {
      'id': id,
      'peerIds': peerIds,
      'state': state.name,
      'createdAt': FieldValue.serverTimestamp(),
      'keyDebugInfo': keyDebugInfo,
    };
  }

  /// Désérialise depuis Firebase
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

  /// Sérialise pour stockage local
  Map<String, dynamic> toJson() => toFirestore();
  
  /// Désérialise depuis stockage local
  factory Conversation.fromJson(Map<String, dynamic> json) => 
      Conversation.fromFirestore(json);

}

