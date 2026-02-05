import 'key_interval.dart';

/// Type d'opération sur une clé
enum KeyOperationType {
  /// Extension de la clé (ajout d'octets via key exchange)
  extension,

  /// Consommation de la clé (envoi ou réception de message)
  consumption,
}

/// Représente une opération sur une clé avec son contexte
class KeyOperation {
  /// Timestamp de l'opération
  final DateTime timestamp;

  /// Type d'opération
  final KeyOperationType type;

  /// Segment concerné par l'opération
  final KeyInterval segment;

  /// État de la clé avant l'opération
  final KeyInterval keyBefore;

  /// État de la clé après l'opération
  final KeyInterval keyAfter;

  /// Raison/contexte de l'opération
  final String reason;

  /// ID de référence (kexId pour extension, messageId pour consommation)
  final String? referenceId;

  const KeyOperation({
    required this.timestamp,
    required this.type,
    required this.segment,
    required this.keyBefore,
    required this.keyAfter,
    required this.reason,
    this.referenceId,
  });

  /// Symbole de l'opération pour l'affichage
  String get operatorSymbol => type == KeyOperationType.extension ? '+' : '-';

  /// Format lisible de l'opération
  String format({int index = 0}) {
    final timeStr = 't$index';
    final keyStr = 'key = ${keyAfter.toShortString()}';
    final opStr = '$operatorSymbol ${segment.toShortString()}';
    final reasonStr = 'by $reason';

    return '$timeStr : $keyStr\t$opStr $reasonStr';
  }

  /// Sérialisation JSON
  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'type': type.name,
    'segment': segment.toJson(),
    'keyBefore': keyBefore.toJson(),
    'keyAfter': keyAfter.toJson(),
    'reason': reason,
    'referenceId': referenceId,
  };

  /// Désérialisation JSON
  factory KeyOperation.fromJson(Map<String, dynamic> json) => KeyOperation(
    timestamp: DateTime.parse(json['timestamp'] as String),
    type: KeyOperationType.values.byName(json['type'] as String),
    segment: KeyInterval.fromJson(json['segment'] as Map<String, dynamic>),
    keyBefore: KeyInterval.fromJson(json['keyBefore'] as Map<String, dynamic>),
    keyAfter: KeyInterval.fromJson(json['keyAfter'] as Map<String, dynamic>),
    reason: json['reason'] as String,
    referenceId: json['referenceId'] as String?,
  );
}

/// Historique des opérations sur une clé
class KeyHistory {
  /// ID de la conversation
  final String conversationId;

  /// Liste des opérations dans l'ordre chronologique
  final List<KeyOperation> _operations;

  KeyHistory({required this.conversationId}) : _operations = [];

  KeyHistory._internal({
    required this.conversationId,
    required List<KeyOperation> operations,
  }) : _operations = operations;

  /// Liste des opérations (lecture seule)
  List<KeyOperation> get operations => List.unmodifiable(_operations);

  /// Nombre d'opérations
  int get length => _operations.length;

  /// True si aucune opération
  bool get isEmpty => _operations.isEmpty;

  /// État initial de la clé
  KeyInterval get initialState => KeyInterval.empty(conversationId);

  /// État actuel de la clé (après toutes les opérations)
  KeyInterval get currentState {
    if (_operations.isEmpty) return initialState;
    return _operations.last.keyAfter;
  }

  /// Enregistre une opération d'extension
  KeyOperation recordExtension({
    required KeyInterval segment,
    required String reason,
    String? kexId,
  }) {
    final keyBefore = currentState;
    final keyAfter = keyBefore + segment;

    final operation = KeyOperation(
      timestamp: DateTime.now(),
      type: KeyOperationType.extension,
      segment: segment,
      keyBefore: keyBefore,
      keyAfter: keyAfter,
      reason: reason,
      referenceId: kexId,
    );

    _operations.add(operation);
    return operation;
  }

  /// Enregistre une opération de consommation
  KeyOperation recordConsumption({
    required KeyInterval segment,
    required String reason,
    String? messageId,
  }) {
    final keyBefore = currentState;
    final keyAfter = keyBefore - segment;

    final operation = KeyOperation(
      timestamp: DateTime.now(),
      type: KeyOperationType.consumption,
      segment: segment,
      keyBefore: keyBefore,
      keyAfter: keyAfter,
      reason: reason,
      referenceId: messageId,
    );

    _operations.add(operation);
    return operation;
  }

  /// Formate l'historique complet pour affichage
  String format() {
    final buffer = StringBuffer();

    // État initial
    buffer.writeln('t0 : key = ${initialState.toShortString()}');

    // Chaque opération
    for (int i = 0; i < _operations.length; i++) {
      buffer.writeln(_operations[i].format(index: i + 1));
    }

    return buffer.toString().trimRight();
  }

  /// Sérialisation JSON
  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'operations': _operations.map((op) => op.toJson()).toList(),
  };

  /// Désérialisation JSON
  factory KeyHistory.fromJson(Map<String, dynamic> json) => KeyHistory._internal(
    conversationId: json['conversationId'] as String,
    operations: (json['operations'] as List)
        .map((op) => KeyOperation.fromJson(op as Map<String, dynamic>))
        .toList(),
  );

  /// Crée une copie de l'historique
  KeyHistory copy() => KeyHistory._internal(
    conversationId: conversationId,
    operations: List.from(_operations),
  );
}

