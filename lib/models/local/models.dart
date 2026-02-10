import 'package:json_annotation/json_annotation.dart';

part 'models.g.dart';


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
