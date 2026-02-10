import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

/// Message content type
enum MessageContentType {
  text,
  image,
  file,
}

/// Image resize quality
enum ImageQuality {
  small(320, 'Small (~50KB)'),
  medium(800, 'Medium (~150KB)'),
  large(1920, 'Large (~500KB)'),
  original(0, 'Original');

  final int maxDimension;
  final String label;
  const ImageQuality(this.maxDimension, this.label);
}

/// Encrypted message metadata.
/// This data is included in the EncryptedMessageProto protobuf,
/// then everything is encrypted with XOR (One-Time Pad).
///
/// Protobuf encoding is handled by EncryptedMessageProto in metadata_proto.dart
class EncryptedMetadata {
  /// Sender ID
  final String senderId;

  /// Creation timestamp (milliseconds since epoch)
  final int createdAtMs;

  /// Indicates if content was compressed before encryption
  final bool isCompressed;

  /// Content type
  final MessageContentType contentType;

  /// File name (for files and images)
  final String? fileName;

  /// MIME type of the file
  final String? mimeType;

  EncryptedMetadata({
    required this.senderId,
    required this.createdAtMs,
    required this.isCompressed,
    required this.contentType,
    this.fileName,
    this.mimeType,
  });

  DateTime get createdAt => DateTime.fromMillisecondsSinceEpoch(createdAtMs);
}

/// Represents a message encrypted with One-Time Pad.
///
/// Structure on Firestore (publicly visible part):
/// - ciphertext: encrypted data (metadata + content)
/// - ackSet: set of random identifiers for acknowledgments (read/transfer)
///
/// The Firestore document ID is "startByte-endByte" (derived from keySegment).
/// The keyId is implicit because a message belongs to a conversation that has a single key.
///
/// All sensitive metadata (senderId, createdAt, fileName, mimeType, isCompressed)
/// are in the encrypted part (EncryptedMetadata).
class EncryptedMessage {
  /// Unique key segment used (startByte inclusive, lengthBytes length)
  /// Also serves as unique identifier: "startByte-endByte"
  final ({int startByte, int lengthBytes}) keySegment;

  /// Encrypted data (serialized metadata + separator + content XOR key)
  final Uint8List ciphertext;

  /// Set of random identifiers for read/transfer acknowledgments.
  /// Each participant generates a random ID on their first interaction.
  /// This hides WHO read/transferred first (no correlation with senderId).
  /// Format: Set of random strings (e.g., short UUID or hash)
  Set<String> ackSet;

  // === Decrypted fields (filled after decryption) ===

  /// Decrypted metadata (null if not yet decrypted)
  EncryptedMetadata? _decryptedMetadata;

  EncryptedMessage({
    required this.keySegment,
    required this.ciphertext,
    Set<String>? ackSet,
    EncryptedMetadata? decryptedMetadata,
  }) : ackSet = ackSet ?? {},
       _decryptedMetadata = decryptedMetadata;

  /// Unique message ID (derived from key segment)
  String get id => '${keySegment.startByte}-${keySegment.startByte + keySegment.lengthBytes}';

  /// Access to decrypted metadata
  EncryptedMetadata? get metadata => _decryptedMetadata;

  /// Sets metadata after decryption
  void setDecryptedMetadata(EncryptedMetadata metadata) {
    _decryptedMetadata = metadata;
  }

  /// Shortcuts to metadata (for compatibility)
  String get senderId => _decryptedMetadata?.senderId ?? '';
  DateTime get createdAt => _decryptedMetadata?.createdAt ?? DateTime.now();
  bool get isCompressed => _decryptedMetadata?.isCompressed ?? false;
  MessageContentType get contentType => _decryptedMetadata?.contentType ?? MessageContentType.text;
  String? get fileName => _decryptedMetadata?.fileName;
  String? get mimeType => _decryptedMetadata?.mimeType;

  /// Index of first used byte
  int get startByte => keySegment.startByte;

  /// Index of last used byte (exclusive)
  int get endByte => keySegment.startByte + keySegment.lengthBytes;

  /// Total length of used segments in bytes
  int get totalBytesUsed => keySegment.lengthBytes;

  /// Checks if message has been acknowledged by N participants
  bool hasAcks(int count) => ackSet.length >= count;

  /// Adds an anonymous acknowledgment with a random ID
  /// Returns the added ID (to save locally)
  String addAck(String randomAckId) {
    ackSet.add(randomAckId);
    return randomAckId;
  }

  /// Checks if an acknowledgment ID exists
  bool hasAckId(String ackId) => ackSet.contains(ackId);

  /// Serializes the message for sending to Firestore
  /// Uses Blob to store ciphertext in native binary (more efficient than base64)
  /// WARNING: Sensitive metadata are INSIDE the ciphertext, not exposed here
  Map<String, dynamic> toFirestore() {
    return {
      // Uses Blob to store bytes directly (no base64 conversion)
      'ciphertext': Blob(ciphertext),
      'ackSet': ackSet.toList(),
      // Server timestamp for ordering (not real metadata)
      'serverTimestamp': FieldValue.serverTimestamp(),
    };
  }

  /// Deserializes a message from Firestore
  /// Note: keySegment is extracted from document ID
  factory EncryptedMessage.fromFirestore(Map<String, dynamic> data, {String? documentId}) {
    // Parse keySegment from document ID (format: "startByte-endByte")
    ({int startByte, int lengthBytes}) parsedSeg;

    if (documentId != null) {
      final parts = documentId.split('-');
      if (parts.length == 2) {
        final start = int.parse(parts[0]);
        final end = int.parse(parts[1]);
        parsedSeg = (startByte: start, lengthBytes: end - start);
      } else {
        throw FormatException('Invalid document ID format: $documentId');
      }
    } else if (data.containsKey('keySegment')) {
      // Fallback for legacy format
      final segRaw = data['keySegment'] as Map<String, dynamic>;
      parsedSeg = (startByte: segRaw['startByte'] as int, lengthBytes: segRaw['lengthBytes'] as int);
    } else {
      throw FormatException('No keySegment information available');
    }

    // Read ciphertext - supports Blob (new) and base64 String (legacy)
    Uint8List ciphertextBytes;
    final ciphertextRaw = data['ciphertext'];
    if (ciphertextRaw is Blob) {
      ciphertextBytes = ciphertextRaw.bytes;
    } else if (ciphertextRaw is String) {
      // Legacy: base64 encoded string
      ciphertextBytes = base64Decode(ciphertextRaw);
    } else {
      throw FormatException('Invalid ciphertext format');
    }

    return EncryptedMessage(
      keySegment: parsedSeg,
      ciphertext: ciphertextBytes,
      ackSet: Set<String>.from(data['ackSet'] as List? ?? []),
    );
  }

  @override
  String toString() {
    final meta = _decryptedMetadata;
    if (meta != null) {
      return 'EncryptedMessage($id from ${meta.senderId}, ${ciphertext.length} bytes, ${meta.contentType.name}${meta.isCompressed ? ', compressed' : ''})';
    }
    return 'EncryptedMessage($id, ${ciphertext.length} bytes, encrypted)';
  }
}
