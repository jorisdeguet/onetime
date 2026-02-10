import 'dart:typed_data';

import 'package:onetime/services/app_logger.dart';
import 'package:onetime/services/firestore_service.dart';
import 'package:onetime/services/local_storage_service.dart';
import 'package:onetime/services/auth_service.dart';

import '../models/firestore/fs_key_status.dart';
import '../models/local/key_history.dart';
import '../models/local/shared_key.dart';

/// Key storage service.
///
/// Uses the new file-based storage structure:
/// ```
/// conversations/<conversationId>/
/// ├── key.bin          # OTP key bytes
/// ├── key_meta.json    # Key metadata (peerIds, nextAvailableByte, etc.)
/// └── history.json     # Key operations history
/// ```
class KeyStorage {
  final _log = AppLogger();
  final _storage = LocalStorageService();

  // Optional local user id used to report key debug info to Firestore
  late final String _localUserId;
  late final FirestoreService? _conversationService;

  KeyStorage._privateConstructor() {
    _localUserId = AuthService().currentUserId!;
    _conversationService = FirestoreService(localUserId: _localUserId);
  }

  static final KeyStorage instance = KeyStorage._privateConstructor();

  /// Saves a shared key for a conversation
  Future<void> saveKey(String conversationId, SharedKey key) async {
    _log.i('KeyStorage', 'saveKey: conversationId=$conversationId, keyLength=${key.lengthInBytes} bytes');
    try {
      // Serialize key metadata (without keyData and history)
      final keyJson = <String, dynamic>{
        'id': conversationId,
        'peerIds': key.peerIds,
        'nextAvailableByte': key.nextAvailableByte,
        'createdAt': key.createdAt.toIso8601String(),
      };
      // Save raw bytes to file storage
      await _storage.saveKeyBytes(conversationId, key.keyData);
      // Save metadata
      await _storage.saveKeyMetadata(conversationId, keyJson);
      // Save history separately
      await _storage.saveKeyHistory(conversationId, key.history.toJson());
      _log.i('KeyStorage', 'saveKey: SUCCESS');
      // Update Firestore debug info if possible
      await _updateFirestoreDebugInfo(conversationId, key);
    } catch (e) {
      _log.e('KeyStorage', 'saveKey ERROR: $e');
      rethrow;
    }
  }

  /// Gets a shared key for a conversation
  Future<SharedKey> getKey(String conversationId) async {
    _log.i('KeyStorage', 'getKey: conversationId=$conversationId');
    try {
      // Get key bytes
      final keyData = await _storage.readKeyBytes(conversationId);
      // Get metadata
      final metadata = await _storage.readKeyMetadata(conversationId);
      if (metadata == null) {
        _log.i('KeyStorage', 'getKey: metadata NOT FOUND');
        throw Exception('Key metadata not found for conversation $conversationId');
      }
      // Load history from separate file
      KeyHistory? history;
      final historyJson = await _storage.readKeyHistory(conversationId);
      if (historyJson != null) {
        history = KeyHistory.fromJson(historyJson);
      } else if (metadata['history'] != null) {
        // Migration: load from old location in metadata
        history = KeyHistory.fromJson(metadata['history'] as Map<String, dynamic>);
        _log.d('KeyStorage', 'Migrated history from key_meta.json');
      }
      final nextAvail = metadata['nextAvailableByte'] as int? ?? (metadata['startOffset'] as int? ?? 0);
      // Force the key id to be the conversationId to avoid mismatches
      final key = SharedKey(
        id: conversationId,
        keyData: Uint8List.fromList(keyData),
        peerIds: List<String>.from(metadata['peerIds'] as List),
        createdAt: DateTime.parse(metadata['createdAt'] as String),
        history: history,
        nextAvailableByte: nextAvail,
      );
      _log.i('KeyStorage', 'getKey: FOUND, ${key.lengthInBytes} bytes');
      // Log history and push to Firestore for debugging
      await _updateFirestoreDebugInfo(conversationId, key);
      return key;
    } catch (e) {
      _log.e('KeyStorage', 'getKey ERROR: $e');
      rethrow;
    }
  }

