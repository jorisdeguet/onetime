// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_pseudo.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

LocalPseudo _$LocalPseudoFromJson(Map<String, dynamic> json) => LocalPseudo(
  myPseudo: json['myPseudo'] as String?,
  pseudos: (json['pseudos'] as Map<String, dynamic>?)?.map(
    (k, e) => MapEntry(k, e as String),
  ),
);

Map<String, dynamic> _$LocalPseudoToJson(LocalPseudo instance) =>
    <String, dynamic>{
      'myPseudo': instance.myPseudo,
      'pseudos': instance.pseudos,
    };
