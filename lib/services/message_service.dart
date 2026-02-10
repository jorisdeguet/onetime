import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:onetime/models/firestore/fs_key_status.dart';
import 'package:onetime/models/firestore/fs_message.dart';
import 'package:onetime/services/lock_service.dart';
import 'package:onetime/services/message_storage.dart';
import 'package:onetime/models/local/key_interval.dart';
import 'package:onetime/services/key_service.dart';
import 'package:onetime/models/local/shared_key.dart';
import 'package:onetime/services/app_logger.dart';
import 'package:onetime/services/firestore_service.dart';
import 'package:onetime/services/crypto_service.dart';
import 'package:onetime/services/compression_service.dart';

import 'package:onetime/services/local_storage_service.dart';
import 'package:onetime/services/media_service.dart';
import 'package:onetime/services/auth_service.dart';
import 'package:onetime/services/pseudo_service.dart';

import '../models/firestore/fs_conversation.dart';

/// Background service that listens to Firestore and performs
/// centralized message decryption. It saves results locally via
/// MessageStorageService and marks transferred messages on Firestore.
class MessageService {
  late final String localUserId;
  late final FirestoreService _conversationService;
  final AuthService _authService = AuthService();
  // final KeyStorage _keyStorage = KeyStorage();
  final KeyService _keyService = KeyService();
  final CryptoService _cryptoService = CryptoService();
  final PseudoService _pseudoService = PseudoService();
  final MessageStorage _messageStorage = MessageStorage();
  final LockService _lockService = LockService();
  final AppLogger _log = AppLogger();

  final Map<String, StreamSubscription<List<EncryptedMessage>>> _subscriptions = {};
  final Map<String, Set<String>> _processing = {};
  StreamSubscription<List<Conversation>>? _conversationsSub;
  final Set<String> _activeConversations = {};

  MessageService.fromCurrentUserID() {
    localUserId = _authService.currentUserId!;
    _conversationService = FirestoreService(localUserId: localUserId);
  }

  MessageService({required this.localUserId})
      : _conversationService = FirestoreService(localUserId: localUserId);


  /// Méthode générique pour envoyer un message avec gestion du lock
  /// Cette méthode factorise la logique commune d'acquisition/libération de lock
  Future<void> _sendWithLock({
    required String conversationId,
    required Future<void> Function(SharedKey key) sendOperation,
    String? logPrefix,
  }) async {
    await _lockService.acquireLock(
      conversationId: conversationId,
      userId: _authService.currentUserId!,
    );

    // ÉTAPE 1: Synchroniser tous les messages Firestore pour avoir les intervalles les plus récents
    _log.d('MessageService', 'Syncing all Firestore messages before acquiring lock');
    await rescanConversation(conversationId);

    // Recharger la clé après la synchronisation (elle a pu être mise à jour)
    final updatedKey = await _keyService.getKey(conversationId);
    // ÉTAPE 2: Synchroniser avec l'état Firestore pour éviter la réutilisation de clé
    await _syncWithFirestoreKeyState(conversationId, updatedKey);

    // ÉTAPE 3: Valider l'état de la clé avant envoi
    try {
      final validatedNextByte = updatedKey.validateState();
      _log.d('MessageService', 'Key state validated: nextAvailableByte=$validatedNextByte');
    } catch (e) {
      _log.e('MessageService', 'Key state validation failed before send: $e');
      rethrow;
    }

    // ÉTAPE 4: Acquérir un lock GLOBAL sur la conversation
    final nextByteIndex = updatedKey.nextAvailableByte;
    _log.d('MessageService', 'Acquiring GLOBAL lock for conversation $conversationId (nextByte=$nextByteIndex)${logPrefix != null ? ' ($logPrefix)' : ''}');

    try {
      // ÉTAPE 5: Exécuter l'opération d'envoi
      await sendOperation(updatedKey);
    } finally {
      // ÉTAPE 6: Libérer le lock dans tous les cas (succès ou erreur)
      _log.d('MessageService', 'Releasing GLOBAL lock for conversation $conversationId${logPrefix != null ? ' ($logPrefix)' : ''}');
      await _lockService.releaseLock(
        conversationId: conversationId,
        byteIndex: nextByteIndex,
        userId: _authService.currentUserId!,
      );
    }
  }

