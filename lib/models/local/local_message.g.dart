// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_message.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

LocalMessage _$LocalMessageFromJson(Map<String, dynamic> json) => LocalMessage(
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
  existsInCloud: json['existsInCloud'] as bool? ?? true,
  hasCloudContent: json['hasCloudContent'] as bool? ?? true,
  allRead: json['allRead'] as bool? ?? false,
  myTransferAckId: json['myTransferAckId'] as String?,
  myReadAckId: json['myReadAckId'] as String?,
);

Map<String, dynamic> _$LocalMessageToJson(
  LocalMessage instance,
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
  'existsInCloud': instance.existsInCloud,
  'hasCloudContent': instance.hasCloudContent,
  'allRead': instance.allRead,
  'myTransferAckId': instance.myTransferAckId,
  'myReadAckId': instance.myReadAckId,
};
