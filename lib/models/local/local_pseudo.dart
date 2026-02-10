import 'package:json_annotation/json_annotation.dart';

part 'local_pseudo.g.dart';

/// Model for storing user pseudonyms locally.
/// Contains the user's own pseudo and a map of other users' pseudos.
@JsonSerializable()
class LocalPseudo {
  /// The current user's pseudonym
  final String? myPseudo;

  /// Map of user IDs to their pseudonyms
  final Map<String, String> pseudos;

  LocalPseudo({
    this.myPseudo,
    Map<String, String>? pseudos,
  }) : pseudos = pseudos ?? {};

  /// Creates a copy with updated fields
  LocalPseudo copyWith({
    String? myPseudo,
    Map<String, String>? pseudos,
  }) {
    return LocalPseudo(
      myPseudo: myPseudo ?? this.myPseudo,
      pseudos: pseudos ?? Map.from(this.pseudos),
    );
  }

  factory LocalPseudo.fromJson(Map<String, dynamic> json) =>
      _$LocalPseudoFromJson(json);

  Map<String, dynamic> toJson() => _$LocalPseudoToJson(this);
}