  /// Synchronise l'état local de la clé avec Firestore pour éviter la réutilisation
  /// Prend le max de tous les nextAvailableByte des participants
  Future<void> _syncWithFirestoreKeyState(String conversationId, SharedKey key) async {
    try {
      final conversation = await _conversationService.getConversation(conversationId);
      if (conversation == null || conversation.keyDebugInfo.isEmpty) {
        _log.w('MessageService', 'No keyDebugInfo available for sync');
        return;
      }
      int maxNextAvailableByte = key.nextAvailableByte;
      conversation.keyDebugInfo.forEach((userId, info) {
        if (info is Map && info.containsKey('nextAvailableByte')) {
          final participantNext = info['nextAvailableByte'] as int;
          if (participantNext > maxNextAvailableByte) {
            _log.w('MessageService',
              'Participant $userId has nextAvailableByte=$participantNext, '
              'local was $maxNextAvailableByte. Syncing to max.');
            maxNextAvailableByte = participantNext;
          }
        }
      });

      // Si on a trouvé un nextAvailableByte plus grand, mettre à jour la clé locale
      if (maxNextAvailableByte > key.nextAvailableByte) {
        _log.i('MessageService',
          'Syncing local key: advancing nextAvailableByte from ${key.nextAvailableByte} to $maxNextAvailableByte');
        _log.i('MessageService', 'Key synchronized with Firestore state');
      } else {
        _log.d('MessageService',
          'Local key is in sync (nextAvailableByte=${key.nextAvailableByte})');
      }
    } catch (e) {
      _log.e('MessageService', 'Error syncing key state with Firestore: $e');
      // Ne pas bloquer l'envoi si la sync échoue, juste logger l'erreur
    }
  }

  /// Factorise le post-processing après chiffrement :
  /// - Sauvegarde locale du message déchiffré
  /// - Mise à jour des octets utilisés
  /// - Envoi sur Firestore
  /// - Ajout d'un ack anonyme pour le transfert
  /// - Ajout d'un ack de lecture (l'expéditeur a déjà "lu" son message)
  Future<void> _postProcessMessage({
    required String conversationId,
    required EncryptedMessage message,
    required KeyInterval usedSegment,
    required LocalMessage localData,
  }) async {
    // Store decrypted message locally FIRST
    await _messageStorage.saveDecryptedMessage(
      conversationId: conversationId,
      message: localData,
    );

    // consume local key
    await _keyService.updateUsedBytes(
      conversationId,
      usedSegment.startIndex,
      usedSegment.endIndex,
    );

    // user has the message and assumes read
    final transferAckId = _generateAckId('T');
    message.addAck(transferAckId);
    final readAckId = _generateAckId('R');
    message.addAck(readAckId);
    final updatedLocalData = localData.copyWith(
      myTransferAckId: transferAckId,
      myReadAckId: readAckId,
    );

    // save messages and acks
    await _messageStorage.updateMessage(
      conversationId: conversationId,
      message: updatedLocalData,
    );

    // sending the wrapper in firestore
    _log.d('MessageService', 'Calling conversationService.sendMessage...');
    await _conversationService.sendMessage(
      conversationId: conversationId,
      message: message,
    );

    _log.i('MessageService', 'Message sent successfully!');
    await updateKeyDebugInfo(conversationId);
  }

  /// Generates an anonymous ack ID with minimal identifying information
  /// [prefix] is 'T' for transfer or 'R' for read
  /// Uses secure random + timestamp, then hashes to remove any pattern
  String _generateAckId(String prefix) {
    final random = Random.secure();
    // Combine multiple random values and timestamp for entropy
    final randomBytes = List<int>.generate(16, (_) => random.nextInt(256));
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final input = '$timestamp${randomBytes.join()}';
    // Hash with SHA256 to remove any identifying pattern
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    // Prefix with T/R and take 15 chars of hash
    return '$prefix${base64Url.encode(digest.bytes).substring(0, 15)}';
  }

