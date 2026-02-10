import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/message_service.dart';
import 'key_exchange_screen.dart';
import '../services/app_logger.dart';
import '../services/firestore_service.dart';
import '../services/auth_service.dart';

/// Screen for creating a new conversation.
/// 1. Creates a conversation in Firestore
/// 2. Displays a QR code with the conversation ID
/// 3. Participants scan to join
/// 4. Creator validates the list of participants
/// 5. Proceeds to key exchange
class NewConversationScreen extends StatefulWidget {
  const NewConversationScreen({super.key});

  @override
  State<NewConversationScreen> createState() => _NewConversationScreenState();
}

class _NewConversationScreenState extends State<NewConversationScreen> {
  final AuthService _authService = AuthService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final _log = AppLogger();

  String? _conversationId;
  bool _isCreating = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _createConversation();
  }

  String get _currentUserId => _authService.currentUserId ?? '';

  /// Crée la conversation et affiche le QR code
  Future<void> _createConversation() async {
    if (_currentUserId.isEmpty) {
      setState(() => _errorMessage = 'Non connecté');
      return;
    }

    setState(() {
      _isCreating = true;
      _errorMessage = null;
    });

    try {
      final conversationService = FirestoreService(localUserId: _currentUserId);
      
      // Créer la conversation avec seulement le créateur
      final conversation = await conversationService.createConversation(
        peerIds: [], // Vide pour l'instant, les autres rejoindront
      );

      setState(() {
        _conversationId = conversation.id;
        _isCreating = false;
      });

      // Initialize background service and start listening to this conversation
      try {
        final getIt = GetIt.instance;
        if (!getIt.isRegistered<MessageService>()) {
          final svc = MessageService(localUserId: _currentUserId);
          getIt.registerSingleton<MessageService>(svc);
          svc.startWatchingUserConversations();
        }
        final svc = getIt.get<MessageService>();
        svc.startForConversation(conversation.id);
        svc.rescanConversation(conversation.id).catchError((e) {
          _log.e('NewConversation', 'Background rescan failed: $e');
        });
      } catch (e) {
        _log.e('NewConversation', 'Could not init background service: $e');
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Erreur: $e';
        _isCreating = false;
      });
    }
  }

  /// Stream des participants de la conversation
  Stream<List<Map<String, String>>> _watchParticipants() {
    if (_conversationId == null) return const Stream.empty();

    return _firestore
        .collection('conversations')
        .doc(_conversationId)
        .snapshots()
        .map((doc) {
          if (!doc.exists) return <Map<String, String>>[];
          
          final data = doc.data()!;
          final peerIds = List<String>.from(data['peerIds'] as List? ?? []);

          return peerIds.map((id) => {
            'id': id,
            'name': id, // Utiliser l'ID utilisateur comme nom
          }).toList();
        });
  }

  /// Finalise la liste des participants et passe à l'échange de clé
  Future<void> _finalizeParticipants() async {
    if (_conversationId == null) return;

    try {
      // Récupérer la conversation actuelle
      final doc = await _firestore.collection('conversations').doc(_conversationId).get();
      if (!doc.exists) {
        setState(() => _errorMessage = 'Conversation non trouvée');
        return;
      }

      final data = doc.data()!;
      final peerIds = List<String>.from(data['peerIds'] as List? ?? []);

      // Allow finalizing with a single participant (the creator) — user requested solo conversations.
      if (peerIds.isEmpty) {
        setState(() => _errorMessage = 'Il faut au moins 1 participant');
        return;
      }

      // Mettre la conversation en état "exchanging" pour notifier les autres participants
      final conversationService = FirestoreService(localUserId: _currentUserId);
      await conversationService.startKeyExchange(_conversationId!);
      _log.d('NewConversation', 'Conversation state set to exchanging');

      if (mounted) {
        // Passer à l'écran d'échange de clé
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => KeyExchangeScreen(
              peerIds: peerIds,
              existingConversationId: _conversationId,
            ),
          ),
        );
      }
    } catch (e) {
      setState(() => _errorMessage = 'Erreur: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nouvelle conversation'),
      ),
      body: _isCreating
          ? const Center(child: CircularProgressIndicator())
          : _buildQrCodeView(),
    );
  }

  Widget _buildQrCodeView() {
    if (_conversationId == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_errorMessage ?? 'Erreur de création'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Retour'),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // Liste des participants (Moved above QR)
          StreamBuilder<List<Map<String, String>>>(
            stream: _watchParticipants(),
            builder: (context, snapshot) {
              final participants = snapshot.data ?? [];
              // Allow finalizing even if only the creator is present (single-participant convo)
              final canFinalize = participants.length >= 1;

              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.people, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'Participants (${participants.length})',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Spacer(),
                          // Bouton vert visible seulement si > 1 participant
                          if (canFinalize)
                            ElevatedButton.icon(
                              onPressed: _finalizeParticipants,
                              icon: const Icon(Icons.check),
                              label: const Text('Valider'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              ),
                            ),
                        ],
                      ),
                      const Divider(),
                      if (participants.isEmpty)
                        const Text(
                          'En attente de participants...',
                          style: TextStyle(color: Colors.grey),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: participants.map((p) {
                            final isMe = p['id'] == _currentUserId;
                            final shortId = p['id']!.length >= 5 
                                ? p['id']!.substring(0, 5) 
                                : p['id']!;
                            return Chip(
                              label: Text(shortId),
                              backgroundColor: isMe ? Colors.green[100] : null,
                            );
                          }).toList(),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          
          // Instructions (Updated text, removed title)
          const Text(
            'Les participants scannent ce QR code pour rejoindre la conversation',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 24),

          // QR Code au centre
          Expanded(
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(25),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: QrImageView(
                  data: _conversationId!,
                  version: QrVersions.auto,
                  size: 250,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),

          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}
