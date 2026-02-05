import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:onetime/convo/encrypted_message.dart';
import 'package:onetime/services/app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Représente un message déchiffré stocké localement
class DecryptedMessageData {
  final String id;
  final String senderId;
  final DateTime createdAt;
  final MessageContentType contentType;
  
  // Pour les messages texte
  final String? textContent;
  
  // Pour les messages binaires (image/fichier)
  final Uint8List? binaryContent;
  final String? fileName;
  final String? mimeType;
  final bool isCompressed;
  // Métadonnées liées à la clé utilisée pour ce message
  final String? keyId;
  final int? keySegmentStart;
  final int? keySegmentEnd;

  DecryptedMessageData({
    required this.id,
    required this.senderId,
    required this.createdAt,
    required this.contentType,
    this.textContent,
    this.binaryContent,
    this.fileName,
    this.mimeType,
    this.isCompressed = false,
    this.keyId,
    this.keySegmentStart,
    this.keySegmentEnd,
  });

  Map<String, dynamic> toJson() {
    return {
      "id": id,
      'senderId': senderId,
      'createdAt': createdAt.toIso8601String(),
      'contentType': contentType.name,
      'textContent': textContent,
      'binaryContent': binaryContent != null ? base64Encode(binaryContent!) : null,
      'fileName': fileName,
      'mimeType': mimeType,
      'isCompressed': isCompressed,
      'keyId': keyId,
      'keySegmentStart': keySegmentStart,
      'keySegmentEnd': keySegmentEnd,
    };
  }

  factory DecryptedMessageData.fromJson(Map<String, dynamic> json) {
    return DecryptedMessageData(
      id: json['id'] as String,
      senderId: json['senderId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      contentType: MessageContentType.values.firstWhere(
        (t) => t.name == json['contentType'],
        orElse: () => MessageContentType.text,
      ),
      textContent: json['textContent'] as String?,
      binaryContent: json['binaryContent'] != null 
          ? base64Decode(json['binaryContent'] as String)
          : null,
      fileName: json['fileName'] as String?,
      mimeType: json['mimeType'] as String?,
      isCompressed: json['isCompressed'] as bool? ?? false,
      keyId: json['keyId'] as String?,
      keySegmentStart: json['keySegmentStart'] as int?,
      keySegmentEnd: json['keySegmentEnd'] as int?,
    );
  }
}

/// Service pour stocker localement les messages déchiffrés
class MessageStorage {
  static final MessageStorage _instance = MessageStorage._internal();
  factory MessageStorage() => _instance;
  MessageStorage._internal();

  static const String _messagePrefix = 'decrypted_msg_';
  final _log = AppLogger();

  // Stream controllers par conversation pour notifier l'UI
  final Map<String, StreamController<List<DecryptedMessageData>>> _controllers = {};