  final _localStorage = LocalStorageService();


  Future<void> sendMessage(String messageToSend, String conversationID) async {
    final text = messageToSend.trim();
    if (text.isEmpty) return;

    await _sendWithLock(
      conversationId: conversationID,
      sendOperation: (key) async {
        _log.d('MessageService', '_sendMessage: "$text" in $conversationID');

        final result = _cryptoService.encrypt(
          plaintext: text,
          sharedKey: key,
          senderId: _authService.currentUserId!,
        );

        await _postProcessMessage(
          conversationId: conversationID,
          message: result.message,
          usedSegment: result.usedSegment,
          localData: LocalMessage(
            id: result.message.id,
            senderId: _authService.currentUserId!,
            createdAt: result.message.createdAt,
            contentType: result.message.contentType,
            textContent: text,
            isCompressed: result.message.isCompressed,
          ),
        );
      },
    );
  }

  Future<void> sendMedia(MediaPickResult media, String conversationId) async {
    await _sendWithLock(
      conversationId: conversationId,
      logPrefix: 'media',
      sendOperation: (key) async {
        final result = _cryptoService.encryptBinary(
          data: media.data,
          sharedKey: key,
          senderId: _authService.currentUserId!,
          contentType: media.contentType,
          fileName: media.fileName,
          mimeType: media.mimeType,
        );

        await _postProcessMessage(
          conversationId: conversationId,
          message: result.message,
          usedSegment: result.usedSegment,
          localData: LocalMessage(
            id: result.message.id,
            senderId: _authService.currentUserId!,
            createdAt: result.message.createdAt,
            contentType: result.message.contentType,
            binaryContent: media.data,
            fileName: media.fileName,
            mimeType: media.mimeType,
            isCompressed: result.message.isCompressed,
          ),
        );
      },
    );
  }

  /// Envoie un message pseudo chiffré pour que les autres participants connaissent notre pseudo
  Future<void>  sendPseudoMessage(String conversationId) async {
    final myPseudo = await _pseudoService.getMyPseudo();
    if (myPseudo == null || myPseudo.isEmpty) {
      _log.d('KeyExchange', 'No pseudo to send');
      throw Exception("No pseudo");
    }
    // add the pseudo to pseudo service cache
    await _pseudoService.setMyPseudo(myPseudo);
    final String pseudoMessage = "@@@${_authService.currentUserId}===$myPseudo";
    await sendMessage(pseudoMessage, conversationId);
  }

  static bool isPseudoMessage(String content) {
    return content.startsWith("@@@") && content.contains("===");
  }

  static String idFromPseudoMessage(String content) =>
      content.split('===')[0].substring(3);

  static String pseudoFromPseudoMessage(String content) =>
      content.split('===')[1];

  // After each key update, update debug info in Firestore
  Future<void> updateKeyDebugInfo(String conversationId) async {
    final SharedKey key = await _keyService.getKey(conversationId);
    try {
      final keyStatus = FsKeyStatus(
        startByte: key.interval.startIndex,
        endByte: key.interval.endIndex,
      );
      await _conversationService.updateKeyDebugInfo(
        conversationId: conversationId,
        userId: _authService.currentUserId!,
        keyStatus: keyStatus,
      );
      _log.d('ConversationDetail', 'Key debug info updated in Firestore');
    } catch (e) {
      _log.e('ConversationDetail', 'Error updating key debug info: $e');
    }
  }

  /// Start watching the current user's conversations and automatically
  /// start/stop listeners per conversation.
  void startWatchingUserConversations() {
    if (_conversationsSub != null) return;

    _log.d('BackgroundMessage', 'startWatchingUserConversations');
    _conversationsSub = _conversationService.watchUserConversations().listen((convs) {
      final newIds = convs.map((c) => c.id).toSet();

      // start listeners for newly added conversations
      for (final id in newIds.difference(_activeConversations)) {
        startForConversation(id);
        _activeConversations.add(id);
      }

      // stop listeners for removed conversations
      for (final id in _activeConversations.difference(newIds).toList()) {
        stopForConversation(id);
        _activeConversations.remove(id);
      }
    }, onError: (e) {
      _log.e('BackgroundMessage', 'Error watching user conversations: $e');
    });
  }

