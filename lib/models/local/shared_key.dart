import 'dart:math';
import 'dart:typed_data';

import 'key_history.dart';
import 'key_interval.dart';

/// Represents a shared key between multiple peers for One-Time Pad encryption.
///
/// Allocation is linear: all peers share the entire key space.
/// This implementation enforces byte alignment and uses a simple
/// `_nextAvailableByte` index that indicates the first free byte (linear allocation).
class SharedKey {
  /// Unique identifier of the shared key
  final String id;

  /// Binary key data
  final Uint8List keyData;

  /// List of peer IDs sharing this key (sorted ascending)
  final List<String> peerIds;

  // Index of the next available byte in keyData
  // Also the offset since key inception
  int _nextAvailableByte;

  /// Key creation date
  final DateTime createdAt;

  /// History of key operations (extensions and consumptions)
  final KeyHistory history;

  SharedKey({
    required this.id,
    required this.keyData,
    required this.peerIds,
    DateTime? createdAt,
    KeyHistory? history,
    required int nextAvailableByte,
  })  : _nextAvailableByte = nextAvailableByte,
        history = history ?? KeyHistory(conversationId: id),
        createdAt = createdAt ?? DateTime.now() {
    // Ensure peers are sorted
    peerIds.sort();

    // If we load state matches the actual stored key size. This
    // avoids inconsistencies where the key bytes are non-empty but history
    // is empty which would make operators like + fail due to mismatched bounds.
    if (this.history.isEmpty) {
      final totalEnd = _nextAvailableByte + keyData.length;
      if (totalEnd > 0) {
        // Record an initial extension from 0 to totalEnd
        this.history.recordExtension(
          segment: KeyInterval(conversationId: id, startIndex: 0, endIndex: totalEnd),
          reason: 'migrated',
        );
      }
    }
  }

  // Sanity check function that goes through history and ensures that
  // all consumed segments are one after the other without gaps
  // and that nextAvailableByte matches the end of the last consumed segment
  int validateState() {
    int expectedNextByte = 0;
    for (final operation in history.operations) {
      if (operation.type == KeyOperationType.consumption) {
        if (operation.segment.startByte == expectedNextByte) {
          // This segment is contiguous
          expectedNextByte = operation.segment.endByte;
        } else if (operation.segment.startByte > expectedNextByte) {
          throw StateError('Gap detected in key consumption history at byte index $expectedNextByte');
        } else {
          // Overlapping segment, should not happen
          throw StateError('Overlapping segment detected in key consumption history at byte index ${operation.segment.startByte}');
        }
      }
    }
    if (expectedNextByte != _nextAvailableByte) {
      throw StateError('nextAvailableByte mismatch: expected $expectedNextByte but found $_nextAvailableByte');
    }
    return expectedNextByte;
  }

  /// Public getter for next available byte index
  int get nextAvailableByte => _nextAvailableByte;

  /// Returns current key interval as KeyInterval.
  /// startIndex = nextAvailableByte (first available byte)
  /// endIndex = startOffset + keyData.length (key end)
  KeyInterval get interval => KeyInterval(
    conversationId: id,
    startIndex: _nextAvailableByte,
    endIndex: _nextAvailableByte + keyData.length,
  );

  // Total length since inception: already used + actually available
  int get lengthInBytes => _nextAvailableByte + keyData.length;

  bool isByteUsed(int byteIndex) {
    if (byteIndex < 0 || byteIndex >= keyData.length) {
      throw StateError('Byte index out of range: $byteIndex (keyData length=${keyData.length})');
    }
    return byteIndex < _nextAvailableByte;
  }

  /// Marks a byte interval as used (endByte exclusive)
  /// In linear allocation mode, we simply advance `_nextAvailableByte`.
  void markBytesAsUsed(int startByte, int endByte) {
    if (endByte <= startByte) return;
    final e = min(endByte, _nextAvailableByte + keyData.length);
    // Add a consumption record to history
    final segment = KeyInterval(
      conversationId: id,
      startIndex: startByte,
      endIndex: e,
    );
    history.recordConsumption(
        segment: segment,
        reason: "message sending",
        messageId: "TODO"
    );
    _nextAvailableByte = max(_nextAvailableByte, e);
  }