  Stream<List<DecryptedMessageData>> watchConversationMessages(String conversationId) {
    // Ensure internal controller exists (used to broadcast updates)
    if (!_controllers.containsKey(conversationId)) {
      _log.d('MessageStorage', 'Creating stream controller for conversation $conversationId');
      _controllers[conversationId] = StreamController<List<DecryptedMessageData>>.broadcast();
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
          // ignore add errors when subscriber is closed
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

  /// Sauvegarde un message déchiffré localement
  Future<void> saveDecryptedMessage({
    required String conversationId,
    required DecryptedMessageData message,
  }) async {
    _log.i('MessageStorage', 'Saving decrypted message ${message.id}');

    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_messagePrefix${conversationId}_${message.id}';

      // Idempotence: si le message existe déjà, on skip
      final existing = prefs.getString(key);
      if (existing != null) {
        _log.d('MessageStorage', 'Message ${message.id} already present locally — skipping save');
        // still ensure the message id is registered in the list and emit
        await _addMessageIdToConversation(conversationId, message.id);
        await _emitConversationMessages(conversationId);
        return;
      }
      await prefs.setString(key, jsonEncode(message.toJson()));
      await _addMessageIdToConversation(conversationId, message.id);
      
      // Notify listeners
      await _emitConversationMessages(conversationId);

      _log.i('MessageStorage', 'Message saved successfully');
    } catch (e) {
      _log.e('MessageStorage', 'Error saving message: $e');
      rethrow;
    }
  }

  /// Récupère un message déchiffré
  Future<DecryptedMessageData?> getDecryptedMessage({
    required String conversationId,
    required String messageId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_messagePrefix${conversationId}_$messageId';
      final data = prefs.getString(key);
      
      if (data == null) return null;
      
      return DecryptedMessageData.fromJson(jsonDecode(data));
    } catch (e) {
      _log.e('MessageStorage', 'Error getting message: $e');
      return null;
    }
  }

  /// Récupère tous les messages déchiffrés d'une conversation
  Future<List<DecryptedMessageData>> getConversationMessages(String conversationId) async {
    try {
      final messageIds = await _getMessageIdsForConversation(conversationId);
      final messages = <DecryptedMessageData>[];
      
      for (final messageId in messageIds) {
        final message = await getDecryptedMessage(
          conversationId: conversationId,
          messageId: messageId,
        );
        if (message != null) {
          messages.add(message);
        }
      }
      
      // Trier par date
      messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      
      return messages;
    } catch (e) {
      _log.e('MessageStorage', 'Error getting conversation messages: $e');
      return [];
    }
  }

  /// Récupère la date du dernier message d'une conversation
  Future<DateTime?> getLastMessageTimestamp(String conversationId) async {
    try {
      final messageIds = await _getMessageIdsForConversation(conversationId);
      if (messageIds.isEmpty) return null;
      
      // On suppose que le dernier ID ajouté est le plus récent
      final lastId = messageIds.last;
      final message = await getDecryptedMessage(
        conversationId: conversationId, 
        messageId: lastId,
      );
      
      return message?.createdAt;
    } catch (e) {
      _log.e('MessageStorage', 'Error getting last message timestamp: $e');
      return null;
    }
  }

  /// Supprime un message déchiffré
  Future<void> deleteDecryptedMessage({
    required String conversationId,
    required String messageId,
  }) async {
    _log.i('MessageStorage', 'Deleting decrypted message $messageId');

    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_messagePrefix${conversationId}_$messageId';
      
      await prefs.remove(key);
      await _removeMessageIdFromConversation(conversationId, messageId);

      // Notify listeners
      await _emitConversationMessages(conversationId);

      _log.i('MessageStorage', 'Message deleted successfully');
    } catch (e) {
      _log.e('MessageStorage', 'Error deleting message: $e');
    }
  }

  /// Supprime tous les messages d'une conversation
  Future<void> deleteConversationMessages(String conversationId) async {
    _log.i('MessageStorage', 'Deleting all messages for conversation $conversationId');

    try {
      final messageIds = await _getMessageIdsForConversation(conversationId);
      
      for (final messageId in messageIds) {
        await deleteDecryptedMessage(
          conversationId: conversationId,
          messageId: messageId,
        );
      }
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('${_messagePrefix}list_$conversationId');
      
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

  /// Ajoute un ID de message à la liste pour une conversation
  Future<void> _addMessageIdToConversation(String conversationId, String messageId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '${_messagePrefix}list_$conversationId';
    
    final existing = prefs.getStringList(key) ?? [];
    if (!existing.contains(messageId)) {
      existing.add(messageId);
      await prefs.setStringList(key, existing);
    }
  }

  /// Retire un ID de message de la liste pour une conversation
  Future<void> _removeMessageIdFromConversation(String conversationId, String messageId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '${_messagePrefix}list_$conversationId';
    
    final existing = prefs.getStringList(key) ?? [];
    existing.remove(messageId);
    await prefs.setStringList(key, existing);
  }

  /// Récupère la liste des IDs de messages pour une conversation
  Future<List<String>> _getMessageIdsForConversation(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '${_messagePrefix}list_$conversationId';
    return prefs.getStringList(key) ?? [];
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
    final messages = await getConversationMessages(convId);
    int totalSize = 0;
    for (final msg in messages) {
      if (msg.contentType == MessageContentType.text && msg.textContent != null) {
        totalSize += utf8.encode(msg.textContent!).length;
      } else if (msg.binaryContent != null) {
        totalSize += msg.binaryContent!.length;
      }
    }
    return totalSize;
  }
}