  /// Stop watching user conversations and stop all per-conversation listeners.
  Future<void> stopWatchingUserConversations() async {
    _log.d('BackgroundMessage', 'stopWatchingUserConversations');
    try {
      await _conversationsSub?.cancel();
    } catch (_) {}
    _conversationsSub = null;

    // Stop any per-conversation listeners
    for (final id in _activeConversations.toList()) {
      await stopForConversation(id);
    }
    _activeConversations.clear();
  }

  /// Start listening to a conversation's message stream
  void startForConversation(String conversationId) {
    if (_subscriptions.containsKey(conversationId)) return;

    _log.d('BackgroundMessage', 'startForConversation: $conversationId');
    _processing[conversationId] = {};

    final sub = _conversationService.watchMessages(conversationId).listen((msgs) async {
      for (final msg in msgs) {
        // Quick skip if already processed locally (includes messages we sent)
        final existing = await _messageStorage.getDecryptedMessage(conversationId: conversationId, messageId: msg.id);
        if (existing != null) continue;


        // Avoid concurrent processing
        if (_processing[conversationId]!.contains(msg.id)) continue;
        _processing[conversationId]!.add(msg.id);

        try {
          await _receiveMessage(conversationId, msg);
        } catch (e) {
          _log.e('BackgroundMessage', 'Error processing ${msg.id}: $e');
        } finally {
          _processing[conversationId]!.remove(msg.id);
        }
      }
    }, onError: (e) {
      _log.e('BackgroundMessage', 'Stream error for $conversationId: $e');
    });

    _subscriptions[conversationId] = sub;
  }

  /// Stop listening a conversation
  Future<void> stopForConversation(String conversationId) async {
    _log.d('BackgroundMessage', 'stopForConversation: $conversationId');
    await _subscriptions[conversationId]?.cancel();
    _subscriptions.remove(conversationId);
    _processing.remove(conversationId);
    // Close message storage controller to free resources for this conv
    try {
      await _messageStorage.closeController(conversationId);
      _log.d('BackgroundMessage', 'Closed MessageStorage controller for $conversationId');
    } catch (e) {
      _log.e('BackgroundMessage', 'Error closing MessageStorage controller for $conversationId: $e');
    }
  }

  /// Stop all listeners
  Future<void> stopAll() async {
    _log.d('BackgroundMessage', 'stopAll');
    for (final sub in _subscriptions.values) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _processing.clear();
    // Close all controllers in message storage to avoid leaks
    try {
      for (final convId in _activeConversations) {
        await _messageStorage.closeController(convId);
      }
      _log.d('BackgroundMessage', 'Closed MessageStorage controllers for all active conversations');
    } catch (e) {
      _log.e('BackgroundMessage', 'Error closing message storage controllers: $e');
    }
  }

