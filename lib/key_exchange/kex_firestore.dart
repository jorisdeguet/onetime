import 'package:onetime/key_exchange/key_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Modèle représentant une session d'échange de clé dans Firestore.
///
/// Cette session permet de synchroniser l'état entre:
/// - Le participant source qui affiche les QR codes
/// - Les participants qui scannent les QR codes
class KexSessionModel {
  /// ID unique de la session
  final String id;

  /// ID de la conversation associée (si existante)
  final String? conversationId;

  /// ID du participant source (celui qui affiche les QR codes)
  final String sourceId;

  /// contient les indexes des segments scannés par pair
  final Map<String, List<int>> segmentsByPeer;

  /// Start index (segment) de la tentative courante pour créer/étendre la clé
  final int startIndex;

  /// End index (segment, exclusive) de la tentative courante
  final int endIndex;

  /// Status de la session
  KeyExchangeStatus status;
  final DateTime createdAt;
  DateTime updatedAt;

  // ---------------------------------------------------------------------------
  // Constructeurs
  // ---------------------------------------------------------------------------

  /// Constructeur principal — prend explicitement tous les champs.
  /// Utile pour la désérialisation depuis Firestore.
  KexSessionModel({
    required this.id,
    this.conversationId,
    required this.sourceId,
    required this.segmentsByPeer,
    this.status = KeyExchangeStatus.inProgress,
    int? startIndex,
    int? endIndex,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : startIndex = startIndex ?? 0,
        endIndex = endIndex ?? 0,
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Constructeur nommé pour création initiale.
  /// - `participants` doit contenir l'identifiant `sourceId` (si absent, il sera ajouté).
  /// - Le `sourceId` recevra la liste complète des indexes [0..totalSegments-1].
  /// - Les autres participants auront des listes vides (ils n'ont encore scanné rien).
  KexSessionModel.createInitial({
    required this.id,
    this.conversationId,
    required this.sourceId,
    required List<String> participants,
    required int totalSegments,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : segmentsByPeer = Map.fromEntries(
         // s'assurer que la source est incluse
         (participants.contains(sourceId) ? participants : ([sourceId] + participants))
             .map((p) => MapEntry(p, p == sourceId ? List<int>.generate(totalSegments, (i) => i) : <int>[])),
       ),
       // Par défaut la tentative couvre l'ensemble des segments produits par la source
       startIndex = 0,
       endIndex = totalSegments,
       status = KeyExchangeStatus.inProgress,
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  int get totalSegments => segmentsByPeer[sourceId]?.length ?? 0;

  /// Liste stable des participants (clé du map)
  List<String> get participants => segmentsByPeer.keys.toList();


  List<String> get otherParticipants =>
      // renvoyer les clés de segmentsByPeer sauf la source
      segmentsByPeer.keys.where((p) => p != sourceId).toList();

  bool allParticipantsScannedSegment(int segmentIndex) {
    return otherParticipants.every((participantId) =>
        segmentsByPeer[participantId]?.contains(segmentIndex) ?? false);
  }

  bool hasParticipantScannedSegment(String participantId, int segmentIndex) {
    return segmentsByPeer[participantId]?.contains(segmentIndex) ?? false;
  }

  /// Getter calculé: map segmentIndex -> liste de participants qui l'ont scanné
  Map<int, List<String>> get scannedBy {
    final map = <int, List<String>>{};
    segmentsByPeer.forEach((peer, segs) {
      for (final idx in segs) {
        map.putIfAbsent(idx, () => []).add(peer);
      }
    });
    // Optionnel: trier chaque liste pour stabilité
    map.forEach((k, v) => v.sort());
    return map;
  }

  /// Ajouter un scan (mutable helper utilisé pendant une transaction locale)
  void addScannedSegment({required String participantId, required int segmentIndex}) {
    final list = segmentsByPeer.putIfAbsent(participantId, () => <int>[]);
    if (!list.contains(segmentIndex)) {
      list.add(segmentIndex);
      list.sort();
    }
  }

  /// Calcule les updates à envoyer à Firestore après modification des segments
  Map<String, dynamic> computeFirestoreUpdatesForSegments() {
     final normalized = <String, List<int>>{};
     segmentsByPeer.forEach((k, v) {
       final copy = List<int>.from(v)..sort();
       normalized[k] = copy;
     });

     return {
       'segmentsByPeer': normalized.map((k, v) => MapEntry(k.toString(), v)),
       'participants': normalized.keys.toList(),
       // use server timestamp for authoritative update time
       'updatedAt': FieldValue.serverTimestamp(),
       // inclure la tentative courante (start/end) pour que les listeners puissent éviter
       // de sauvegarder deux fois la même clé si plusieurs updates arrivent.
       'startIndex': startIndex,
       'endIndex': endIndex,
     };
   }

  /// Getter pratique: index actuel produit par la source (nombre de segments source)
  int get currentSegmentIndex => totalSegments;

  bool hasScanned(String participantId, int segmentIndex) {
    return hasParticipantScannedSegment(participantId, segmentIndex);
  }

  /// Vérifie si un participant a scanné tous les segments
  bool hasParticipantFinishedScanning(String participantId) {
    // Compare les sets pour s'assurer que les éléments sont les mêmes, pas seulement la longueur
    final sourceList = segmentsByPeer[sourceId] ?? <int>[];
    final peerList = segmentsByPeer[participantId] ?? <int>[];
    if (sourceList.length != peerList.length) return false;
    final sset = Set<int>.from(sourceList);
    final pset = Set<int>.from(peerList);
    return sset.difference(pset).isEmpty;
  }

  /// Obtient le nombre de segments scannés par un participant
  int getParticipantProgress(String participantId) {
    return segmentsByPeer[participantId]?.length ?? 0;
  }

  /// Vérifie si l'échange est terminé
  bool get isComplete =>
      status == KeyExchangeStatus.completed ||
      otherParticipants.every((p) => hasParticipantFinishedScanning(p));

  /// Sérialise pour Firestore en utilisant Timestamp natifs et listes triées
  Map<String, dynamic> toFirestore() {
    // s'assurer que chaque liste est triée et contient des ints
    final segmentsNormalized = <String, List<int>>{};
    segmentsByPeer.forEach((k, v) {
      final copy = List<int>.from(v);
      copy.sort();
      segmentsNormalized[k] = copy;
    });

    return {
      'id': id,
      'conversationId': conversationId,
      'sourceId': sourceId,
      'segmentsByPeer': segmentsNormalized.map((k, v) => MapEntry(k.toString(), v)),
      'participants': participants,
      'status': status.name,
      'totalSegments': segmentsNormalized[sourceId]?.length ?? 0,
      // store total key size in bytes for clarity
      'totalKeyBytes': (segmentsNormalized[sourceId]?.length ?? 0) * KeyService.segmentSizeBytes,
       'startIndex': startIndex,
       'endIndex': endIndex,
       // server timestamps for authoritative times
       'createdAt': FieldValue.serverTimestamp(),
       'updatedAt': FieldValue.serverTimestamp(),
     };
  }

  /// Désérialise depuis Firestore
  factory KexSessionModel.fromFirestore(Map<String, dynamic> data) {
    final segmentsByPeerRaw = data['segmentsByPeer'] as Map<String, dynamic>? ?? {};
    final segmentsByPeer = <String, List<int>>{};
    segmentsByPeerRaw.forEach((key, value) {
      // Assurer que la valeur est une liste d'entiers et triée
      final list = List<int>.from(value as List);
      list.sort();
      segmentsByPeer[key] = list;
    });

    DateTime parseDate(dynamic v) {
      if (v == null) return DateTime.now();
      if (v is DateTime) return v;
      if (v is String) return DateTime.parse(v);
      try {
        // Firestore Timestamp has toDate()
        return (v as dynamic).toDate() as DateTime;
      } catch (_) {
        return DateTime.now();
      }
    }

    final statusStr = data['status'] as String?;

    // Ensure sourceId exists in parsed structure
    final sourceId = data['sourceId'] as String;

    return KexSessionModel(
      id: data['id'] as String,
      conversationId: data['conversationId'] as String?,
      sourceId: sourceId,
      segmentsByPeer: segmentsByPeer,
      status: KeyExchangeStatus.values.firstWhere(
        (s) => s.name == statusStr,
        orElse: () => KeyExchangeStatus.inProgress,
      ),
      startIndex: data['startIndex'] as int? ?? 0,
      endIndex: data['endIndex'] as int? ?? 0,
      createdAt: parseDate(data['createdAt']),
      updatedAt: parseDate(data['updatedAt']),
    );
  }

  bool hasScannedLegacy(String participantId, int segmentIndex) {
    return segmentsByPeer[participantId]?.contains(segmentIndex) ?? false;
  }

  /// Convenience factory: construct a model representing a source session.
  /// This is a thin wrapper around the main constructor and kept for clarity
  /// when creating a session originating from the source device.
  factory KexSessionModel.fromSource({
    required String id,
    String? conversationId,
    required String sourceId,
    required Map<String, List<int>> segmentsByPeer,
    KeyExchangeStatus status = KeyExchangeStatus.inProgress,
    int? startIndex,
    int? endIndex,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return KexSessionModel(
      id: id,
      conversationId: conversationId,
      sourceId: sourceId,
      segmentsByPeer: segmentsByPeer,
      status: status,
      startIndex: startIndex,
      endIndex: endIndex,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  /// Convenience factory: construct a model representing a reader session.
  /// This is a thin wrapper around the main constructor and clarifies intent
  /// when building a model from a reader-side state.
  factory KexSessionModel.fromReader({
    required String id,
    String? conversationId,
    required String sourceId,
    required Map<String, List<int>> segmentsByPeer,
    KeyExchangeStatus status = KeyExchangeStatus.inProgress,
    int? startIndex,
    int? endIndex,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return KexSessionModel(
      id: id,
      conversationId: conversationId,
      sourceId: sourceId,
      segmentsByPeer: segmentsByPeer,
      status: status,
      startIndex: startIndex,
      endIndex: endIndex,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

/// Status d'une session d'échange de clé
enum KeyExchangeStatus {
  /// En attente de participants
  waiting,

  /// Échange en cours
  inProgress,

  /// Échange terminé avec succès
  completed,

  /// Échange annulé
  cancelled,
}
