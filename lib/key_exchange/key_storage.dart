import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:onetime/services/app_logger.dart';
import 'package:onetime/services/firestore_service.dart';
import 'package:onetime/signin/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../key_exchange/key_history.dart';
import '../key_exchange/shared_key.dart';


import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

// Key storage, bytes and metadata
class KeyStorage {
  static const String _keyPrefix = 'shared_key_';
  final _log = AppLogger();

  // Optional local user id used to report key debug info to Firestore
  late final String _localUserId;
  late final FirestoreService? _conversationService;

  KeyStorage._privateConstructor(){
    _localUserId = AuthService().currentUserId!;
    _conversationService = FirestoreService(localUserId: _localUserId);
  }
  static final KeyStorage instance = KeyStorage._privateConstructor();

  /// Sauvegarde une clé partagée pour une conversation
  Future<void> saveKey(String conversationId, SharedKey key) async {
     _log.i('KeyStorage', 'saveKey: conversationId=$conversationId, keyLength=${key.lengthInBytes} bytes');

     try {
       final prefs = await SharedPreferences.getInstance();

       // Sérialiser la métadonnée de la clé (sans keyData)
       final keyJson = key.toJson();

       // Ensure the stored id is the conversationId (legacy keys may contain other ids)
       keyJson['id'] = conversationId;

       // Save raw bytes to file storage
       await saveKeyBytes(conversationId, key.keyData);

       // Sauvegarder les métadonnées
       await prefs.setString('${_keyPrefix}meta_$conversationId', jsonEncode(keyJson));

       _log.i('KeyStorage', 'saveKey: SUCCESS');

       // Update Firestore debug info if possible
       try {
         if (_conversationService != null && _localUserId.isNotEmpty) {
           final info = {
             'history': key.history.toJson(),
             'interval': key.interval.toJson(),
             'nextAvailableByte': key.nextAvailableByte,
             //'startOffset': key.startOffset,
           };
           await _conversationService.updateKeyDebugInfo(
             conversationId: conversationId,
             userId: _localUserId,
             info: info,
           );
           _log.d('KeyStorage', 'Firestore keyDebugInfo updated after saveKey');
         }
       } catch (e) {
         _log.w('KeyStorage', 'Could not update Firestore keyDebugInfo: $e');
       }
     } catch (e) {
       _log.e('KeyStorage', 'saveKey ERROR: $e');
       rethrow;
     }
   }

   /// Récupère une clé partagée pour une conversation
   Future<SharedKey> getKey(String conversationId) async {
     _log.i('KeyStorage', 'getKey: conversationId=$conversationId');

     try {
       final prefs = await SharedPreferences.getInstance();

       // Récupérer les octets de la clé depuis le fichier local
       final keyData = await readKeyBytes(conversationId);

       // Récupérer les métadonnées
       final metadataStr = prefs.getString('${_keyPrefix}meta_$conversationId');
       if (metadataStr == null) {
         _log.i('KeyStorage', 'getKey: metadata NOT FOUND');
         throw Exception('Key metadata not found for conversation $conversationId');
       }

       final metadata = jsonDecode(metadataStr) as Map<String, dynamic>;

       // Charger l'historique si présent
       KeyHistory? history;
       if (metadata['history'] != null) {
         history = KeyHistory.fromJson(metadata['history'] as Map<String, dynamic>);
       }

       final nextAvail = metadata['nextAvailableByte'] as int? ?? (metadata['startOffset'] as int? ?? 0);
       final startOffset = metadata['startOffset'] as int? ?? 0;

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
       try {
         final histStr = key.history.format();
         _log.i('KeyStorage', 'Key history:\n$histStr');

         if (_conversationService != null && _localUserId.isNotEmpty) {
           final info = {
             'history': key.history.toJson(),
             'interval': key.interval.toJson(),
             'nextAvailableByte': key.nextAvailableByte,
             //'startOffset': key.startOffset,
           };
           await _conversationService.updateKeyDebugInfo(
             conversationId: conversationId,
             userId: _localUserId,
             info: info,
           );
           _log.d('KeyStorage', 'Firestore keyDebugInfo updated after getKey');
         }
       } catch (e) {
         _log.w('KeyStorage', 'Could not push history to Firestore: $e');
       }

       return key;
     } catch (e) {
       _log.e('KeyStorage', 'getKey ERROR: $e');
       rethrow;
     }
   }

