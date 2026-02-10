/// Represents a key interval [startIndex, endIndex) in bytes.
///
/// Algebraic structure for One-Time Pad key management.
/// Operations are:
///   - Extension (+): adds bytes at the end
///   - Consumption (-): removes bytes from the beginning
///
/// Invariant: startIndex <= endIndex
/// An empty interval has startIndex == endIndex.
class KeyInterval {
  /// Associated conversation ID
  final String conversationId;

  /// Index of first available byte (inclusive)
  final int startIndex;

  /// End index (exclusive) - first unavailable byte
  final int endIndex;

  const KeyInterval({
    required this.conversationId,
    required this.startIndex,
    required this.endIndex,
  });

  /// Creates an empty interval for a conversation
  const KeyInterval.empty(this.conversationId)
      : startIndex = 0,
        endIndex = 0;

  /// Creates an interval from zero to [length] bytes
  KeyInterval.fromLength(this.conversationId, int length)
      : startIndex = 0,
        endIndex = length;

  /// Number of available bytes in the interval
  int get length => endIndex - startIndex;

  /// Alias for startIndex (backward compatibility)
  int get startByte => startIndex;

  /// Alias for length (backward compatibility)
  int get lengthBytes => length;

  /// Alias for endIndex (backward compatibility)
  int get endByte => endIndex;

  /// True if the interval is empty
  bool get isEmpty => startIndex >= endIndex;

  /// True if the interval contains bytes
  bool get isNotEmpty => startIndex < endIndex;

  /// Operator +: Key extension (adds bytes at the end)
  ///
  /// Returns a new interval with extended endIndex.
  /// The added segment must start where the current interval ends.
  ///
  /// Example:
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

  /// Operator -: Key consumption (removes bytes from the beginning)
  ///
  /// Returns a new interval with advanced startIndex.
  /// The consumed segment must start at the beginning of the interval.
  ///
  /// Example:
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

  /// Creates a consumption segment of [bytesCount] bytes from the beginning
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

  /// Creates an extension segment of [bytesCount] bytes at the end
  KeyInterval extendSegment(int bytesCount) {
    return KeyInterval(
      conversationId: conversationId,
      startIndex: endIndex,
      endIndex: endIndex + bytesCount,
    );
  }

  /// Checks if this interval fully contains another interval
  bool contains(KeyInterval other) {
    return other.conversationId == conversationId &&
           other.startIndex >= startIndex &&
           other.endIndex <= endIndex;
  }

  /// Checks if two intervals overlap
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

  /// Short format for logs
  String toShortString() => '[$startIndex, $endIndex)';

  /// JSON serialization
  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'startIndex': startIndex,
    'endIndex': endIndex,
  };

  /// JSON deserialization
  factory KeyInterval.fromJson(Map<String, dynamic> json) => KeyInterval(
    conversationId: json['conversationId'] as String,
    startIndex: json['startIndex'] as int,
    endIndex: json['endIndex'] as int,
  );
}
