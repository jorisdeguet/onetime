// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

DecryptedMessageData _$DecryptedMessageDataFromJson(
  Map<String, dynamic> json,
) => DecryptedMessageData(
  id: json['id'] as String,
  senderId: json['senderId'] as String,
  createdAt: DateTime.parse(json['createdAt'] as String),
  contentType: const MessageContentTypeConverter().fromJson(
    json['contentType'] as String,
  ),
  textContent: json['textContent'] as String?,
  binaryContent: const Uint8ListConverter().fromJson(
    json['binaryContent'] as String?,
  ),
  fileName: json['fileName'] as String?,
  mimeType: json['mimeType'] as String?,
  isCompressed: json['isCompressed'] as bool? ?? false,
  keySegmentStart: (json['keySegmentStart'] as num?)?.toInt(),
  keySegmentEnd: (json['keySegmentEnd'] as num?)?.toInt(),
);

Map<String, dynamic> _$DecryptedMessageDataToJson(
  DecryptedMessageData instance,
) => <String, dynamic>{
  'id': instance.id,
  'senderId': instance.senderId,
  'createdAt': instance.createdAt.toIso8601String(),
  'contentType': const MessageContentTypeConverter().toJson(
    instance.contentType,
  ),
  'textContent': instance.textContent,
  'binaryContent': const Uint8ListConverter().toJson(instance.binaryContent),
  'fileName': instance.fileName,
  'mimeType': instance.mimeType,
  'isCompressed': instance.isCompressed,
  'keySegmentStart': instance.keySegmentStart,
  'keySegmentEnd': instance.keySegmentEnd,
};

KeyMetadata _$KeyMetadataFromJson(Map<String, dynamic> json) => KeyMetadata(
  id: json['id'] as String,
  peerIds: (json['peerIds'] as List<dynamic>).map((e) => e as String).toList(),
  nextAvailableByte: (json['nextAvailableByte'] as num).toInt(),
  createdAt: DateTime.parse(json['createdAt'] as String),
  history: json['history'] as Map<String, dynamic>?,
);

Map<String, dynamic> _$KeyMetadataToJson(KeyMetadata instance) =>
    <String, dynamic>{
      'id': instance.id,
      'peerIds': instance.peerIds,
      'nextAvailableByte': instance.nextAvailableByte,
      'createdAt': instance.createdAt.toIso8601String(),
      'history': instance.history,
    };

KeySegmentData _$KeySegmentDataFromJson(Map<String, dynamic> json) =>
    KeySegmentData(
      startByte: (json['startByte'] as num).toInt(),
      lengthBytes: (json['lengthBytes'] as num).toInt(),
    );

Map<String, dynamic> _$KeySegmentDataToJson(KeySegmentData instance) =>
    <String, dynamic>{
      'startByte': instance.startByte,
      'lengthBytes': instance.lengthBytes,
    };
