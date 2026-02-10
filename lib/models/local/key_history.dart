import 'key_interval.dart';

/// Key operation type
enum KeyOperationType {
  /// Key extension (bytes added via key exchange)
  extension,

  /// Key consumption (message send or receive)
  consumption,
}

/// Represents an operation on a key with its context
class KeyOperation {
  /// Operation timestamp
  final DateTime timestamp;

  /// Operation type
  final KeyOperationType type;

  /// Segment concerned by the operation
  final KeyInterval segment;

  /// Key state before operation
  final KeyInterval keyBefore;

  /// Key state after operation
  final KeyInterval keyAfter;

  /// Operation reason/context
  final String reason;

  /// Reference ID (kexId for extension, messageId for consumption)
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

  /// Operation symbol for display
  String get operatorSymbol => type == KeyOperationType.extension ? '+' : '-';

  /// Human-readable operation format
  String format({int index = 0}) {
    final timeStr = 't$index';
    final keyStr = 'key = ${keyAfter.toShortString()}';
    final opStr = '$operatorSymbol ${segment.toShortString()}';
    final reasonStr = 'by $reason';

    return '$timeStr : $keyStr\t$opStr $reasonStr';
  }

  /// JSON serialization
  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'type': type.name,
    'segment': segment.toJson(),
    'keyBefore': keyBefore.toJson(),
    'keyAfter': keyAfter.toJson(),
    'reason': reason,
    'referenceId': referenceId,
  };

  /// JSON deserialization
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

/// Key operations history
class KeyHistory {
  /// Conversation ID
  final String conversationId;

  /// List of operations in chronological order
  final List<KeyOperation> _operations;

  KeyHistory({required this.conversationId}) : _operations = [];

  KeyHistory._internal({
    required this.conversationId,
    required List<KeyOperation> operations,
  }) : _operations = operations;

  /// Operations list (read-only)
  List<KeyOperation> get operations => List.unmodifiable(_operations);

  /// Number of operations
  int get length => _operations.length;

  /// True if no operations
  bool get isEmpty => _operations.isEmpty;

  /// Initial key state
  KeyInterval get initialState => KeyInterval.empty(conversationId);

  /// Current key state (after all operations)
  KeyInterval get currentState {
    if (_operations.isEmpty) return initialState;
    return _operations.last.keyAfter;
  }

  /// Records an extension operation
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

  /// Records a consumption operation
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

  /// Formats complete history for display
  String format() {
    final buffer = StringBuffer();

    // Initial state
    buffer.writeln('t0 : key = ${initialState.toShortString()}');

    // Each operation
    for (int i = 0; i < _operations.length; i++) {
      buffer.writeln(_operations[i].format(index: i + 1));
    }

    return buffer.toString().trimRight();
  }

  /// JSON serialization
  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'operations': _operations.map((op) => op.toJson()).toList(),
  };

  /// JSON deserialization
  factory KeyHistory.fromJson(Map<String, dynamic> json) => KeyHistory._internal(
    conversationId: json['conversationId'] as String,
    operations: (json['operations'] as List)
        .map((op) => KeyOperation.fromJson(op as Map<String, dynamic>))
        .toList(),
  );

  /// Creates a copy of the history
  KeyHistory copy() => KeyHistory._internal(
    conversationId: conversationId,
    operations: List.from(_operations),
  );
}
