import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'key_history.dart';
import 'key_interval.dart';


/// Représente une clé partagée entre plusieurs pairs pour le chiffrement One-Time Pad.
///
/// L'allocation est linéaire : tous les pairs partagent l'espace entier de la clé.
/// Cette implémentation force l'alignement sur octet et utilise un simple index
/// `_nextAvailableByte` qui indique le premier octet libre (allocation linéaire).
class SharedKey {
  /// Identifiant unique de la clé partagée
  final String id;

  /// Les données binaires de la clé
  final Uint8List keyData;

  /// Liste des IDs des pairs partageant cette clé (triés par ordre croissante)
  final List<String> peerIds;

  // index of the next available byte in the keyData
  // also the offset since key inception
  int _nextAvailableByte;

  /// Date de création de la clé
  final DateTime createdAt;

  /// Historique des opérations sur la clé (extensions et consommations)
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
    // S'assurer que les peers sont triés
    peerIds.sort();

    // Normaliser _nextAvailableByte
    final int maxIndex = keyData.length;

    // If we load State matches the actual stored key size. This
    // avoids inconsistencies where the key bytes are non-empty but history
    // is empty which would make operators like + fail due to mismatched bounds.
    if (this.history.isEmpty) {
      final totalEnd = _nextAvailableByte + keyData.length;
      if (totalEnd > 0) {
        // record an initial extension from 0 to totalEnd
        this.history.recordExtension(
          segment: KeyInterval(conversationId: id, startIndex: 0, endIndex: totalEnd),
          reason: 'migrated',
        );
      }
    }
  }

  // sanity check function that goes through history and ensures that
  // all consumed segments are one after the other without gaps
  // and that nextAvailableByte matches the end of the last consumed segment
  int validateState() {
    print("validate" + history.format());
    int expectedNextByte = 0;
    for (final operation in history.operations) {
      if (operation.type == KeyOperationType.consumption){
        if (operation.segment.startByte == expectedNextByte) {// This segment is contiguous
          expectedNextByte = operation.segment.endByte;
        } else if (operation.segment.startByte > expectedNextByte) {
          throw StateError('Gap detected in key consumption history at byte index ${expectedNextByte}');
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

  /// Retourne l'intervalle actuel de la clé sous forme de KeyInterval.
  /// startIndex = nextAvailableByte (premier octet disponible)
  /// endIndex = startOffset + keyData.length (fin de la clé)
  KeyInterval get interval => KeyInterval(
    conversationId: id,
    startIndex: _nextAvailableByte,
    endIndex: _nextAvailableByte + keyData.length,
  );

  // total length since inception already used + actually available
  int get lengthInBytes => _nextAvailableByte + keyData.length;


  bool isByteUsed(int byteIndex) {
    if (byteIndex < 0 || byteIndex >= keyData.length) {
      throw StateError('Byte index out of range: $byteIndex (keyData length=${keyData.length})');
    }
    return byteIndex < _nextAvailableByte;
  }

  /// Marque un intervalle d'octets comme utilisé (endByte exclusive)
  /// En mode allocation linéaire, on avance simplement `_nextAvailableByte`.
  void markBytesAsUsed(int startByte, int endByte) {
    print("Mark" + history.format());
    if (endByte <= startByte) return;
    final e = min(endByte, _nextAvailableByte + keyData.length);
    // add a consumption record to history
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
    // Clamp
    //_nextAvailableByte = _nextAvailableByte.clamp(startOffset, startOffset + keyData.length);
  }

  /// Trouve le prochain segment disponible en octets (allocation linéaire simplifiée)
  /// Retourne tuple (startByte, lengthBytes) ou null si pas assez d'octets.
  KeyInterval? findAvailableSegmentByBytes(int bytesNeeded) {
    if (bytesNeeded <= 0) return null;
    final firstFree = _nextAvailableByte;
    final available = keyData.length;
    if (available >= bytesNeeded) {
      // return a new KeyInterval with this id (same as conversation) and the found range
      return KeyInterval(
        conversationId: id,
        startIndex: firstFree,
        endIndex: firstFree + bytesNeeded,
      );
    }
    return null;
  }

  /// Extrait des octets contigus depuis la clé locale.
  /// [startByte] est l'index d'octet relatif au keyData (0-based)
  Uint8List extractKeyBytes(int startByte, int lengthBytes) {
    if (startByte < 0 || lengthBytes <= 0) throw RangeError('Invalid byte range');
    if (startByte < _nextAvailableByte) {
      throw StateError('Cannot extract bytes from truncated part of key');
    }
    final endByte = startByte + lengthBytes;
    if (endByte > keyData.length) {
      throw RangeError('Requested bytes exceed key length');
    }
    return Uint8List.fromList(keyData.sublist(startByte, endByte));
  }

  int countAvailableBytes() => keyData.length;

  // extends key after key expansion IRL
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

  /// Sérialise la clé pour stockage local
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'peerIds': peerIds,
      'nextAvailableByte': _nextAvailableByte,
      'createdAt': createdAt.toIso8601String(),
      'history': history.toJson(),
    };
  }

  /// Désérialise une clé depuis le stockage local
  factory SharedKey.fromJson(Map<String, dynamic> json) {
    final startOffset = json['startOffset'] as int? ?? 0;
    final id = json['id'] as String;

    // Charger l'historique si présent
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