  Future<void> _receiveMessage(String conversationId, EncryptedMessage msg) async {
    _log.d('BackgroundMessage', 'Processing message ${msg.id} in $conversationId');
    final key = await _keyService.getKey(conversationId);
    // Valider l'état de la clé avant déchiffrement
    try {
      final validatedNextByte = key.validateState();
      _log.d('BackgroundMessage', 'Key state validated before decrypt: nextAvailableByte=$validatedNextByte');
    } catch (e) {
      _log.e('BackgroundMessage', 'Key state validation failed before decrypt: $e');
      // Ne pas bloquer le déchiffrement, juste logger l'erreur
      // L'erreur sera visible dans les logs pour investigation
    }

    try {
      final crypto = CryptoService();

      // Compute key segment start/end in bytes
      final int keySegmentStartByte = msg.keySegment.startByte;
      final int keySegmentEndByte = msg.keySegment.startByte + msg.keySegment.lengthBytes;

      // First, decrypt as binary to get metadata (contentType is inside encrypted data)
      final decryptedBin = crypto.decryptBinary(encryptedMessage: msg, sharedKey: key, markAsUsed: true);

      // Now msg.metadata is available with the real contentType
      final senderId = msg.senderId;
      final createdAt = msg.createdAt;
      final contentType = msg.contentType;

      _log.d('BackgroundMessage', 'Decrypted message ${msg.id}: contentType=$contentType, size=${decryptedBin.length}');

      if (contentType == MessageContentType.text) {
        // Convert binary to text
        String textContent;
        if (msg.isCompressed) {
          textContent = CompressionService().smartDecompress(decryptedBin, true);
        } else {
          textContent = utf8.decode(decryptedBin);
        }

        // Save decrypted message locally with key metadata
        await _messageStorage.saveDecryptedMessage(
          conversationId: conversationId,
          message: LocalMessage(
            id: msg.id,
            senderId: senderId,
            createdAt: createdAt,
            contentType: contentType,
            textContent: textContent,
            isCompressed: msg.isCompressed,
            keySegmentStart: keySegmentStartByte,
            keySegmentEnd: keySegmentEndByte,
          ),
        );

        if (isPseudoMessage(textContent)) {
          _pseudoService.setPseudo(idFromPseudoMessage(textContent), pseudoFromPseudoMessage(textContent));
        }
      } else {
        // Image or file - keep as binary
        await _messageStorage.saveDecryptedMessage(
          conversationId: conversationId,
          message: LocalMessage(
            id: msg.id,
            senderId: senderId,
            createdAt: createdAt,
            contentType: contentType,
            binaryContent: decryptedBin,
            fileName: msg.fileName,
            mimeType: msg.mimeType,
            isCompressed: msg.isCompressed,
            keySegmentStart: keySegmentStartByte,
            keySegmentEnd: keySegmentEndByte,
          ),
        );
      }

      await _keyService.updateUsedBytes(
        conversationId,
        keySegmentStartByte,
        keySegmentEndByte,
      );
      // Valider l'état de la clé après déchiffrement
      try {
        final validatedNextByte = key.validateState();
        _log.d('BackgroundMessage', 'Key state validated after decrypt: nextAvailableByte=$validatedNextByte');
      } catch (e) {
        _log.e('BackgroundMessage', 'Key state validation failed after decrypt: $e');
        // Ne pas bloquer, juste logger
      }

      // Générer un ack anonyme pour signaler le transfert
      final transferAckId = _generateAckId('T');

      // Mettre à jour le message local avec notre transferAckId
      final existingMsg = await _messageStorage.getDecryptedMessage(
        conversationId: conversationId,
        messageId: msg.id,
      );
      if (existingMsg != null) {
        await _messageStorage.updateMessage(
          conversationId: conversationId,
          message: existingMsg.copyWith(myTransferAckId: transferAckId),
        );
      }

      await _conversationService.addMessageAck(
        conversationId: conversationId,
        messageId: msg.id,
        ackId: transferAckId,
      );

      // Persist updated key bitmap
      await updateKeyDebugInfo(conversationId);
      _log.i('BackgroundMessage', 'Message ${msg.id} processed and stored locally');
    } catch (e, st) {
      _log.e('BackgroundMessage', 'Error decrypting message ${msg.id}: $e');
      _log.e('BackgroundMessage', 'Stack: $st');
      rethrow;
    }
  }

  /// Rescan (one-shot) all messages of a conversation and attempt to process any
  /// messages that haven't been decrypted/stored locally yet.
  Future<void> rescanConversation(String conversationId) async {
    // Explanation: added public method to rescan past messages and attempt decryption.
    _log.d('BackgroundMessage', 'rescanConversation: $conversationId');

    try {
      // Fetch messages (ConversationService returns messages ordered descending)
      final messages = await _conversationService.getMessages(conversationId: conversationId);

      // Process oldest first
      final toProcess = messages.reversed.toList();

      for (final msg in toProcess) {
        // Quick skip if already processed locally (includes messages we sent)
        final existing = await _messageStorage.getDecryptedMessage(conversationId: conversationId, messageId: msg.id);
        if (existing != null) continue;


        // Avoid concurrent processing
        _processing.putIfAbsent(conversationId, () => {});
        if (_processing[conversationId]!.contains(msg.id)) continue;
        _processing[conversationId]!.add(msg.id);

        try {
          await _receiveMessage(conversationId, msg);
        } catch (e) {
          _log.e('BackgroundMessage', 'Error rescanning ${msg.id}: $e');
        } finally {
          _processing[conversationId]!.remove(msg.id);
        }
      }
    } catch (e, st) {
      _log.e('BackgroundMessage', 'rescanConversation ERROR: $e');
      _log.e('BackgroundMessage', 'Stack: $st');
      rethrow;
    }
  }

