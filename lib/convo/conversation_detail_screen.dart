import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:onetime/convo/conversation_info_screen.dart';
import 'package:onetime/convo/encrypted_message.dart';
import 'package:onetime/convo/lock_service.dart';
import 'package:onetime/convo/message_service.dart';
import 'package:onetime/convo/message_storage.dart';
import 'package:onetime/key_exchange/key_exchange_screen.dart';
import 'package:onetime/l10n/app_localizations.dart';
import 'package:onetime/services/firestore_service.dart';
import 'package:onetime/services/media_service.dart';
import 'package:onetime/signin/auth_service.dart';
import 'package:onetime/signin/pseudo_service.dart';

import '../services/app_logger.dart';
import 'conversation.dart';
import 'media_send_screen.dart';

/// Wrapper pour afficher un message local déchiffré
class _DisplayMessage {
  final String id;
  final String senderId;
  final DateTime createdAt;
  final MessageContentType contentType;

  // Données locales déchiffrées
  final String? textContent;
  final Uint8List? binaryContent;
  final String? fileName;
  final String? mimeType;

  final bool isCompressed;

  _DisplayMessage({
    required this.id,
    required this.senderId,
    required this.createdAt,
    required this.contentType,
    this.textContent,
    this.binaryContent,
    this.fileName,
    this.mimeType,
    this.isCompressed = false,
  });

  /// Crée depuis un message local déchiffré
  factory _DisplayMessage.fromLocal(DecryptedMessageData local) {
    return _DisplayMessage(
      id: local.id,
      senderId: local.senderId,
      createdAt: local.createdAt,
      contentType: local.contentType,
      textContent: local.textContent,
      binaryContent: local.binaryContent,
      fileName: local.fileName,
      mimeType: local.mimeType,
      isCompressed: local.isCompressed,
    );
  }
}

/// Écran de détail d'une conversation (chat).
class ConversationDetailScreen extends StatefulWidget {
  final Conversation conversation;

  const ConversationDetailScreen({
    super.key,
    required this.conversation,
  });

  @override
  State<ConversationDetailScreen> createState() => _ConversationDetailScreenState();
}

class _ConversationDetailScreenState extends State<ConversationDetailScreen> {
  final AuthService _authService = AuthService();
  final AppLogger _log = AppLogger();
  final MediaService _mediaService = MediaService();
  final PseudoService _pseudoService = PseudoService();
  final MessageService _messageService = MessageService.fromCurrentUserID();
  late final FirestoreService _conversationService;
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();

  bool _isLoading = false;
  bool _hasSentPseudo = false;
  bool _showScrollToBottom = false;
  // Cache des pseudos pour affichage
  Map<String, String> _displayNames = {};

  StreamSubscription<String>? _pseudoSubscription;

