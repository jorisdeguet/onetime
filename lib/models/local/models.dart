import 'dart:convert';
import 'dart:typed_data';

import 'package:json_annotation/json_annotation.dart';

import '../firestore/fs_message.dart';

part 'models.g.dart';

/// Converter for Uint8List <-> Base64 String
class Uint8ListConverter implements JsonConverter<Uint8List?, String?> {
  const Uint8ListConverter();

  @override
  Uint8List? fromJson(String? json) {
    if (json == null) return null;
    return base64Decode(json);
  }

  @override
  String? toJson(Uint8List? object) {
    if (object == null) return null;
    return base64Encode(object);
  }
}

/// Converter for non-nullable Uint8List
class Uint8ListRequiredConverter implements JsonConverter<Uint8List, String> {
  const Uint8ListRequiredConverter();

  @override
  Uint8List fromJson(String json) => base64Decode(json);

  @override
  String toJson(Uint8List object) => base64Encode(object);
}

/// Converter for MessageContentType
class MessageContentTypeConverter implements JsonConverter<MessageContentType, String> {
  const MessageContentTypeConverter();

  @override
  MessageContentType fromJson(String json) {
    return MessageContentType.values.firstWhere(
      (t) => t.name == json,
      orElse: () => MessageContentType.text,
    );
  }

  @override
  String toJson(MessageContentType object) => object.name;
}

/// Represents a decrypted message stored locally
@JsonSerializable()
class LocalMessage {  // TODO rename LocalMessage
  final String id;
  final String senderId;
  final DateTime createdAt;
  @MessageContentTypeConverter()
  final MessageContentType contentType;
  // For text messages
  final String? textContent;
  // For binary messages (image/file)
  @Uint8ListConverter()
  final Uint8List? binaryContent;
  final String? fileName;
  final String? mimeType;
  final bool isCompressed;
  // Metadata related to key segment used for this message
  final int? keySegmentStart;
  final int? keySegmentEnd;

  // Cloud status - updated by MessageService
  // true if the message still exists in Firestore
  final bool existsInCloud;
  // true if the ciphertext is still present (not yet transferred by all)
  final bool hasCloudContent;
  // true if all participants have read (all R acks received)
  final bool allRead;

  LocalMessage({
    required this.id,
    required this.senderId,
    required this.createdAt,
    required this.contentType,
    this.textContent,
    this.binaryContent,
    this.fileName,
    this.mimeType,
    this.isCompressed = false,
    this.keySegmentStart,
    this.keySegmentEnd,
    this.existsInCloud = true,
    this.hasCloudContent = true,
    this.allRead = false,
  });

  /// Creates a copy with updated cloud status
  LocalMessage copyWith({
    bool? existsInCloud,
    bool? hasCloudContent,
    bool? allRead,
  }) {
    return LocalMessage(
      id: id,
      senderId: senderId,
      createdAt: createdAt,
      contentType: contentType,
      textContent: textContent,
      binaryContent: binaryContent,
      fileName: fileName,
      mimeType: mimeType,
      isCompressed: isCompressed,
      keySegmentStart: keySegmentStart,
      keySegmentEnd: keySegmentEnd,
      existsInCloud: existsInCloud ?? this.existsInCloud,
      hasCloudContent: hasCloudContent ?? this.hasCloudContent,
      allRead: allRead ?? this.allRead,
    );
  }

  factory LocalMessage.fromJson(Map<String, dynamic> json) =>
      _$DecryptedMessageDataFromJson(json);

  Map<String, dynamic> toJson() => _$DecryptedMessageDataToJson(this);
}

/// Key metadata stored locally
@JsonSerializable()
class KeyMetadata {
  final String id;
  final List<String> peerIds;
  final int nextAvailableByte;
  final DateTime createdAt;
  final Map<String, dynamic>? history;

  KeyMetadata({
    required this.id,
    required this.peerIds,
    required this.nextAvailableByte,
    required this.createdAt,
    this.history,
  });

  factory KeyMetadata.fromJson(Map<String, dynamic> json) =>
      _$KeyMetadataFromJson(json);

  Map<String, dynamic> toJson() => _$KeyMetadataToJson(this);
}

/// Key segment
@JsonSerializable()
class KeySegmentData {
  final int startByte;
  final int lengthBytes;

  KeySegmentData({
    required this.startByte,
    required this.lengthBytes,
  });

  factory KeySegmentData.fromJson(Map<String, dynamic> json) =>
      _$KeySegmentDataFromJson(json);

  Map<String, dynamic> toJson() => _$KeySegmentDataToJson(this);

  int get endByte => startByte + lengthBytes;
}
