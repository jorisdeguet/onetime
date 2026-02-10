// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

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
