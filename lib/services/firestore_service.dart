import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/firestore/fs_conversation.dart';
import '../models/firestore/fs_key_status.dart';
import '../models/firestore/fs_message.dart';
import 'key_pre_generation_service.dart';
import 'app_logger.dart';

/// Firebase conversation management service.
class FirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final String localUserId;
  final _log = AppLogger();

  FirestoreService({required this.localUserId});

  /// Conversations collection
  CollectionReference<Map<String, dynamic>> get _conversationsRef =>
      _firestore.collection('conversations');

  /// Messages collection for a conversation
  CollectionReference<Map<String, dynamic>> _messagesRef(String conversationId) =>
      _conversationsRef.doc(conversationId).collection('messages');

  // ==================== CONVERSATIONS ====================

  /// Creates a new conversation (in "joining" state)
  Future<Conversation> createConversation({
    required List<String> peerIds,
    ConversationState state = ConversationState.joining,
  }) async {
    _log.d('Conversation', 'createConversation: peerIds=$peerIds, state=$state');

    // Ensure local user is included
    final allPeers = {...peerIds, localUserId}.toList()..sort();
    final conversationId = _generateConversationId();
    final conversation = Conversation(
      id: conversationId,
      peerIds: allPeers,
      state: state,
    );
    await _conversationsRef.doc(conversationId).set(conversation.toFirestore());
    _log.i('Conversation', 'Conversation created: $conversationId');

    try {
      KeyPreGenerationService().initialize();
      _log.d('Conversation', 'Key pre-generation initialized for conversation $conversationId');
    } catch (e) {
      _log.w('Conversation', 'Could not initialize KeyPreGenerationService: $e');
    }

    return conversation;
  }

  /// Changes conversation state
  Future<void> setConversationState(String conversationId, ConversationState state) async {
    _log.d('Conversation', 'setConversationState: $conversationId -> $state');
    await _conversationsRef.doc(conversationId).update({
      'state': state.name,
    });
  }

  /// Sets conversation to "exchanging" mode (key exchange in progress)
  Future<void> startKeyExchange(String conversationId) async {
    await setConversationState(conversationId, ConversationState.exchanging);
  }

  /// Sets conversation to "ready" mode (ready to use)
  Future<void> markConversationReady(String conversationId, int totalKeyBytes) async {
    _log.d('Conversation', 'markConversationReady: $conversationId, totalKeyBytes=$totalKeyBytes');
    await _conversationsRef.doc(conversationId).update({
      'state': ConversationState.ready.name,
      'totalKeyBytes': totalKeyBytes,
    });
  }

  /// Gets a conversation by ID
  Future<Conversation?> getConversation(String id) async {
    final doc = await _conversationsRef.doc(id).get();
    if (!doc.exists) return null;
    return Conversation.fromFirestore(doc.data()!);
  }

  /// Gets all user conversations
  Future<List<Conversation>> getUserConversations() async {
    final query = await _conversationsRef
        .where('peerIds', arrayContains: localUserId)
        .orderBy('createdAt', descending: true)
        .get();

    return query.docs
        .map((doc) => Conversation.fromFirestore(doc.data()))
        .toList();
  }

  /// Stream of user conversations
  Stream<List<Conversation>> watchUserConversations() {
    return _conversationsRef
        .where('peerIds', arrayContains: localUserId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Conversation.fromFirestore(doc.data()))
            .toList());
  }

  /// Stream of a specific conversation
  Stream<Conversation?> watchConversation(String conversationId) {
    return _conversationsRef.doc(conversationId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return Conversation.fromFirestore(doc.data()!);
    });
  }

  /// Renames a conversation
  Future<void> renameConversation(String conversationId, String newName) async {
    // This feature is no longer supported in the model
    // await _conversationsRef.doc(conversationId).update({'name': newName});
  }

  Future<void> updateConversationKey({
    required String conversationId,
  }) async {
    _log.d('Conversation', 'updateConversationKey: $conversationId');

    await _conversationsRef.doc(conversationId).update({
      'state': ConversationState.ready.name,
    });
  }

  /// Updates key debug info for a user
  Future<void> updateKeyDebugInfo({
    required String conversationId,
    required String userId,
    required FsKeyStatus keyStatus,
  }) async {
    _log.d('Conversation', 'updateKeyDebugInfo: $conversationId, user=$userId');
    // Use dot notation to update a specific field in the map
    await _conversationsRef.doc(conversationId).update({
      'keyDebugInfo.$userId': keyStatus.toFirestore(),
    });
  }

  /// Deletes a conversation (and all its messages)
  Future<void> deleteConversation(String conversationId) async {
    _log.d('Conversation', 'deleteConversation: $conversationId');

    // Delete all messages first
    final messages = await _messagesRef(conversationId).get();
    final batch = _firestore.batch();
    for (final doc in messages.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();

    // Delete associated key exchange sessions
    final sessions = await _firestore
        .collection('key_exchange_sessions')
        .where('conversationId', isEqualTo: conversationId)
        .get();
    for (final doc in sessions.docs) {
      await doc.reference.delete();
    }

    // Delete the conversation
    await _conversationsRef.doc(conversationId).delete();

    _log.i('Conversation', 'Conversation deleted: $conversationId');
  }

  // ==================== MESSAGES ====================

  /// Sends an encrypted message
  Future<void> sendMessage({
    required String conversationId,
    required EncryptedMessage message,
    String? plaintextDebug,
  }) async {
    _log.d('Conversation', 'sendMessage: conversationId=$conversationId');
    _log.d('Conversation', 'sendMessage: messageId=${message.id}');

    try {
      // Add the message
      _log.d('Conversation', 'Adding message to Firestore...');
      final messageData = message.toFirestore();

      await _messagesRef(conversationId).doc(message.id).set(messageData);
      _log.i('Conversation', 'Message added successfully');
    } catch (e, stackTrace) {
      _log.e('Conversation', 'ERROR in sendMessage: $e');
      _log.e('Conversation', 'Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Gets messages from a conversation
  Future<List<EncryptedMessage>> getMessages({
    required String conversationId,
    int? limit,
    DateTime? before,
  }) async {
    Query<Map<String, dynamic>> query = _messagesRef(conversationId)
        .orderBy('serverTimestamp', descending: true);

    if (before != null) {
      query = query.where('serverTimestamp', isLessThan: Timestamp.fromDate(before));
    }

    if (limit != null) {
      query = query.limit(limit);
    }

    final snapshot = await query.get();
    return snapshot.docs
        .map((doc) => EncryptedMessage.fromFirestore(doc.data(), documentId: doc.id))
        .toList();
  }

  /// Stream of messages from a conversation
  Stream<List<EncryptedMessage>> watchMessages(String conversationId) {
    return _messagesRef(conversationId)
        .orderBy('serverTimestamp', descending: false)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => EncryptedMessage.fromFirestore(doc.data(), documentId: doc.id))
            .toList());
  }

  /// Adds an anonymous acknowledgment to a message
  /// The ackId is a random identifier that doesn't reveal WHO added it
  Future<void> addMessageAck({
    required String conversationId,
    required String messageId,
    required String ackId,
  }) async {
    final docRef = _messagesRef(conversationId).doc(messageId);
    final conversation = await getConversation(conversationId);

    await _firestore.runTransaction((transaction) async {
      final doc = await transaction.get(docRef);
      if (!doc.exists) return;

      final data = doc.data()!;
      final ackSet = Set<String>.from(data['ackSet'] as List? ?? []);

      if (!ackSet.contains(ackId)) {
        ackSet.add(ackId);
      }

      // Check if all participants have acknowledged (ack count >= participant count)
      final allAcked = ackSet.length >= conversation!.peerIds.length;

      if (allAcked) {
        // Delete encrypted content (keep metadata for status)
        // SECURITY: Ciphertext is only deleted if ALL participants have downloaded it
        transaction.update(docRef, {
          'ackSet': ackSet.toList(),
          'ciphertext': '', // Clear ciphertext
        });
        _log.d('Conversation', 'Message $messageId ciphertext deleted (all acked)');
      } else {
        transaction.update(docRef, {
          'ackSet': ackSet.toList(),
        });
      }
    });
  }

  /// Marks a message as read (via anonymous ack) and checks if we can delete it
  /// Adds the ackId to ackSet and deletes the message if all participants have read
  /// expectedAckCount should be peerIds.length (we count only R-prefixed read acks)
  Future<void> markMessageAsReadAndCleanup({
    required String conversationId,
    required String messageId,
    required String ackId,
    required int expectedAckCount,
  }) async {
    final docRef = _messagesRef(conversationId).doc(messageId);

    await _firestore.runTransaction((transaction) async {
      final doc = await transaction.get(docRef);
      if (!doc.exists) return;

      final data = doc.data()!;
      final ackSet = Set<String>.from(data['ackSet'] as List? ?? []);

      // Add the read ack
      if (!ackSet.contains(ackId)) {
        ackSet.add(ackId);
      }
      // go through ackSet filtering that starts with R and count
      final numberRead = ackSet.where((ack) => ack.startsWith('R')).length;
      final allRead = numberRead >= expectedAckCount;

      if (allRead) {
        // Delete message completely from Firestore
        transaction.delete(docRef);
        _log.d('Conversation', 'Message $messageId deleted (all acks received: ${ackSet.length}/$expectedAckCount)');
      } else {
        // Update ackSet
        transaction.update(docRef, {
          'ackSet': ackSet.toList(),
        });
        _log.d('Conversation', 'Message $messageId ack added (${ackSet.length}/$expectedAckCount)');
      }
    });
  }

  /// Adds a read ack and returns the current cloud status of the message
  /// This is used by MessageService to update local message status
  Future<CloudMessageStatus> addReadAckAndGetStatus({
    required String conversationId,
    required String messageId,
    required String ackId,
    required int expectedAckCount,
  }) async {
    final docRef = _messagesRef(conversationId).doc(messageId);

    return await _firestore.runTransaction<CloudMessageStatus>((transaction) async {
      final doc = await transaction.get(docRef);

      if (!doc.exists) {
        // Message already deleted from Firestore
        return CloudMessageStatus(exists: false, hasContent: false, allRead: true);
      }

      final data = doc.data()!;
      final ackSet = Set<String>.from(data['ackSet'] as List? ?? []);

      // Add the read ack if not already present (idempotent)
      if (!ackSet.contains(ackId)) {
        ackSet.add(ackId);
      }

      // Count R acks to check if all have read
      final numberRead = ackSet.where((ack) => ack.startsWith('R')).length;
      final allRead = numberRead >= expectedAckCount;

      // Check if ciphertext has content
      final ciphertextRaw = data['ciphertext'];
      final hasContent = ciphertextRaw != null &&
          ((ciphertextRaw is Blob && ciphertextRaw.bytes.isNotEmpty) ||
           (ciphertextRaw is String && ciphertextRaw.isNotEmpty));

      if (allRead) {
        // Delete message completely from Firestore
        transaction.delete(docRef);
        _log.d('Conversation', 'Message $messageId deleted (all read: $numberRead/$expectedAckCount)');
        return CloudMessageStatus(exists: false, hasContent: false, allRead: true);
      } else {
        // Update ackSet
        transaction.update(docRef, {
          'ackSet': ackSet.toList(),
        });
        _log.d('Conversation', 'Message $messageId ack added (read: $numberRead/$expectedAckCount)');
        return CloudMessageStatus(exists: true, hasContent: hasContent, allRead: false);
      }
    });
  }

  /// Deletes a message (ultra-secure mode)
  Future<void> deleteMessage(String conversationId, String messageId) async {
    await _messagesRef(conversationId).doc(messageId).delete();
  }

  // ==================== UTILITIES ====================

  String _generateConversationId() {
    return 'conv_${DateTime.now().millisecondsSinceEpoch}_$localUserId';
  }
}

/// Status of a message in the cloud (Firestore)
class CloudMessageStatus {
  /// True if the message document exists in Firestore
  final bool exists;
  /// True if the ciphertext field has content (not empty)
  final bool hasContent;
  /// True if all participants have sent their read ack (R)
  final bool allRead;

  CloudMessageStatus({
    required this.exists,
    required this.hasContent,
    required this.allRead,
  });
}

