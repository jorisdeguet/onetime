import 'package:flutter/material.dart';
import 'package:onetime/services/key_service.dart';
import 'package:onetime/services/firestore_service.dart';
import 'package:onetime/services/format_service.dart';
import 'package:onetime/services/auth_service.dart';
import 'package:onetime/services/pseudo_service.dart';

import '../models/firestore/fs_conversation.dart';

class ConversationInfoScreen extends StatefulWidget {
  final Conversation conversation;
  final VoidCallback? onDelete;
  final VoidCallback? onExtendKey;

  const ConversationInfoScreen({
    super.key,
    required this.conversation,
    this.onDelete,
    this.onExtendKey,
  });

  @override
  State<ConversationInfoScreen> createState() => _ConversationInfoScreenState();
}

class _ConversationInfoScreenState extends State<ConversationInfoScreen> {
  final PseudoService _pseudoService = PseudoService();
  final KeyService _keyService = KeyService();
  final AuthService _authService = AuthService();
  late final FirestoreService _conversationService;
  
  Map<String, String> _displayNames = {};
  bool _isLoading = false;
  late String _currentUserId;

  @override
  void initState() {
    super.initState();
    _currentUserId = _authService.currentUserId ?? '';
    _conversationService = FirestoreService(localUserId: _currentUserId);
    _loadDisplayNames();
  }

  Future<void> _loadDisplayNames() async {
    final names = await _pseudoService.getDisplayNames(widget.conversation.peerIds);
    if (mounted) {
      setState(() {
        _displayNames = names;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Infos conversation')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Infos conversation'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // En-tête avec nom de conversation
            Center(
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: Colors.orange.withAlpha(30),
                    child: Text(
                      widget.conversation.displayName.substring(0, 1).toUpperCase(),
                      style: TextStyle(
                        fontSize: 24,
                        color: Colors.orange,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    widget.conversation.displayName,
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Créée le ${FormatService.formatDate(widget.conversation.createdAt)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Participants
            Text(
              'Participants (${widget.conversation.peerIds.length})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Card(
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: widget.conversation.peerIds.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final peerId = widget.conversation.peerIds[index];
                  final pseudo = _displayNames[peerId];

                  return ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        (pseudo ?? peerId).substring(0, 1).toUpperCase(),
                      ),
                    ),
                    title: Text(pseudo ?? peerId),
                    subtitle: Text(
                      (pseudo != null ? peerId : ''),
                      style: const TextStyle(fontSize: 10),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 24),

            // Informations sur la clé
            Text(
              'Chiffrement et Sécurité',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _showDeleteConfirmation(context),
                icon: const Icon(Icons.delete_forever),
                label: const Text('Supprimer la conversation'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteConfirmation(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer la conversation ?'),
        content: const Text(
          'Cette action est irréversible. La conversation et tous ses messages seront supprimés pour tous les participants.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context); // Close dialog
              _deleteConversation();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteConversation() async {
    setState(() => _isLoading = true);
    
    try {
      await _conversationService.deleteConversation(widget.conversation.id);
      await _keyService.deleteKey(widget.conversation.id);
      if (mounted) {
        Navigator.pop(context); // Close info screen
        widget.onDelete?.call(); // Callback to close detail screen
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Conversation supprimée')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur: $e')),
        );
      }
    }
  }
}
