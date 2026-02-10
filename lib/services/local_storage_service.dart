import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';

/// Unified local storage service.
///
/// Folder structure:
/// ```
/// <app_documents>/
/// └── conversations/
///     └── <conversationId>/
///         ├── key.bin          # OTP key bytes
///         ├── key_meta.json    # Key metadata (peerIds, history, etc.)
///         └── messages/
///             ├── <messageId>.json  # Decrypted message
///             └── ...
/// ```
class LocalStorageService {
  static final LocalStorageService _instance = LocalStorageService._internal();
  factory LocalStorageService() => _instance;
  LocalStorageService._internal();

  final _log = AppLogger();
  Directory? _baseDir;

  /// Initializes service and returns base directory
  Future<Directory> _getBaseDir() async {
    if (_baseDir != null) return _baseDir!;

    final appDir = await getApplicationDocumentsDirectory();
    _baseDir = Directory(path.join(appDir.path, 'conversations'));

    if (!await _baseDir!.exists()) {
      await _baseDir!.create(recursive: true);
    }

    return _baseDir!;
  }

  /// Returns conversation directory (creates if necessary)
  Future<Directory> _getConversationDir(String conversationId) async {
    final base = await _getBaseDir();
    final safeName = _sanitizeFileName(conversationId);
    final dir = Directory(path.join(base.path, safeName));

    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return dir;
  }

  /// Returns messages directory for a conversation
  Future<Directory> _getMessagesDir(String conversationId) async {
    final convDir = await _getConversationDir(conversationId);
    final messagesDir = Directory(path.join(convDir.path, 'messages'));

    if (!await messagesDir.exists()) {
      await messagesDir.create(recursive: true);
    }

    return messagesDir;
  }

  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  // ==================== KEY STORAGE ====================