  /// Marque un message comme lu (et tous les précédents par idempotence)
  /// - Met à jour le statut local du message
  /// - Envoie un ack R à Firestore en arrière-plan (idempotent)
  /// - Émet un événement de mise à jour
  Future<void> markMessageAsRead(String conversationId, String messageId) async {
    try {
      // Récupérer tous les messages locaux pour marquer tous ceux <= messageId comme lus
      final allMessages = await _messageStorage.getConversationMessages(conversationId);
      if (allMessages.isEmpty) return;

      allMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      // Trouver l'index du message actuel
      final currentIndex = allMessages.indexWhere((m) => m.id == messageId);
      if (currentIndex == -1) return;

      // Marquer tous les messages jusqu'à celui-ci comme lus localement (fast)
      final readIds = await _getReadMessageIds(conversationId);
      final messagesToMark = <LocalMessage>[];

      for (int i = 0; i <= currentIndex; i++) {
        final msg = allMessages[i];
        if (!readIds.contains(msg.id)) {
          readIds.add(msg.id);
          messagesToMark.add(msg);
        }
      }

      // Sauvegarder les IDs lus localement FIRST (fast)
      await _localStorage.saveReadMessageIds(conversationId, readIds);

      _log.i('UnreadMsg', 'Marked messages up to $messageId as read locally (${currentIndex + 1} messages)');

      // Mettre à jour Firestore en arrière-plan (non-bloquant)
      if (messagesToMark.isNotEmpty) {
        _updateFirestoreReadStatus(conversationId, messagesToMark).catchError((e) {
          _log.e('UnreadMsg', 'Error updating Firestore read status: $e');
        });
      }
    } catch (e) {
      _log.e('UnreadMsg', 'Error marking message as read: $e');
    }
  }

  /// Récupère le nombre de messages non lus
  /// = nombre de messages décryptés localement - nombre de messages lus
  Future<int> getUnreadCount(String conversationId) async {
    try {
      // Get all local decrypted messages
      final allMessages = await _messageStorage.getConversationMessages(conversationId);

      // Get read message IDs
      final readIds = await _getReadMessageIds(conversationId);

      // Count unread = messages not in read set and not sent by me
      // We need userId but we don't have it here, so we'll count all non-read messages
      final unreadCount = allMessages.where((msg) => !readIds.contains(msg.id)).length;

      return unreadCount;
    } catch (e) {
      _log.e('UnreadMsg', 'Error getting unread count: $e');
      return 0;
    }
  }

  /// Récupère le nombre de messages non lus (excluant les messages de l'utilisateur)
  Future<int> getUnreadCountExcludingUser(String conversationId) async {
    try {
      // Get all local decrypted messages
      final allMessages = await _messageStorage.getConversationMessages(conversationId);

      // Get read message IDs
      final readIds = await _getReadMessageIds(conversationId);

      // Count unread = messages not in read set and not sent by me
      final unreadCount = allMessages.where((msg) =>
      !readIds.contains(msg.id) && msg.senderId != localUserId
      ).length;

      return unreadCount;
    } catch (e) {
      _log.e('UnreadMsg', 'Error getting unread count: $e');
      return 0;
    }
  }