  /// Finds next available segment in bytes (simplified linear allocation)
  /// Returns tuple (startByte, lengthBytes) or null if not enough bytes.
  KeyInterval? findAvailableSegmentByBytes(int bytesNeeded) {
    if (bytesNeeded <= 0) return null;
    final firstFree = _nextAvailableByte;
    final available = keyData.length;
    if (available >= bytesNeeded) {
      // Return a new KeyInterval with this id (same as conversation) and the found range
      return KeyInterval(
        conversationId: id,
        startIndex: firstFree,
        endIndex: firstFree + bytesNeeded,
      );
    }
    return null;
  }

  /// Extracts contiguous bytes from local key.
  /// [startByte] is an absolute byte index (from key inception)
  /// [lengthBytes] is the number of bytes to extract
  Uint8List extractKeyBytes(int startByte, int lengthBytes) {
    if (startByte < 0 || lengthBytes <= 0) throw RangeError('Invalid byte range');
    if (startByte < _nextAvailableByte) {
      throw StateError('Cannot extract bytes from truncated part of key (startByte=$startByte < nextAvailableByte=$_nextAvailableByte)');
    }

    final endByte = startByte + lengthBytes;
    final keyEndByte = _nextAvailableByte + keyData.length; // Absolute end of key

    if (endByte > keyEndByte) {
      throw RangeError('Requested bytes exceed key length (endByte=$endByte > keyEndByte=$keyEndByte)');
    }

    // Convert absolute indices to relative indices within keyData
    final relativeStart = startByte - _nextAvailableByte;
    final relativeEnd = endByte - _nextAvailableByte;

    return Uint8List.fromList(keyData.sublist(relativeStart, relativeEnd));
  }

  int countAvailableBytes() => keyData.length;

  // Extends key after key expansion IRL
  SharedKey extend(Uint8List additionalKeyData, {String? kexId}) {
    if (additionalKeyData.isEmpty) return this;
    final newKeyData = Uint8List(keyData.length + additionalKeyData.length);
    newKeyData.setRange(0, keyData.length, keyData);
    newKeyData.setRange(keyData.length, newKeyData.length, additionalKeyData);
    // Create extended segment for history
    // baseIndex is taken from history.currentState to ensure consistency
    // between stored history and newly appended bytes (handles migration cases
    // where history and keyData might have diverged).
    final baseIndex = history.currentState.endIndex;
    final extSegment = KeyInterval(
      conversationId: id,
      startIndex: baseIndex,
      endIndex: baseIndex + additionalKeyData.length,
    );
    // Copy history and record extension
    final newHistory = history.copy();
    newHistory.recordExtension(
      segment: extSegment,
      reason: kexId != null ? 'kex id=$kexId' : 'extend',
      kexId: kexId,
    );
    return SharedKey(
      id: id,
      keyData: newKeyData,
      peerIds: List.from(peerIds),
      createdAt: createdAt,
      history: newHistory,
      nextAvailableByte: _nextAvailableByte,
    );
  }

  /// Serializes key for local storage
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'peerIds': peerIds,
      'nextAvailableByte': _nextAvailableByte,
      'createdAt': createdAt.toIso8601String(),
      'history': history.toJson(),
    };
  }

  /// Deserializes a key from local storage
  factory SharedKey.fromJson(Map<String, dynamic> json) {
    final startOffset = json['startOffset'] as int? ?? 0;
    final id = json['id'] as String;

    // Load history if present
    KeyHistory? history;
    if (json['history'] != null) {
      history = KeyHistory.fromJson(json['history'] as Map<String, dynamic>);
    }

    int? nextAvail = json['nextAvailableByte'] as int? ?? startOffset;

    // Note: keyData bytes must be read from KeyFileStorage after constructing the object.
    return SharedKey(
      id: id,
      keyData: Uint8List(0), // placeholder; caller must replace by reading file
      peerIds: List<String>.from(json['peerIds'] as List),
      createdAt: DateTime.parse(json['createdAt'] as String),
      history: history,
      nextAvailableByte: nextAvail,
    );
  }
}