  /// Saves key bytes
  Future<void> saveKeyBytes(String conversationId, Uint8List bytes) async {
    final convDir = await _getConversationDir(conversationId);
    final file = File(path.join(convDir.path, 'key.bin'));

    try {
      // Atomic write via temporary file
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);
      _log.d('LocalStorage', 'Saved key bytes for $conversationId (${bytes.length} bytes)');
    } catch (e) {
      _log.e('LocalStorage', 'Error saving key bytes: $e');
      rethrow;
    }
  }

  /// Reads key bytes
  Future<Uint8List> readKeyBytes(String conversationId) async {
    final convDir = await _getConversationDir(conversationId);
    final file = File(path.join(convDir.path, 'key.bin'));

    if (!await file.exists()) {
      throw FileSystemException('Key file not found', file.path);
    }

    return Uint8List.fromList(await file.readAsBytes());
  }

  /// Saves key metadata (JSON)
  Future<void> saveKeyMetadata(String conversationId, Map<String, dynamic> metadata) async {
    final convDir = await _getConversationDir(conversationId);
    final file = File(path.join(convDir.path, 'key_meta.json'));

    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(metadata), flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);
      _log.d('LocalStorage', 'Saved key metadata for $conversationId');
    } catch (e) {
      _log.e('LocalStorage', 'Error saving key metadata: $e');
      rethrow;
    }
  }

  /// Reads key metadata
  Future<Map<String, dynamic>?> readKeyMetadata(String conversationId) async {
    final convDir = await _getConversationDir(conversationId);
    final file = File(path.join(convDir.path, 'key_meta.json'));

    if (!await file.exists()) {
      return null;
    }

    final content = await file.readAsString();
    return jsonDecode(content) as Map<String, dynamic>;
  }

  /// Removes first N bytes from key file
  Future<void> truncateKeyPrefix(String conversationId, int bytesToRemove) async {
    if (bytesToRemove <= 0) return;

    final convDir = await _getConversationDir(conversationId);
    final file = File(path.join(convDir.path, 'key.bin'));

    if (!await file.exists()) {
      _log.w('LocalStorage', 'truncateKeyPrefix: file does not exist');
      return;
    }

    try {
      final bytes = await file.readAsBytes();
      if (bytesToRemove >= bytes.length) {
        await file.delete();
        _log.i('LocalStorage', 'Key file deleted (all bytes truncated)');
        return;
      }

      final remaining = bytes.sublist(bytesToRemove);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(remaining, flush: true);
      await file.delete();
      await tmp.rename(file.path);
      _log.d('LocalStorage', 'Truncated $bytesToRemove bytes, ${remaining.length} remaining');
    } catch (e) {
      _log.e('LocalStorage', 'Error truncating key: $e');
      rethrow;
    }
  }

  /// Checks if a key exists
  Future<bool> keyExists(String conversationId) async {
    final convDir = await _getConversationDir(conversationId);
    final file = File(path.join(convDir.path, 'key.bin'));
    return file.exists();
  }

  /// Returns key file size
  Future<int> getKeySize(String conversationId) async {
    final convDir = await _getConversationDir(conversationId);
    final file = File(path.join(convDir.path, 'key.bin'));
    if (!await file.exists()) return 0;
    return file.length();
  }

  // ==================== KEY HISTORY STORAGE ====================

  /// Saves key history (JSON)
  Future<void> saveKeyHistory(String conversationId, Map<String, dynamic> historyJson) async {
    final convDir = await _getConversationDir(conversationId);
    final file = File(path.join(convDir.path, 'history.json'));
    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(historyJson), flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);
      _log.d('LocalStorage', 'Saved key history for $conversationId');
    } catch (e) {
      _log.e('LocalStorage', 'Error saving key history: $e');
      rethrow;
    }
  }

  /// Reads key history
  Future<Map<String, dynamic>?> readKeyHistory(String conversationId) async {
    final convDir = await _getConversationDir(conversationId);
    final file = File(path.join(convDir.path, 'history.json'));
    if (!await file.exists()) {
      return null;
    }
    final content = await file.readAsString();
    return jsonDecode(content) as Map<String, dynamic>;
  }

  // ==================== MESSAGE STORAGE ====================

  /// Saves a message (JSON)
  Future<void> saveMessage(String conversationId, String messageId, Map<String, dynamic> messageJson) async {
    final messagesDir = await _getMessagesDir(conversationId);
    final safeId = _sanitizeFileName(messageId);
    final file = File(path.join(messagesDir.path, '$safeId.json'));

    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(messageJson), flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);
      _log.d('LocalStorage', 'Saved message $messageId for $conversationId');
    } catch (e) {
      _log.e('LocalStorage', 'Error saving message: $e');
      rethrow;
    }
  }

  /// Reads a message
  Future<Map<String, dynamic>?> readMessage(String conversationId, String messageId) async {
    final messagesDir = await _getMessagesDir(conversationId);
    final safeId = _sanitizeFileName(messageId);
    final file = File(path.join(messagesDir.path, '$safeId.json'));

    if (!await file.exists()) {
      return null;
    }

    final content = await file.readAsString();
    return jsonDecode(content) as Map<String, dynamic>;
  }

  /// Deletes a message
  Future<void> deleteMessage(String conversationId, String messageId) async {
    final messagesDir = await _getMessagesDir(conversationId);
    final safeId = _sanitizeFileName(messageId);
    final file = File(path.join(messagesDir.path, '$safeId.json'));

    if (await file.exists()) {
      await file.delete();
      _log.d('LocalStorage', 'Deleted message $messageId');
    }
  }

  /// Lists all message IDs for a conversation
  Future<List<String>> listMessageIds(String conversationId) async {
    final messagesDir = await _getMessagesDir(conversationId);

    if (!await messagesDir.exists()) {
      return [];
    }

    final files = messagesDir.listSync().whereType<File>();
    return files
        .where((f) => f.path.endsWith('.json'))
        .map((f) => path.basenameWithoutExtension(f.path))
        .toList();
  }

  /// Checks if a message exists
  Future<bool> messageExists(String conversationId, String messageId) async {
    final messagesDir = await _getMessagesDir(conversationId);
    final safeId = _sanitizeFileName(messageId);
    final file = File(path.join(messagesDir.path, '$safeId.json'));
    return file.exists();
  }

  // ==================== CONVERSATION MANAGEMENT ====================

  /// Lists all conversations (IDs)
  Future<List<String>> listConversations() async {
    final base = await _getBaseDir();

    if (!await base.exists()) {
      return [];
    }

    final dirs = base.listSync().whereType<Directory>();
    return dirs.map((d) => path.basename(d.path)).toList();
  }

  /// Deletes an entire conversation (key + messages)
  Future<void> deleteConversation(String conversationId) async {
    final convDir = await _getConversationDir(conversationId);

    if (await convDir.exists()) {
      await convDir.delete(recursive: true);
      _log.i('LocalStorage', 'Deleted conversation $conversationId');
    }
  }

  /// Calculates total size of a conversation
  Future<int> getConversationSize(String conversationId) async {
    final convDir = await _getConversationDir(conversationId);

    if (!await convDir.exists()) return 0;

    int totalSize = 0;
    await for (final entity in convDir.list(recursive: true)) {
      if (entity is File) {
        totalSize += await entity.length();
      }
    }
    return totalSize;
  }

  // ==================== ACK STORAGE ====================

  /// Saves local ackId for a message
  Future<void> saveAckId(String conversationId, String messageId, String ackId) async {
    final convDir = await _getConversationDir(conversationId);
    final file = File(path.join(convDir.path, 'acks.json'));

    Map<String, String> acks = {};
    if (await file.exists()) {
      final content = await file.readAsString();
      acks = Map<String, String>.from(jsonDecode(content) as Map);
    }

    acks[messageId] = ackId;
    await file.writeAsString(jsonEncode(acks), flush: true);
  }

  /// Gets local ackId for a message
  Future<String?> getAckId(String conversationId, String messageId) async {
    final convDir = await _getConversationDir(conversationId);
    final file = File(path.join(convDir.path, 'acks.json'));

    if (!await file.exists()) return null;

    final content = await file.readAsString();
    final acks = Map<String, String>.from(jsonDecode(content) as Map);
    return acks[messageId];
  }

  // ==================== READ STATUS STORAGE ====================

  /// Saves read message IDs
  Future<void> saveReadMessageIds(String conversationId, List<String> readIds) async {
    final convDir = await _getConversationDir(conversationId);
    final file = File(path.join(convDir.path, 'read_messages.json'));
    await file.writeAsString(jsonEncode(readIds), flush: true);
  }

  /// Gets read message IDs
  Future<List<String>> getReadMessageIds(String conversationId) async {
    final convDir = await _getConversationDir(conversationId);
    final file = File(path.join(convDir.path, 'read_messages.json'));

    if (!await file.exists()) return [];

    final content = await file.readAsString();
    return List<String>.from(jsonDecode(content) as List);
  }
}
