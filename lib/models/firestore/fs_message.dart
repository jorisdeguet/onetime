import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fixnum/fixnum.dart';

import '../../generated/message.pb.dart';

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

/// Extension on EncryptedMessageProto for convenience methods
extension EncryptedMessageProtoExt on EncryptedMessageProto {
  /// Get creation timestamp as DateTime
  DateTime get createdAt => DateTime.fromMillisecondsSinceEpoch(createdAtMs.toInt());

  /// Encodes to binary protobuf format
  Uint8List toBytes() => Uint8List.fromList(writeToBuffer());

  /// Get content type as enum
  MessageContentType get contentTypeEnum => MessageContentType.values[
    contentType.clamp(0, MessageContentType.values.length - 1)
  ];

  /// Get file name or null if not set
  String? get fileNameOrNull => hasFileName() ? fileName : null;

  /// Get MIME type or null if not set
  String? get mimeTypeOrNull => hasMimeType() ? mimeType : null;

  /// Get content as Uint8List
  Uint8List get contentBytes => Uint8List.fromList(content);
}

/// Helper function to create EncryptedMessageProto with typed parameters
EncryptedMessageProto createEncryptedMessageProto({
  required String senderId,
  required int createdAtMs,
  required bool isCompressed,
  required MessageContentType contentType,
  String? fileName,
  String? mimeType,
  required Uint8List content,
}) {
  return EncryptedMessageProto(
    senderId: senderId,
    createdAtMs: Int64(createdAtMs),
    isCompressed: isCompressed,
    contentType: contentType.index,
    fileName: fileName,
    mimeType: mimeType,
    content: content,
  );
}

/// Helper function to decode EncryptedMessageProto from bytes
EncryptedMessageProto decodeEncryptedMessageProto(Uint8List bytes) {
  return EncryptedMessageProto.fromBuffer(bytes);
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
/// are in the encrypted part (EncryptedMessageProto).
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

  /// Decrypted protobuf message (null if not yet decrypted)
  EncryptedMessageProto? _decryptedProto;

  EncryptedMessage({
    required this.keySegment,
    required this.ciphertext,
    Set<String>? ackSet,
    EncryptedMessageProto? decryptedMetadata,
  }) : ackSet = ackSet ?? {},
       _decryptedProto = decryptedMetadata;

  /// Unique message ID (derived from key segment)
  String get id => '${keySegment.startByte}-${keySegment.startByte + keySegment.lengthBytes}';

  /// Access to decrypted protobuf
  EncryptedMessageProto? get metadata => _decryptedProto;

  /// Sets metadata after decryption
  void setDecryptedMetadata(EncryptedMessageProto proto) {
    _decryptedProto = proto;
  }

  /// Shortcuts to metadata (for compatibility)
  String get senderId => _decryptedProto?.senderId ?? '';
  DateTime get createdAt => _decryptedProto?.createdAt ?? DateTime.now();
  bool get isCompressed => _decryptedProto?.isCompressed ?? false;
  MessageContentType get contentType => _decryptedProto?.contentTypeEnum ?? MessageContentType.text;
  String? get fileName => _decryptedProto?.fileNameOrNull;
  String? get mimeType => _decryptedProto?.mimeTypeOrNull;

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
    final proto = _decryptedProto;
    if (proto != null) {
      return 'EncryptedMessage($id from ${proto.senderId}, ${ciphertext.length} bytes, ${proto.contentTypeEnum.name}${proto.isCompressed ? ', compressed' : ''})';
    }
    return 'EncryptedMessage($id, ${ciphertext.length} bytes, encrypted)';
  }
}
