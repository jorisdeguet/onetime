//
//  Generated code. Do not modify.
//  source: message.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use encryptedMessageProtoDescriptor instead')
const EncryptedMessageProto$json = {
  '1': 'EncryptedMessageProto',
  '2': [
    {'1': 'sender_id', '3': 1, '4': 1, '5': 9, '10': 'senderId'},
    {'1': 'created_at_ms', '3': 2, '4': 1, '5': 3, '10': 'createdAtMs'},
    {'1': 'is_compressed', '3': 3, '4': 1, '5': 8, '10': 'isCompressed'},
    {'1': 'content_type', '3': 4, '4': 1, '5': 5, '10': 'contentType'},
    {'1': 'file_name', '3': 5, '4': 1, '5': 9, '10': 'fileName'},
    {'1': 'mime_type', '3': 6, '4': 1, '5': 9, '10': 'mimeType'},
    {'1': 'content', '3': 7, '4': 1, '5': 12, '10': 'content'},
  ],
};

/// Descriptor for `EncryptedMessageProto`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List encryptedMessageProtoDescriptor = $convert.base64Decode(
    'ChVFbmNyeXB0ZWRNZXNzYWdlUHJvdG8SGwoJc2VuZGVyX2lkGAEgASgJUghzZW5kZXJJZBIiCg'
    '1jcmVhdGVkX2F0X21zGAIgASgDUgtjcmVhdGVkQXRNcxIjCg1pc19jb21wcmVzc2VkGAMgASgI'
    'Ugxpc0NvbXByZXNzZWQSIQoMY29udGVudF90eXBlGAQgASgFUgtjb250ZW50VHlwZRIbCglmaW'
    'xlX25hbWUYBSABKAlSCGZpbGVOYW1lEhsKCW1pbWVfdHlwZRgGIAEoCVIIbWltZVR5cGUSGAoH'
    'Y29udGVudBgHIAEoDFIHY29udGVudA==');