  /// Updates used bytes for a key (startByte inclusive, endByte exclusive)
  Future<void> updateUsedBytes(String conversationId, int startByte, int endByte) async {
    _log.i('KeyStorage', 'updateUsedBytes: $conversationId, $startByte-$endByte');

    try {
      final key = await getKey(conversationId);
      int oldNextAvailableByte = key.nextAvailableByte;
      key.markBytesAsUsed(startByte, endByte);

      // Compute how many bytes should be removed from the local file
      final bytesToRemove = key.nextAvailableByte - oldNextAvailableByte;
      if (bytesToRemove > 0) {
        // Truncate the file prefix
        await _storage.truncateKeyPrefix(conversationId, bytesToRemove);
        // Read remaining bytes and construct a new SharedKey with updated startOffset
        final remainingBytes = await _storage.readKeyBytes(conversationId);
        final newKey = SharedKey(
          id: conversationId,
          keyData: Uint8List.fromList(remainingBytes),
          peerIds: List.from(key.peerIds),
          createdAt: key.createdAt,
          history: key.history.copy(),
          nextAvailableByte: key.nextAvailableByte,
        );
        // Persist the new state
        await saveKey(conversationId, newKey);
      } else {
        // No bytes removed, but metadata/history changed
        await saveKey(conversationId, key);
      }
      _log.i('KeyStorage', 'updateUsedBytes: SUCCESS');
    } catch (e) {
      _log.e('KeyStorage', 'updateUsedBytes ERROR: $e');
    }
  }

  Future<void> deleteKey(String conversationId) async {
    _log.i('KeyStorage', 'deleteKey: $conversationId');

    try {
      // Delete the entire conversation folder
      await _storage.deleteConversation(conversationId);
      _log.i('KeyStorage', 'deleteKey: SUCCESS');
    } catch (e) {
      _log.e('KeyStorage', 'deleteKey ERROR: $e');
    }
  }

  /// Lists all conversations that have a key
  Future<List<String>> listConversationsWithKeys() async {
    return _storage.listConversations();
  }

  Future<int> getTotalUsedBytes() async {
    int totalUsed = 0;
    final conversationIds = await listConversationsWithKeys();
    for (final convoId in conversationIds) {
      final size = await _storage.getKeySize(convoId);
      totalUsed += size;
    }
    return totalUsed;
  }

  Future<bool> exists(String conversationId) async {
    return _storage.keyExists(conversationId);
  }

  /// Returns conversation IDs for which a key file exists.
  Future<List<String>> listSavedKeys() async {
    return _storage.listConversations();
  }

  /// Returns the key file size in bytes, or 0 if absent.
  Future<int> getKeyFileSize(String conversationId) async {
    return _storage.getKeySize(conversationId);
  }

  // === Compatibility methods for old API ===

  Future<void> saveKeyBytes(String conversationId, Uint8List bytes) async {
    await _storage.saveKeyBytes(conversationId, bytes);
  }

  Future<Uint8List> readKeyBytes(String conversationId) async {
    return _storage.readKeyBytes(conversationId);
  }

  Future<void> truncatePrefix(String conversationId, int bytesToRemove) async {
    await _storage.truncateKeyPrefix(conversationId, bytesToRemove);
  }

  Future<void> deleteKeyFile(String conversationId) async {
    await _storage.deleteConversation(conversationId);
  }

  /// Helper to update debug info on Firestore
  Future<void> _updateFirestoreDebugInfo(String conversationId, SharedKey key) async {
    try {
      if (_conversationService != null && _localUserId.isNotEmpty) {
        final keyStatus = FsKeyStatus(
          startByte: key.interval.startIndex,
          endByte: key.interval.endIndex,
        );
        await _conversationService.updateKeyDebugInfo(
          conversationId: conversationId,
          userId: _localUserId,
          keyStatus: keyStatus,
        );
        _log.d('KeyStorage', 'Firestore keyDebugInfo updated');
      }
    } catch (e) {
      _log.w('KeyStorage', 'Could not update Firestore keyDebugInfo: $e');
    }
  }
}