   /// Met à jour les octets utilisés pour une clé (startByte inclus, endByte exclusive)
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
        await truncatePrefix(conversationId, bytesToRemove);
        // Read remaining bytes and construct a new SharedKey with updated startOffset
        final remainingBytes = await readKeyBytes(conversationId);
        final newKey = SharedKey(
          id: conversationId,
          keyData: Uint8List.fromList(remainingBytes),
          peerIds: List.from(key.peerIds),
          createdAt: key.createdAt,
          history: key.history.copy(),
          nextAvailableByte: key.nextAvailableByte,
        );
        // Persist the new state (this will overwrite meta and file with same bytes)
        await saveKey(conversationId, newKey);
      } else {
        // No bytes removed, but metadata/history changed (likely only history/nextAvailableByte)
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
       final prefs = await SharedPreferences.getInstance();
       await prefs.remove('${_keyPrefix}meta_$conversationId');
       await deleteKeyFile(conversationId);
       _log.i('KeyStorage', 'deleteKey: SUCCESS');
     } catch (e) {
       _log.e('KeyStorage', 'deleteKey ERROR: $e');
     }
   }

   /// Liste toutes les conversations qui ont une clé
   Future<List<String>> listConversationsWithKeys() async {
     return listSavedKeys();
   }

  Future<int> getTotalUsedBytes() async {
    int totalUsed = 0;
    final conversationIds = await listConversationsWithKeys();
    for (final convoId in conversationIds) {
      final size = await getKeyFileSize(convoId);
      totalUsed += size;
    }
    return totalUsed;
  }

  Future<Directory> _getBaseDir() async {
    // Fallback simple: use current directory + /keys. In Flutter app you may
    // wish to replace this with getApplicationDocumentsDirectory() from path_provider.
    final dir = await getApplicationDocumentsDirectory();;
    final base = Directory(join(dir.path, 'keys'));
    if (!await base.exists()) {
      await base.create(recursive: true);
    }
    return base;
  }

  File _fileForId(String conversationId, Directory baseDir) {
    // filename = conversationId (no extension)
    final safeName = _sanitizeFileName(conversationId);
    return File(join(baseDir.path, safeName));
  }

  String _sanitizeFileName(String id) {
    // Remove path separators and other problematic chars
    return id.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  /// Écrit complètement le contenu de la clé (écrase si exists)
  Future<void> saveKeyBytes(String conversationId, Uint8List bytes) async {
    final base = await _getBaseDir();
    final f = _fileForId(conversationId, base);
    try {
      // Write atomically: write to temp then rename
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      if (await f.exists()) {
        await f.delete();
      }
      await tmp.rename(f.path);
      _log.i('KeyFileStorage', 'Saved key file for $conversationId (${bytes.length} bytes)');
    } catch (e) {
      _log.e('KeyFileStorage', 'Error saving key file for $conversationId: $e');
      rethrow;
    }
  }

  /// Lire tout le contenu de la clé. Lance si le fichier n'existe pas.
  Future<Uint8List> readKeyBytes(String conversationId) async {
    final base = await _getBaseDir();
    final f = _fileForId(conversationId, base);
    if (!await f.exists()) {
      throw FileSystemException('Key file not found', f.path);
    }
    final bytes = await f.readAsBytes();
    _log.d('KeyFileStorage', 'Read key file for $conversationId (${bytes.length} bytes)');
    return Uint8List.fromList(bytes);
  }

  /// Retirer les `bytesToRemove` premiers octets du fichier.
  /// Si bytesToRemove >= file.length, le fichier est supprimé et un Uint8List(0) doit être considéré par l'appelant.
  Future<void> truncatePrefix(String conversationId, int bytesToRemove) async {
    if (bytesToRemove <= 0) return;
    final base = await _getBaseDir();
    final f = _fileForId(conversationId, base);
    if (!await f.exists()) {
      _log.w('KeyFileStorage', 'truncatePrefix called but file does not exist for $conversationId');
      return;
    }

    try {
      final bytes = await f.readAsBytes();
      if (bytesToRemove >= bytes.length) {
        await f.delete();
        _log.i('KeyFileStorage', 'Truncated entire key file for $conversationId (deleted)');
        return;
      }
      final remaining = bytes.sublist(bytesToRemove);
      // Write atomically
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(remaining, flush: true);
      await f.delete();
      await tmp.rename(f.path);
      _log.i('KeyFileStorage', 'Truncated $bytesToRemove bytes from key file $conversationId; remaining ${remaining.length} bytes');
    } catch (e) {
      _log.e('KeyFileStorage', 'Error truncating key file for $conversationId: $e');
      rethrow;
    }
  }

  Future<void> deleteKeyFile(String conversationId) async {
    final base = await _getBaseDir();
    final f = _fileForId(conversationId, base);
    if (await f.exists()) {
      await f.delete();
      _log.i('KeyFileStorage', 'Deleted key file for $conversationId');
    }
  }

  Future<bool> exists(String conversationId) async {
    final base = await _getBaseDir();
    final f = _fileForId(conversationId, base);
    return f.exists();
  }

  /// Retourne la liste des conversationIds pour lesquelles un fichier de clé est présent.
  Future<List<String>> listSavedKeys() async {
    final base = await _getBaseDir();
    final entries = base.listSync().whereType<File>();
    final ids = entries.map((f) => basename(f.path)).toList();
    _log.d('KeyFileStorage', 'Listed ${ids.length} key files');
    return ids;
  }

  /// Retourne la taille du fichier de clé en octets, ou 0 si absent.
  Future<int> getKeyFileSize(String conversationId) async {
    final base = await _getBaseDir();
    final f = _fileForId(conversationId, base);
    if (!await f.exists()) return 0;
    return await f.length();
  }
 }
