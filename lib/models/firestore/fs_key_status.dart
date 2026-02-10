import 'package:json_annotation/json_annotation.dart';

part 'fs_key_status.g.dart';

/// Firestore model for key status debug info.
/// Stores the current key usage state for a user in a conversation.
@JsonSerializable()
class FsKeyStatus {
  final int startByte;

  final int endByte;

  FsKeyStatus({
    required this.startByte,
    required this.endByte,
  });

  /// Number of available bytes
  int get availableBytes => endByte - startByte;

  factory FsKeyStatus.fromJson(Map<String, dynamic> json) =>
      _$FsKeyStatusFromJson(json);

  Map<String, dynamic> toJson() => _$FsKeyStatusToJson(this);

  /// Converts to Firestore format
  Map<String, dynamic> toFirestore() => toJson();

  /// Creates from Firestore data
  factory FsKeyStatus.fromFirestore(Map<String, dynamic> data) =>
      FsKeyStatus.fromJson(data);
}