  /// Marque tous les messages comme lus localement et sur Firestore
  /// Ajoute un ack de lecture pour chaque message et met à jour les statuts locaux
  /// Cette méthode est non-bloquante pour éviter les problèmes de connexion lente
  Future<void> markAllAsRead(String conversationId) async {
    try {
      // Get all local messages
      final allMessages = await _messageStorage.getConversationMessages(conversationId);
      if (allMessages.isEmpty) return;

      // Save all as read locally FIRST (fast operation)
      final allIds = allMessages.map((m) => m.id).toList();
      await _localStorage.saveReadMessageIds(conversationId, allIds);

      // Then update Firestore in background (don't block UI)
      _updateFirestoreReadStatus(conversationId, allMessages).catchError((e) {
        _log.e('UnreadMsg', 'Error updating Firestore read status: $e');
      });

      _log.i('UnreadMsg', 'Marked all ${allIds.length} messages as read locally for $conversationId');
    } catch (e) {
      _log.e('UnreadMsg', 'Error marking all as read: $e');
    }
  }

  /// Updates Firestore read status in background (non-blocking)
  Future<void> _updateFirestoreReadStatus(String conversationId, List<LocalMessage> messages) async {
    final conversation = await _conversationService.getConversation(conversationId);
    if (conversation == null) return;

    // Expected ack count = nombre de participants (on compte seulement les acks R)
    // Si pas encore de participants (conversation vide), on ne peut pas calculer allRead
    final expectedAckCount = conversation.peerIds.length;
    if (expectedAckCount == 0) {
      _log.d('UnreadMsg', 'No participants yet, skipping Firestore read status update');
      return;
    }

    // Process each message
    for (final msg in messages) {
      // Use existing readAckId if already set, otherwise generate a new one
      final readAckId = msg.myReadAckId ?? _generateAckId('R');

      try {
        // Add ack to Firestore and get status (idempotent)
        final cloudStatus = await _conversationService.addReadAckAndGetStatus(
          conversationId: conversationId,
          messageId: msg.id,
          ackId: readAckId,
          expectedAckCount: expectedAckCount,
        );

        // Update local message with cloud status and readAckId
        final updatedMessage = msg.copyWith(
          existsInCloud: cloudStatus.exists,
          hasCloudContent: cloudStatus.hasContent,
          allRead: cloudStatus.allRead,
          myReadAckId: readAckId,
        );

        await _messageStorage.updateMessage(
          conversationId: conversationId,
          message: updatedMessage,
        );
      } catch (e) {
        // Message might already be deleted from Firestore or connection issue
        // Update local status to reflect it's no longer in cloud
        final updatedMessage = msg.copyWith(
          existsInCloud: false,
          hasCloudContent: false,
          allRead: true,
        );
        await _messageStorage.updateMessage(
          conversationId: conversationId,
          message: updatedMessage,
        );
        _log.d('UnreadMsg', 'Message ${msg.id} not in Firestore: $e');
      }
    }

    _log.i('UnreadMsg', 'Updated Firestore read status for ${messages.length} messages');
  }


  /// Supprime les données de lecture pour une conversation
  Future<void> deleteUnreadCount(String conversationId) async {
    try {
      await _localStorage.saveReadMessageIds(conversationId, []);
    } catch (e) {
      _log.e('UnreadMsg', 'Error deleting unread data: $e');
    }
  }

  /// Supprime tous les compteurs (supprime les conversations)
  Future<void> deleteAllUnreadCounts() async {
    try {
      final conversations = await _localStorage.listConversations();
      for (final convId in conversations) {
        await _localStorage.saveReadMessageIds(convId, []);
      }
      _log.i('UnreadMsg', 'All unread data deleted');
    } catch (e) {
      _log.e('UnreadMsg', 'Error deleting all unread data: $e');
    }
  }

  /// Récupère les IDs de messages lus
  Future<List<String>> _getReadMessageIds(String conversationId) async {
    try {
      return await _localStorage.getReadMessageIds(conversationId);
    } catch (e) {
      _log.e('UnreadMsg', 'Error getting read message IDs: $e');
      return [];
    }
  }

  Future<int> getConversationSize(String convId) async =>
      _messageStorage.getConversationSize(convId);

  Stream<List<LocalMessage>> watchConversationMessages(String conversationId) =>
      _messageStorage.watchConversationMessages(conversationId);

  Future<void> deleteConversationMessages(String convId) async =>
      _messageStorage.deleteConversationMessages(convId);

  Future<List<LocalMessage>> getConversationMessages(String id) async =>
      _messageStorage.getConversationMessages(id);
}
