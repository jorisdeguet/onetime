import 'dart:async';

import 'package:onetime/services/app_logger.dart';
import 'package:onetime/services/local_storage_service.dart';
import 'package:onetime/models/local/models.dart';

// Re-export DecryptedMessageData from models.dart for backwards compatibility
export 'package:onetime/models/local/models.dart' show LocalMessage;

/// Service to locally store decrypted messages.
///
/// Uses the new file-based storage structure:
/// ```
/// conversations/<conversationId>/messages/<messageId>.json
/// ```
class MessageStorage {
  static final MessageStorage _instance = MessageStorage._internal();
  factory MessageStorage() => _instance;
  MessageStorage._internal();

  final _log = AppLogger();
  final _storage = LocalStorageService();

  // Stream controllers per conversation to notify UI
  final Map<String, StreamController<List<LocalMessage>>> _controllers = {};

  Stream<List<LocalMessage>> watchConversationMessages(String conversationId) {
    // Ensure internal controller exists (used to broadcast updates)
    if (!_controllers.containsKey(conversationId)) {
      _log.d('MessageStorage', 'Creating stream controller for conversation $conversationId');
      _controllers[conversationId] = StreamController<List<LocalMessage>>.broadcast();
    }
    _log.d('MessageStorage', 'watchConversationMessages subscribed (wrapper) for $conversationId');
    return Stream.multi((subscriber) async {
      // Emit initial snapshot
      try {
        final initial = await getConversationMessages(conversationId);
        subscriber.add(initial);
      } catch (e) {
        _log.e('MessageStorage', 'Error emitting initial messages: $e');
      }

      // Forward subsequent updates
      final sub = _controllers[conversationId]!.stream.listen((msgs) {
        try {
          subscriber.add(msgs);
        } catch (e) {
          // Ignore add errors when subscriber is closed
        }
      }, onError: (e) {
        try {
          subscriber.addError(e);
        } catch (_) {}
      });

      // Cancel forwarding when subscriber cancels
      subscriber.onCancel = () async {
        await sub.cancel();
      };
    });
  }

  Future<void> _emitConversationMessages(String conversationId) async {
    if (_controllers.containsKey(conversationId) && !_controllers[conversationId]!.isClosed) {
      _log.d('MessageStorage', 'Emitting messages for conversation $conversationId');
      final msgs = await getConversationMessages(conversationId);
      try {
        _controllers[conversationId]!.add(msgs);
      } catch (_) {}
    }
  }

  /// Saves a decrypted message locally
  Future<void> saveDecryptedMessage({
    required String conversationId,
    required LocalMessage message,
  }) async {
    _log.i('MessageStorage', 'Saving decrypted message ${message.id}');

    try {
      // Idempotence: if message already exists, skip
      final exists = await _storage.messageExists(conversationId, message.id);
      if (exists) {
        _log.d('MessageStorage', 'Message ${message.id} already present locally — skipping save');
        await _emitConversationMessages(conversationId);
        return;
      }

      await _storage.saveMessage(conversationId, message.id, message.toJson());

      // Notify listeners
      await _emitConversationMessages(conversationId);

      _log.i('MessageStorage', 'Message saved successfully');
    } catch (e) {
      _log.e('MessageStorage', 'Error saving message: $e');
      rethrow;
    }
  }

  /// Updates an existing message (e.g., cloud status)
  Future<void> updateMessage({
    required String conversationId,
    required LocalMessage message,
  }) async {
    _log.d('MessageStorage', 'Updating message ${message.id}');

    try {
      await _storage.saveMessage(conversationId, message.id, message.toJson());

      // Notify listeners
      await _emitConversationMessages(conversationId);

      _log.d('MessageStorage', 'Message ${message.id} updated successfully');
    } catch (e) {
      _log.e('MessageStorage', 'Error updating message: $e');
      rethrow;
    }
  }

  /// Gets a decrypted message
  Future<LocalMessage?> getDecryptedMessage({
    required String conversationId,
    required String messageId,
  }) async {
    try {
      final json = await _storage.readMessage(conversationId, messageId);
      if (json == null) return null;
      return LocalMessage.fromJson(json);
    } catch (e) {
      _log.e('MessageStorage', 'Error getting message: $e');
      return null;
    }
  }

  /// Gets all decrypted messages for a conversation
  Future<List<LocalMessage>> getConversationMessages(String conversationId) async {
    try {
      final messageIds = await _storage.listMessageIds(conversationId);
      final messages = <LocalMessage>[];

      for (final messageId in messageIds) {
        final message = await getDecryptedMessage(
          conversationId: conversationId,
          messageId: messageId,
        );
        if (message != null) {
          messages.add(message);
        }
      }

      // Sort by date
      messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      return messages;
    } catch (e) {
      _log.e('MessageStorage', 'Error getting conversation messages: $e');
      return [];
    }
  }

  /// Gets the last message timestamp for a conversation
  Future<DateTime?> getLastMessageTimestamp(String conversationId) async {
    try {
      final messages = await getConversationMessages(conversationId);
      if (messages.isEmpty) return null;
      return messages.last.createdAt;
    } catch (e) {
      _log.e('MessageStorage', 'Error getting last message timestamp: $e');
      return null;
    }
  }

  /// Deletes a decrypted message
  Future<void> deleteDecryptedMessage({
    required String conversationId,
    required String messageId,
  }) async {
    _log.i('MessageStorage', 'Deleting decrypted message $messageId');

    try {
      await _storage.deleteMessage(conversationId, messageId);

      // Notify listeners
      await _emitConversationMessages(conversationId);

      _log.i('MessageStorage', 'Message deleted successfully');
    } catch (e) {
      _log.e('MessageStorage', 'Error deleting message: $e');
    }
  }

  /// Deletes all messages for a conversation
  Future<void> deleteConversationMessages(String conversationId) async {
    _log.i('MessageStorage', 'Deleting all messages for conversation $conversationId');

    try {
      final messageIds = await _storage.listMessageIds(conversationId);

      for (final messageId in messageIds) {
        await _storage.deleteMessage(conversationId, messageId);
      }

      // Notify listeners
      await _emitConversationMessages(conversationId);

      // Close and remove any controller to avoid leaks for deleted conversations
      if (_controllers.containsKey(conversationId)) {
        try {
          await _controllers[conversationId]!.close();
        } catch (_) {}
        _controllers.remove(conversationId);
        _log.d('MessageStorage', 'Controller closed for deleted conversation $conversationId');
      }

      _log.i('MessageStorage', 'All messages deleted');
    } catch (e) {
      _log.e('MessageStorage', 'Error deleting conversation messages: $e');
    }
  }

  /// Close and remove the controller for a conversation (safe to call multiple times)
  Future<void> closeController(String conversationId) async {
    if (_controllers.containsKey(conversationId)) {
      _log.d('MessageStorage', 'Closing controller for $conversationId');
      try {
        await _controllers[conversationId]!.close();
      } catch (e) {
        _log.e('MessageStorage', 'Error closing controller for $conversationId: $e');
      }
      _controllers.remove(conversationId);
    }
  }

  Future<int> getConversationSize(String convId) async {
    return _storage.getConversationSize(convId);
  }
}
