import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

/// Type de contenu d'un message
enum MessageContentType {
  text,
  image,
  file,
}

/// Qualité de redimensionnement d'image
enum ImageQuality {
  small(320, 'Petite (~50KB)'),
  medium(800, 'Moyenne (~150KB)'),
  large(1920, 'Grande (~500KB)'),
  original(0, 'Originale');

  final int maxDimension;
  final String label;
  const ImageQuality(this.maxDimension, this.label);
}

/// Représente un message chiffré avec One-Time Pad.
/// 
/// Le message contient les données chiffrées (XOR avec la clé)
/// ainsi que les métadonnées permettant de le déchiffrer.
class EncryptedMessage {
  /// ID unique du message
  final String id;
  
  /// ID de la clé partagée utilisée
  final String keyId;
  
  /// ID de l'expéditeur
  final String senderId;
  
  /// Segment unique de clé utilisé (startByte inclusive, lengthBytes length)
  final ({int startByte, int lengthBytes})? keySegment;

  /// Données chiffrées (XOR du message avec la clé)
  final Uint8List ciphertext;
  
  /// Timestamp de création
  final DateTime createdAt;
  
  /// Liste des participants qui ont lu le message
  List<String> readBy;

  /// Liste des participants qui ont transféré/reçu le message
  List<String> transferredBy;
  
  /// Indique si le message était compressé avant chiffrement
  final bool isCompressed;

  /// Type de contenu
  final MessageContentType contentType;

  /// Nom du fichier (pour les fichiers et images)
  final String? fileName;

  /// Type MIME du fichier
  final String? mimeType;

  EncryptedMessage({
    required this.id,
    required this.keyId,
    required this.senderId,
    this.keySegment,
    required this.ciphertext,
    DateTime? createdAt,
    List<String>? readBy,
    List<String>? transferredBy,
    this.isCompressed = false,
    this.contentType = MessageContentType.text,
    this.fileName,
    this.mimeType,
  }) : createdAt = createdAt ?? DateTime.now(),
       // Le sender est automatiquement inclus dans les listes
       readBy = readBy ?? [senderId],
       transferredBy = transferredBy ?? [senderId];

  /// Indique si le message est chiffré (a des segments de clé)
  bool get isEncrypted => keySegment != null;

  /// Index du premier octet utilisé (du premier segment), ou 0 si non chiffré
  int get startByte => keySegment != null ? keySegment!.startByte : 0;

  /// Index du dernier octet utilisé (exclusif), ou 0 si non chiffré
  int get endByte => keySegment != null ? keySegment!.startByte + keySegment!.lengthBytes : 0;

  /// Longueur totale des segments utilisés en octets
  int get totalBytesUsed {
    if (keySegment == null) return 0;
    return keySegment!.lengthBytes;
  }

  /// Vérifie si tous les participants ont transféré le message
  bool allTransferred(List<String> participants) {
    return participants.every((p) => transferredBy.contains(p));
  }

  /// Vérifie si tous les participants ont lu le message
  bool allRead(List<String> participants) {
    return participants.every((p) => readBy.contains(p));
  }

  /// Marque le message comme transféré par un participant
  void markTransferredBy(String participantId) {
    if (!transferredBy.contains(participantId)) {
      transferredBy.add(participantId);
    }
  }

  /// Marque le message comme lu par un participant
  void markReadBy(String participantId) {
    if (!readBy.contains(participantId)) {
      readBy.add(participantId);
    }
  }

  /// Sérialise le message pour envoi sur Firebase
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'keyId': keyId,
      'senderId': senderId,
      // store single key segment as object for simplicity
      'keySegment': keySegment != null ? {'startByte': keySegment!.startByte, 'lengthBytes': keySegment!.lengthBytes} : null,
      'ciphertext': base64Encode(ciphertext),
      // Use server timestamp so Firestore sets an authoritative creation time
      'createdAt': FieldValue.serverTimestamp(),
      'readBy': readBy,
      'transferredBy': transferredBy,
      'isCompressed': isCompressed,
      'contentType': contentType.name,
      'fileName': fileName,
      'mimeType': mimeType,
    };
  }

  /// Désérialise un message depuis Firebase
  factory EncryptedMessage.fromJson(Map<String, dynamic> json) {
    // Support new single-segment format. If absent, leave as null.
    final segRaw = json['keySegment'] as Map<String, dynamic>?;
    ({int startByte, int lengthBytes})? parsedSeg;
    if (segRaw != null) {
      parsedSeg = (startByte: segRaw['startByte'] as int, lengthBytes: segRaw['lengthBytes'] as int);
    } else {
      parsedSeg = null;
    }

    // createdAt is expected to be a Firestore Timestamp
    final createdRaw = json['createdAt'];
    DateTime created;
    if (createdRaw is Timestamp) {
      created = createdRaw.toDate();
    } else if (createdRaw is Map && createdRaw['_seconds'] != null) {
      // sometimes during local emulation/serialization it may be a map
      created = Timestamp(createdRaw['_seconds'] as int, (createdRaw['_nanoseconds'] as int?) ?? 0).toDate();
    } else {
      // As a fallback (should not happen in production since DB is reset), use now
      created = DateTime.now();
    }

    return EncryptedMessage(
      id: json['id'] as String,
      keyId: json['keyId'] as String,
      senderId: json['senderId'] as String,
      keySegment: parsedSeg,
      ciphertext: base64Decode(json['ciphertext'] as String),
      createdAt: created,
      readBy: List<String>.from(json['readBy'] as List? ?? [json['senderId']]),
      transferredBy: List<String>.from(json['transferredBy'] as List? ?? [json['senderId']]),
      isCompressed: json['isCompressed'] as bool? ?? false,
      contentType: MessageContentType.values.firstWhere(
        (t) => t.name == json['contentType'],
        orElse: () => MessageContentType.text,
      ),
      fileName: json['fileName'] as String?,
      mimeType: json['mimeType'] as String?,
    );
   }

   @override
   String toString() => 'EncryptedMessage($id from $senderId, ${ciphertext.length} bytes, ${contentType.name}${isCompressed ? ', compressed' : ''})';
 }
