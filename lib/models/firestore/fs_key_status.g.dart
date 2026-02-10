// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'fs_key_status.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

FsKeyStatus _$FsKeyStatusFromJson(Map<String, dynamic> json) => FsKeyStatus(
  startByte: (json['startByte'] as num).toInt(),
  endByte: (json['endByte'] as num).toInt(),
);

Map<String, dynamic> _$FsKeyStatusToJson(FsKeyStatus instance) =>
    <String, dynamic>{
      'startByte': instance.startByte,
      'endByte': instance.endByte,
    };
