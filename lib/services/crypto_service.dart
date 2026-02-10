import 'dart:convert';
import 'dart:typed_data';

import 'package:onetime/models/firestore/fs_message.dart';

import 'compression_service.dart';
import '../models/local/key_interval.dart';
import '../models/local/shared_key.dart';

class CryptoService {
  /// Compression service
  final CompressionService _compressionService = CompressionService();

  CryptoService();

  /// Encrypts a message with One-Time Pad.
  ///
  /// [plaintext] - The plaintext message
  /// [sharedKey] - The shared key to use
  /// [senderId] - Sender ID (encrypted with metadata)
  ///
  /// Returns the encrypted message and the used interval for update
  ({EncryptedMessage message, KeyInterval usedSegment}) encrypt({
    required String plaintext,
    required SharedKey sharedKey,
    required String senderId,
  }) {
    // Prepare data to encrypt with compression
    final compressed = _compressionService.smartCompress(plaintext);
    return _encryptData(
      dataToEncrypt: compressed.data,
      sharedKey: sharedKey,
      senderId: senderId,
      isCompressed: compressed.isCompressed,
      contentType: MessageContentType.text,
    );
  }

  /// Encrypts binary data (images, files) with One-Time Pad.
  ///
  /// [data] - Binary data to encrypt
  /// [sharedKey] - The shared key to use
  /// [senderId] - Sender ID (encrypted with metadata)
  /// [contentType] - Content type (image or file)
  /// [fileName] - File name
  /// [mimeType] - MIME type of the file
  ///
  /// Returns the encrypted message and the used interval for update
  ({EncryptedMessage message, KeyInterval usedSegment}) encryptBinary({
    required Uint8List data,
    required SharedKey sharedKey,
    required String senderId,
    required MessageContentType contentType,
    String? fileName,
    String? mimeType,
  }) {
    return _encryptData(
      dataToEncrypt: data,
      sharedKey: sharedKey,
      senderId: senderId,
      isCompressed: false,
      contentType: contentType,
      fileName: fileName,
      mimeType: mimeType,
    );
  }

  /// Decrypts a binary message and returns raw data
  /// Also updates decrypted metadata in the message
  Uint8List decryptBinary({
    required EncryptedMessage encryptedMessage,
    required SharedKey sharedKey,
    bool markAsUsed = true,
  }) {
    return _decryptData(
      encryptedMessage: encryptedMessage,
      sharedKey: sharedKey,
      markAsUsed: markAsUsed,
    );
  }

  /// Decrypts a message.
  ///
  /// [encryptedMessage] - The encrypted message
  /// [sharedKey] - The shared key
  /// [markAsUsed] - If true, marks key bytes as used
  String decrypt({
    required EncryptedMessage encryptedMessage,
    required SharedKey sharedKey,
    bool markAsUsed = true,
  }) {
    // Decrypt raw data (this also updates metadata)
    final decryptedData = _decryptData(
      encryptedMessage: encryptedMessage,
      sharedKey: sharedKey,
      markAsUsed: markAsUsed,
    );

    // Return empty if no data
    if (decryptedData.isEmpty) {
      return '';
    }

    // Decompress if necessary (metadata already extracted by _decryptData)
    if (encryptedMessage.isCompressed) {
      return _compressionService.smartDecompress(decryptedData, true);
    } else {
      return utf8.decode(decryptedData);
    }
  }

  /// XOR of two byte arrays
  Uint8List _xor(Uint8List data, Uint8List key) {
    final result = Uint8List(data.length);
    for (int i = 0; i < data.length; i++) {
      result[i] = data[i] ^ key[i];
    }
    return result;
  }

  /// Generic encryption method - factorizes common logic
  ///
  /// Format: EncryptedMessageProto.toBytes() -> XOR with OTP key
  /// Protobuf contains metadata + content, then encrypted as a block
  ({EncryptedMessage message, KeyInterval usedSegment}) _encryptData({
    required Uint8List dataToEncrypt,
    required SharedKey sharedKey,
    required String senderId,
    required bool isCompressed,
    required MessageContentType contentType,
    String? fileName,
    String? mimeType,
  }) {
    // Create protobuf message with metadata + content
    final proto = createEncryptedMessageProto(
      senderId: senderId,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      isCompressed: isCompressed,
      contentType: contentType,
      fileName: fileName,
      mimeType: mimeType,
      content: dataToEncrypt,
    );

    // Serialize to binary protobuf (very compact)
    final payload = proto.toBytes();
    final bytesNeeded = payload.length;

    // Find available segment in bytes
    final seg = sharedKey.findAvailableSegmentByBytes(bytesNeeded);
    if (seg == null) {
      throw InsufficientKeyException(
        'Not enough key bytes available. Needed: $bytesNeeded bytes',
      );
    }

    // Extract key bytes
    final keyBytes = sharedKey.extractKeyBytes(seg.startByte, seg.lengthBytes);

    // XOR complete protobuf with OTP key
    final ciphertext = _xor(payload, keyBytes);

    // Create encrypted message (keep proto for local access)
    final encryptedMessage = EncryptedMessage(
      keySegment: (startByte: seg.startByte, lengthBytes: seg.lengthBytes),
      ciphertext: ciphertext,
      decryptedMetadata: proto, // Keep protobuf locally
    );

    return (message: encryptedMessage, usedSegment: seg);
  }

  /// Generic decryption method - factorizes common logic
  /// Returns raw decrypted data (message content)
  /// Extracts and stores metadata in the message
  Uint8List _decryptData({
    required EncryptedMessage encryptedMessage,
    required SharedKey sharedKey,
    required bool markAsUsed,
  }) {
    // Extract segment
    final seg = encryptedMessage.keySegment;

    // Extract key bytes
    final keyBytes = sharedKey.extractKeyBytes(seg.startByte, seg.lengthBytes);

    // XOR to decrypt protobuf
    final decryptedProtoBytes = _xor(encryptedMessage.ciphertext, keyBytes);

    // Deserialize protobuf
    final proto = decodeEncryptedMessageProto(decryptedProtoBytes);

    // Store decrypted proto in message
    encryptedMessage.setDecryptedMetadata(proto);

    // Return message content
    return proto.contentBytes;
  }
}

/// Exception thrown when key doesn't have enough available bits
class InsufficientKeyException implements Exception {
  final String message;
  InsufficientKeyException(this.message);

  @override
  String toString() => 'InsufficientKeyException: $message';
}