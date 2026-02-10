//
//  Generated code. Do not modify.
//  source: message.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

/// Complete message encrypted with One-Time Pad
/// This data is serialized to protobuf, then encrypted (XOR with OTP key)
/// Final format: protobuf_bytes XOR key_bytes
class EncryptedMessageProto extends $pb.GeneratedMessage {
  factory EncryptedMessageProto({
    $core.String? senderId,
    $fixnum.Int64? createdAtMs,
    $core.bool? isCompressed,
    $core.int? contentType,
    $core.String? fileName,
    $core.String? mimeType,
    $core.List<$core.int>? content,
  }) {
    final $result = create();
    if (senderId != null) {
      $result.senderId = senderId;
    }
    if (createdAtMs != null) {
      $result.createdAtMs = createdAtMs;
    }
    if (isCompressed != null) {
      $result.isCompressed = isCompressed;
    }
    if (contentType != null) {
      $result.contentType = contentType;
    }
    if (fileName != null) {
      $result.fileName = fileName;
    }
    if (mimeType != null) {
      $result.mimeType = mimeType;
    }
    if (content != null) {
      $result.content = content;
    }
    return $result;
  }
  EncryptedMessageProto._() : super();
  factory EncryptedMessageProto.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory EncryptedMessageProto.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'EncryptedMessageProto', package: const $pb.PackageName(_omitMessageNames ? '' : 'onetime'), createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'senderId')
    ..aInt64(2, _omitFieldNames ? '' : 'createdAtMs')
    ..aOB(3, _omitFieldNames ? '' : 'isCompressed')
    ..a<$core.int>(4, _omitFieldNames ? '' : 'contentType', $pb.PbFieldType.O3)
    ..aOS(5, _omitFieldNames ? '' : 'fileName')
    ..aOS(6, _omitFieldNames ? '' : 'mimeType')
    ..a<$core.List<$core.int>>(7, _omitFieldNames ? '' : 'content', $pb.PbFieldType.OY)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  EncryptedMessageProto clone() => EncryptedMessageProto()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  EncryptedMessageProto copyWith(void Function(EncryptedMessageProto) updates) => super.copyWith((message) => updates(message as EncryptedMessageProto)) as EncryptedMessageProto;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static EncryptedMessageProto create() => EncryptedMessageProto._();
  EncryptedMessageProto createEmptyInstance() => create();
  static $pb.PbList<EncryptedMessageProto> createRepeated() => $pb.PbList<EncryptedMessageProto>();
  @$core.pragma('dart2js:noInline')
  static EncryptedMessageProto getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<EncryptedMessageProto>(create);
  static EncryptedMessageProto? _defaultInstance;

  /// Sender ID
  @$pb.TagNumber(1)
  $core.String get senderId => $_getSZ(0);
  @$pb.TagNumber(1)
  set senderId($core.String v) { $_setString(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasSenderId() => $_has(0);
  @$pb.TagNumber(1)
  void clearSenderId() => clearField(1);

  /// Creation timestamp (milliseconds since epoch)
  @$pb.TagNumber(2)
  $fixnum.Int64 get createdAtMs => $_getI64(1);
  @$pb.TagNumber(2)
  set createdAtMs($fixnum.Int64 v) { $_setInt64(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasCreatedAtMs() => $_has(1);
  @$pb.TagNumber(2)
  void clearCreatedAtMs() => clearField(2);

  /// Indicates if content was compressed before encryption
  @$pb.TagNumber(3)
  $core.bool get isCompressed => $_getBF(2);
  @$pb.TagNumber(3)
  set isCompressed($core.bool v) { $_setBool(2, v); }
  @$pb.TagNumber(3)
  $core.bool hasIsCompressed() => $_has(2);
  @$pb.TagNumber(3)
  void clearIsCompressed() => clearField(3);

  /// Content type (0=text, 1=image, 2=file)
  @$pb.TagNumber(4)
  $core.int get contentType => $_getIZ(3);
  @$pb.TagNumber(4)
  set contentType($core.int v) { $_setSignedInt32(3, v); }
  @$pb.TagNumber(4)
  $core.bool hasContentType() => $_has(3);
  @$pb.TagNumber(4)
  void clearContentType() => clearField(4);

  /// File name (optional, for files and images)
  @$pb.TagNumber(5)
  $core.String get fileName => $_getSZ(4);
  @$pb.TagNumber(5)
  set fileName($core.String v) { $_setString(4, v); }
  @$pb.TagNumber(5)
  $core.bool hasFileName() => $_has(4);
  @$pb.TagNumber(5)
  void clearFileName() => clearField(5);

  /// MIME type of the file (optional)
  @$pb.TagNumber(6)
  $core.String get mimeType => $_getSZ(5);
  @$pb.TagNumber(6)
  set mimeType($core.String v) { $_setString(5, v); }
  @$pb.TagNumber(6)
  $core.bool hasMimeType() => $_has(5);
  @$pb.TagNumber(6)
  void clearMimeType() => clearField(6);

  /// Message content (UTF-8 text or binary)
  @$pb.TagNumber(7)
  $core.List<$core.int> get content => $_getN(6);
  @$pb.TagNumber(7)
  set content($core.List<$core.int> v) { $_setBytes(6, v); }
  @$pb.TagNumber(7)
  $core.bool hasContent() => $_has(6);
  @$pb.TagNumber(7)
  void clearContent() => clearField(7);
}


const _omitFieldNames = $core.bool.fromEnvironment('protobuf.omit_field_names');
const _omitMessageNames = $core.bool.fromEnvironment('protobuf.omit_message_names');
