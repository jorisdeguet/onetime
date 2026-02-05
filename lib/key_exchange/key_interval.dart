/// Représente un intervalle de clé [startIndex, endIndex) en octets.
///
/// Structure algébrique pour la gestion des clés One-Time Pad.
/// Les opérations sont :
///   - Extension (+) : ajoute des octets à la fin
///   - Consommation (-) : retire des octets du début
///
/// Invariant : startIndex <= endIndex
/// Un intervalle vide a startIndex == endIndex.
class KeyInterval {
  /// ID de la conversation associée
  final String conversationId;

  /// Index du premier octet disponible (inclusif)
  final int startIndex;

  /// Index de fin (exclusif) - premier octet non disponible
  final int endIndex;

  const KeyInterval({
    required this.conversationId,
    required this.startIndex,
    required this.endIndex,
  });

  /// Crée un intervalle vide pour une conversation
  const KeyInterval.empty(this.conversationId)
      : startIndex = 0,
        endIndex = 0;

  /// Crée un intervalle depuis zéro jusqu'à [length] octets
  KeyInterval.fromLength(this.conversationId, int length)
      : startIndex = 0,
        endIndex = length;

  /// Nombre d'octets disponibles dans l'intervalle
  int get length => endIndex - startIndex;

  /// Alias pour startIndex (compatibilité avec l'ancienne API)
  int get startByte => startIndex;

  /// Alias pour length (compatibilité avec l'ancienne API)
  int get lengthBytes => length;

  /// Alias pour endIndex (compatibilité avec l'ancienne API)
  int get endByte => endIndex;

  /// True si l'intervalle est vide
  bool get isEmpty => startIndex >= endIndex;

  /// True si l'intervalle contient des octets
  bool get isNotEmpty => startIndex < endIndex;

  /// Opérateur + : Extension de la clé (ajoute des octets à la fin)
  ///
  /// Retourne un nouvel intervalle avec endIndex étendu.
  /// Le segment ajouté doit commencer là où l'intervalle actuel se termine.
  ///
  /// Exemple:
  /// ```dart
  /// final key = KeyInterval(conversationId: 'conv1', startIndex: 0, endIndex: 0);
  /// final extended = key + KeyInterval(conversationId: 'conv1', startIndex: 0, endIndex: 1024);
  /// // extended = [0, 1024)
  /// ```
  KeyInterval operator +(KeyInterval segment) {
    if (segment.conversationId != conversationId) {
      throw ArgumentError('Cannot add intervals from different conversations');
    }
    if (segment.startIndex != endIndex) {
      throw ArgumentError(
        'Segment must start at endIndex. Expected $endIndex, got ${segment.startIndex}',
      );
    }
    return KeyInterval(
      conversationId: conversationId,
      startIndex: startIndex,
      endIndex: segment.endIndex,
    );
  }

  /// Opérateur - : Consommation de la clé (retire des octets du début)
  ///
  /// Retourne un nouvel intervalle avec startIndex avancé.
  /// Le segment consommé doit commencer au début de l'intervalle.
  ///
  /// Exemple:
  /// ```dart
  /// final key = KeyInterval(conversationId: 'conv1', startIndex: 0, endIndex: 1024);
  /// final consumed = key - KeyInterval(conversationId: 'conv1', startIndex: 0, endIndex: 12);
  /// // consumed = [12, 1024)
  /// ```
  KeyInterval operator -(KeyInterval segment) {
    if (segment.conversationId != conversationId) {
      throw ArgumentError('Cannot subtract intervals from different conversations');
    }
    if (segment.startIndex != startIndex) {
      throw ArgumentError(
        'Segment must start at startIndex. Expected $startIndex, got ${segment.startIndex}',
      );
    }
    if (segment.endIndex > endIndex) {
      throw ArgumentError(
        'Cannot consume more than available. Max: $endIndex, requested: ${segment.endIndex}',
      );
    }
    return KeyInterval(
      conversationId: conversationId,
      startIndex: segment.endIndex,
      endIndex: endIndex,
    );
  }

  /// Crée un segment de consommation de [bytesCount] octets depuis le début
  KeyInterval consumeSegment(int bytesCount) {
    if (bytesCount > length) {
      throw ArgumentError('Cannot consume $bytesCount bytes, only $length available');
    }
    return KeyInterval(
      conversationId: conversationId,
      startIndex: startIndex,
      endIndex: startIndex + bytesCount,
    );
  }

  /// Crée un segment d'extension de [bytesCount] octets à la fin
  KeyInterval extendSegment(int bytesCount) {
    return KeyInterval(
      conversationId: conversationId,
      startIndex: endIndex,
      endIndex: endIndex + bytesCount,
    );
  }

  /// Vérifie si cet intervalle contient entièrement un autre intervalle
  bool contains(KeyInterval other) {
    return other.conversationId == conversationId &&
           other.startIndex >= startIndex &&
           other.endIndex <= endIndex;
  }

  /// Vérifie si deux intervalles se chevauchent
  bool overlaps(KeyInterval other) {
    if (other.conversationId != conversationId) return false;
    return startIndex < other.endIndex && other.startIndex < endIndex;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is KeyInterval &&
           other.conversationId == conversationId &&
           other.startIndex == startIndex &&
           other.endIndex == endIndex;
  }

  @override
  int get hashCode => Object.hash(conversationId, startIndex, endIndex);

  @override
  String toString() => '[$startIndex, $endIndex)';

  /// Format court pour les logs
  String toShortString() => '[$startIndex, $endIndex)';

  /// Sérialisation JSON
  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'startIndex': startIndex,
    'endIndex': endIndex,
  };

  /// Désérialisation JSON
  factory KeyInterval.fromJson(Map<String, dynamic> json) => KeyInterval(
    conversationId: json['conversationId'] as String,
    startIndex: json['startIndex'] as int,
    endIndex: json['endIndex'] as int,
  );
}

