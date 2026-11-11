import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:onetime/models/firestore/fs_message.dart';

import 'compression_service.dart';
import '../models/local/key_interval.dart';
import '../models/local/shared_key.dart';

/// One-time pad with a one-time MAC (Wegman–Carter).
///
/// A message uses [macKeyBytes] + payload length bytes of the shared key:
/// ```
/// key range:   | MAC key (32) | pad (payload length)         |
/// ciphertext:                 | payload XOR pad | tag (16)   |
/// ```
/// The tag is Poly1305 of the ciphertext under the 32 MAC key bytes, which
/// are used for this message only. Poly1305 keyed this way is a
/// Wegman–Carter authenticator: a forgery succeeds with probability below
/// 2^-100 for any attacker, however much computing power it has, so integrity
/// is as unconditional as the pad's secrecy. Without it, flipping a ciphertext
/// bit flips the same plaintext bit (sender id, guessable words) unnoticed.
class CryptoService {
  /// Key bytes consumed by the MAC of each message.
  static const macKeyBytes = 32;

  /// Bytes the tag adds to the ciphertext: the range is longer by [macKeyBytes]
  /// than the stored ciphertext minus the tag.
  static const tagBytes = 16;

  static const _poly1305 = DartPoly1305();

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

  /// Poly1305 of [encrypted] under the first [macKeyBytes] of [keyBytes].
  Uint8List _tag(Uint8List encrypted, Uint8List keyBytes) {
    final mac = _poly1305.calculateMacSync(
      encrypted,
      secretKeyData: SecretKeyData(Uint8List.sublistView(keyBytes, 0, macKeyBytes)),
      nonce: const [],
    );
    return Uint8List.fromList(mac.bytes);
  }

  /// Constant-time comparison.
  static bool _equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
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
    final bytesNeeded = macKeyBytes + payload.length;

    // Find available segment in bytes
    final seg = sharedKey.findAvailableSegmentByBytes(bytesNeeded);
    if (seg == null) {
      throw InsufficientKeyException(
        'Not enough key bytes available. Needed: $bytesNeeded bytes',
      );
    }

    // Extract key bytes
    final keyBytes = sharedKey.extractKeyBytes(seg.startByte, seg.lengthBytes);

    // XOR complete protobuf with OTP key, then authenticate the result
    final encrypted = _xor(payload, Uint8List.sublistView(keyBytes, macKeyBytes));
    final ciphertext = Uint8List(encrypted.length + tagBytes)
      ..setRange(0, encrypted.length, encrypted)
      ..setRange(encrypted.length, encrypted.length + tagBytes, _tag(encrypted, keyBytes));

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

    // Check the tag before using anything: a modified or forged message is
    // dropped without being decrypted
    final ciphertext = encryptedMessage.ciphertext;
    if (ciphertext.length != seg.lengthBytes - macKeyBytes + tagBytes || seg.lengthBytes <= macKeyBytes) {
      throw MessageAuthenticationException('Unexpected length for range ${encryptedMessage.id}');
    }
    final encrypted = Uint8List.sublistView(ciphertext, 0, ciphertext.length - tagBytes);
    if (!_equal(_tag(encrypted, keyBytes), Uint8List.sublistView(ciphertext, encrypted.length))) {
      throw MessageAuthenticationException('Invalid tag for range ${encryptedMessage.id}');
    }

    // XOR to decrypt protobuf
    final decryptedProtoBytes = _xor(encrypted, Uint8List.sublistView(keyBytes, macKeyBytes));

    // Deserialize protobuf
    final proto = decodeEncryptedMessageProto(decryptedProtoBytes);

    // Store decrypted proto in message
    encryptedMessage.setDecryptedMetadata(proto);

    // Return message content
    return proto.contentBytes;
  }
}

/// The message was modified, forged, or not sent by a holder of the key.
class MessageAuthenticationException implements Exception {
  final String message;
  MessageAuthenticationException(this.message);

  @override
  String toString() => 'MessageAuthenticationException: $message';
}

/// Exception thrown when key doesn't have enough available bits
class InsufficientKeyException implements Exception {
  final String message;
  InsufficientKeyException(this.message);

  @override
  String toString() => 'InsufficientKeyException: $message';
}