  @override
  void initState() {
    super.initState();
    final userId = _authService.currentUserId ?? '';
    _conversationService = FirestoreService(localUserId: userId);
    _loadDisplayNames();
    _checkIfPseudoSent().whenComplete(() {
      // _loadSharedKey();
    });

    // Listen for pseudo updates
    _pseudoSubscription = _pseudoService.pseudoUpdates.listen((conversationId) {
      if (conversationId == widget.conversation.id) {
        _loadDisplayNames();
      }
    });
    _messageService.markAllAsRead(widget.conversation.id);
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scrollController.hasClients) {
      final isAtBottom = _scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 100;
      if (isAtBottom && _showScrollToBottom) {
        setState(() => _showScrollToBottom = false);
      }
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      setState(() => _showScrollToBottom = false);
    }
  }

  /// Check if user has already sent their pseudo in this conversation
  Future<void> _checkIfPseudoSent() async {
    final messages = await _messageService.getConversationMessages(widget.conversation.id);

    // Check if any message from current user is a pseudo message
    for (final msg in messages) {
      if (msg.senderId == _currentUserId && msg.textContent != null) {
        if (MessageService.isPseudoMessage(msg.textContent!)) {
          if (mounted) {
            setState(() {
              _hasSentPseudo = true;
            });
          }
          return;
        }
      }
    }
  }

  Future<void> _loadDisplayNames() async {
    _displayNames = await _pseudoService.getDisplayNames(widget.conversation.peerIds);
    if (mounted) {
      setState(() {
        //_displayNames = names;
      });
    }
  }

  Stream<List<_DisplayMessage>> _getCombinedMessagesStream() async* {
    try {
      await for (final localMessages in _messageService.watchConversationMessages(widget.conversation.id)) {
        final combined = <_DisplayMessage>[];
        for (final local in localMessages) {
          combined.add(_DisplayMessage.fromLocal(local));
        }
        combined.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        yield combined;
      }
    } catch (e) {
      _log.e('ConversationDetail', 'ERROR in _getCombinedMessagesStream: $e');
      yield [];
    }
  }



  @override
  void dispose() {
    _pseudoSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Handles when the conversation is deleted from Firestore
  Future<void> _handleConversationDeleted(BuildContext context) async {
    if (!mounted) return;
    // Check if user initiated the deletion (if they're not in the conversation anymore)
    final conversationExists = await _conversationService.getConversation(widget.conversation.id);
    if (conversationExists != null) return; // Conversation still exists, false alarm

    // Show dialog asking if user wants to delete locally stored messages
    final shouldDeleteLocal = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Conversation supprimée'),
        content: const Text(
          'Cette conversation a été supprimée par un autre participant.\n\n' // TODO i18n
              'Voulez-vous également supprimer les messages déchiffrés stockés localement ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Conserver les messages'), // TODO i18n
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Supprimer'), // TODO i18n
          ),
        ],
      ),
    );

    if (shouldDeleteLocal == true) {
      await _messageService.deleteConversationMessages(widget.conversation.id);
    }

    if (mounted) {
      Navigator.of(context).pop(); // Return to home screen
    }
  }

  String get _currentUserId => _authService.currentUserId ?? '';

  Future<void> _sendMyPseudo() async {
    setState(() => _isLoading = true);
    try {
      final myPseudo = await PseudoService().getMyPseudo();
      if (myPseudo == null || myPseudo.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Veuillez définir votre pseudo dans les paramètres')),
          );
        }
        return;
      }

      await _messageService.sendPseudoMessage(widget.conversation.id);



      // Update state to show message input
      if (mounted) {
        setState(() {
          _hasSentPseudo = true;
        });
      }

      _log.i('ConversationDetail', 'Pseudo message sent successfully');
    } catch (e, stackTrace) {
      _log.e('ConversationDetail', 'ERROR sending pseudo: $e');
      _log.e('ConversationDetail', 'Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    _log.d('ConversationDetail', '_sendMessage: "$text"');
    _log.d('ConversationDetail', 'conversationId: ${widget.conversation.id}');
    if (text.isEmpty) return;
    setState(() => _isLoading = true);
    try{
      await _messageService.sendMessage(text, widget.conversation.id);

      _messageController.clear();
      setState(() => _isLoading = false);
      // Scroll to bottom after sending
      if (mounted) {
        // Petit délai pour laisser le temps à l'UI de se mettre à jour
        Future.delayed(const Duration(milliseconds: 10), () {
          if (mounted) _scrollToBottom();
        });
      }
    } on LockAcquisitionException catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch(e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erreur lors de l\'envoi: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }


  /// Affiche le menu d'attachement (image/fichier)
  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Galerie'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Appareil photo'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('Fichier'),
              onTap: () {
                Navigator.pop(context);
                _pickFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Sélectionne et envoie une image
  Future<void> _pickImage(ImageSource source) async {
    // Afficher un indicateur de chargement pendant le traitement de l'image
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Traitement de l\'image...'),
              ],
            ),
          ),
        ),
      ),
    );

    final result = await _mediaService.pickImage(
      source: source,
      quality: ImageQuality.medium,
    );
    // Fermer l'indicateur de chargement
    if (mounted) Navigator.of(context).pop();
    if (result == null) return;
    if (!mounted) return;
    // Naviguer vers l'écran complet d'envoi
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => MediaSendScreen(
          mediaResult: result,
          conversationId: widget.conversation.id,
          currentUserId: _currentUserId,
        ),
      ),
    );

  }

  /// Sélectionne et envoie un fichier
  Future<void> _pickFile() async {
    // Afficher un indicateur de chargement pendant le traitement du fichier
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Traitement du fichier...'),
              ],
            ),
          ),
        ),
      ),
    );

    final result = await _mediaService.pickFile();

    // Fermer l'indicateur de chargement
    if (mounted) Navigator.of(context).pop();

    if (result == null) return;

    if (!mounted) return;

    // Naviguer vers l'écran complet d'envoi
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => MediaSendScreen(
          mediaResult: result,
          conversationId: widget.conversation.id,
          currentUserId: _currentUserId,
        ),
      ),
    );
  }

  void _startKeyExchange() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => KeyExchangeScreen(
          peerIds: widget.conversation.peerIds,
          existingConversationId: widget.conversation.id,
        ),
      ),
    );
  }

  String _getParticipantPseudos() {
    final pseudos = widget.conversation.peerIds
        .where((id) => id != _currentUserId) // Filter out current user
        .map((id) => _displayNames[id] ?? id.substring(0, 8))
        .toList();

    if (pseudos.isEmpty) {
      return widget.conversation.displayName;
    }

    return pseudos.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Conversation?>(
      stream: _conversationService.watchConversation(widget.conversation.id),
      initialData: widget.conversation,
      builder: (context, snapshot) {
        if (snapshot.data == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _handleConversationDeleted(context);
          });
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final conversation = snapshot.data!;
        return _buildConversationScreen(context, conversation);
      },
    );
  }

  Widget _buildConversationScreen(BuildContext context, Conversation conversation) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: () => _showConversationInfo(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _getParticipantPseudos(),
                style: const TextStyle(fontSize: 16),
              ),
              Row(
                children: [
                  // Nombre de participants
                  Icon(
                    Icons.people,
                    size: 12,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${widget.conversation.peerIds.length}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                  const SizedBox(width: 12),
                  // Status de la clé
                  Icon(
                    Icons.lock,
                    size: 12,
                    color: Colors.green,
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          if (_hasKeyConsistencyIssue())
            IconButton(
              icon: const Icon(Icons.broken_image, color: Colors.red),
              tooltip: 'Incohérence de clé détectée',
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Attention: Les clés des participants semblent désynchronisées.'),
                    backgroundColor: Colors.red,
                  ),
                );
              },
            ),

          IconButton(
            icon: const Icon(Icons.key),
            tooltip: 'Créer / étendre une clé',
            onPressed: _startKeyExchange,
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showConversationInfo(context),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // Liste des messages
              Expanded(
                child: StreamBuilder<List<_DisplayMessage>>(
                  stream: _getCombinedMessagesStream(),
                  builder: (context, snapshot) {
                    // Show loading only if no data yet
                    if (snapshot.data == null) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final messages = snapshot.data ?? [];

                    // Don't filter pseudo messages - show them in the thread
                    final visibleMessages = messages;

                    if (visibleMessages.isEmpty) {
                      return const Center(
                        child: Text(
                          'Aucun message\nEnvoyez le premier!',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      );
                    }

                    // Auto-scroll on initial load or new message if already at bottom
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_scrollController.hasClients) {
                        final maxScroll = _scrollController.position.maxScrollExtent;
                        final currentScroll = _scrollController.position.pixels;
                        final isAtBottom = maxScroll - currentScroll < 100;

                        if (isAtBottom) {
                          _scrollController.jumpTo(maxScroll);
                        } else {
                          // New message arrived while scrolled up
                          // Verify if it is really a new message by checking length or last id
                          // For now, simple logic: if not at bottom, show button
                          setState(() => _showScrollToBottom = true);
                        }
                      }
                    });

                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: visibleMessages.length,
                      itemBuilder: (context, index) {
                        final message = visibleMessages[index];
                        final isMine = message.senderId == _currentUserId;
                        final senderName = _displayNames[message.senderId] ?? message.senderId;

                        return _MessageBubbleNew(
                          message: message,
                          isMine: isMine,
                          senderName: senderName,
                          onMessageRead: (messageId) async {
                            // Mark as read and potentially delete
                            await _conversationService.markMessageAsReadAndCleanup(
                              conversationId: widget.conversation.id,
                              messageId: messageId,
                              allParticipants: widget.conversation.peerIds,
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),

              // Barre de saisie ou bouton pseudo
              if (!_hasSentPseudo)
              // Show "Send my pseudo" button
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(20),
                        blurRadius: 4,
                        offset: const Offset(0, -2),
                      ),
                    ],
                  ),
                  child: SafeArea(
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isLoading ? null : _sendMyPseudo,
                        icon: _isLoading
                            ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                            : const Icon(Icons.person_add),
                        label: const Text('👋 Envoyer mon pseudo'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.all(16),
                          backgroundColor: Theme.of(context).primaryColor,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ),
                )
              else
              // Show message input
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(20),
                        blurRadius: 4,
                        offset: const Offset(0, -2),
                      ),
                    ],
                  ),
                  child: SafeArea(
                    child: Row(
                      children: [
                        // Bouton d'attachement (image/fichier)
                        IconButton(
                          onPressed: _isLoading ? null : _showAttachmentMenu,
                          icon: const Icon(Icons.attach_file),
                          tooltip: 'Envoyer image/fichier',
                        ),
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            decoration: InputDecoration(
                              hintText: AppLocalizations.of(context).get('conversation_type_message'),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                            ),
                            maxLines: null,
                            keyboardType: TextInputType.text,
                            enableIMEPersonalizedLearning: false,
                            enableSuggestions: false,
                            autocorrect: false,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _sendMessage(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FloatingActionButton.small(
                          onPressed: _isLoading ? null : _sendMessage,
                          child: _isLoading
                              ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                              : const Icon(Icons.send),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),

          // Bouton Scroll To Bottom
          if (_showScrollToBottom)
            Positioned(
              bottom: 80,
              right: 16,
              child: FloatingActionButton.small(
                onPressed: _scrollToBottom,
                backgroundColor: Theme.of(context).primaryColor,
                child: const Icon(Icons.arrow_downward, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  bool _hasKeyConsistencyIssue() {
    if (widget.conversation.keyDebugInfo.isEmpty) return false;
    String? referenceHash;
    bool hasMismatch = false;

    widget.conversation.keyDebugInfo.forEach((userId, info) {
      if (info is Map<String, dynamic> && info.containsKey('consistencyHash')) {
        final hash = info['consistencyHash'] as String;
        if (referenceHash == null) {
          referenceHash = hash;
        } else if (referenceHash != hash) {
          hasMismatch = true;
        }
      }
    });

    return hasMismatch;
  }

  void _showConversationInfo(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ConversationInfoScreen(
          conversation: widget.conversation,
          onDelete: () {
            Navigator.pop(context); // Close detail screen
          },
          onExtendKey: _startKeyExchange,
        ),
      ),
    );
  }

}


/// Adapter widget to display either a local decrypted message (_DisplayMessage)
/// or wrap the encrypted `_MessageBubble` when the message is from Firestore.
class _MessageBubbleNew extends StatelessWidget {
  final _DisplayMessage message;
  final bool isMine;
  final String? senderName;
  final Future<void> Function(String messageId)? onMessageRead;

  const _MessageBubbleNew({
    required this.message,
    required this.isMine,
    this.senderName,
    this.onMessageRead,
  });

  @override
  Widget build(BuildContext context) {
    // If the message is stored locally (decrypted), present it directly.

    if (message.contentType == MessageContentType.text) {
      // If the local text is a pseudo exchange message, show a concise UI
      if (message.textContent != null && MessageService.isPseudoMessage(message.textContent!)) {
        final pseudo = MessageService.pseudoFromPseudoMessage(message.textContent!);
        final pseudoName = pseudo;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Row(
            mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              if (!isMine) CircleAvatar(radius: 14, child: Text((senderName ?? '').substring(0,1))),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isMine ? Theme.of(context).colorScheme.primaryContainer : Colors.grey[200],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 16),
                    const SizedBox(width: 6),
                    Text(' $pseudoName', style: TextStyle(color: isMine ? Theme.of(context).colorScheme.onPrimaryContainer : Colors.black87, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
        );
      }

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: Row(
          mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            if (!isMine)
              CircleAvatar(radius: 14, child: Text(senderName?.substring(0,1) ?? '')),
            const SizedBox(width: 8),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isMine ? Theme.of(context).colorScheme.primaryContainer : Colors.grey[200],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  message.textContent ?? '',
                  style: TextStyle(
                    color: isMine ? Theme.of(context).colorScheme.onPrimaryContainer : Colors.black87,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Binary local message (image/file)
    if (message.contentType == MessageContentType.image && message.binaryContent != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: Row(
          mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            if (!isMine)
              CircleAvatar(radius: 14, child: Text((senderName ?? '').substring(0, 1))),
            const SizedBox(width: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(message.binaryContent!, width: 180, fit: BoxFit.cover),
            ),
          ],
        ),
      );
    }

    // Fallback simple view for other local messages
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Text(message.textContent ?? ''),
    );

  }
}
