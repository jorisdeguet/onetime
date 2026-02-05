import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../key_exchange/key_exchange_screen.dart';
import '../services/app_logger.dart';
import '../signin/auth_service.dart';

/// Écran pour rejoindre une conversation existante via QR code.
/// Le participant scanne le QR code affiché par le créateur.
class JoinConversationScreen extends StatefulWidget {
  const JoinConversationScreen({super.key});

  @override
  State<JoinConversationScreen> createState() => _JoinConversationScreenState();
}

class _JoinConversationScreenState extends State<JoinConversationScreen> {
  final AuthService _authService = AuthService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final _log = AppLogger();

  String? _scannedConversationId;
  bool _isJoining = false;
  bool _isNavigating = false; // Protection contre les navigations multiples
  String? _errorMessage;

  String get _currentUserId => _authService.currentUserId ?? '';

  /// Appelé quand un QR code est scanné
  Future<void> _onQrScanned(String conversationId) async {
    if (_isJoining || _scannedConversationId != null) return;
    
    setState(() {
      _scannedConversationId = conversationId;
      _isJoining = true;
      _errorMessage = null;
    });

    try {
      // Vérifier que la conversation existe
      final doc = await _firestore.collection('conversations').doc(conversationId).get();
      
      if (!doc.exists) {
        setState(() {
          _errorMessage = 'Conversation non trouvée';
          _isJoining = false;
          _scannedConversationId = null;
        });
        return;
      }

      final data = doc.data()!;
      final peerIds = List<String>.from(data['peerIds'] as List? ?? []);

      // Ajouter cet utilisateur à la conversation
      if (!peerIds.contains(_currentUserId)) {
        peerIds.add(_currentUserId);

        await _firestore.collection('conversations').doc(conversationId).update({
          'peerIds': peerIds,
        });
      }

      setState(() => _isJoining = false);

    } catch (e) {
      setState(() {
        _errorMessage = 'Erreur: $e';
        _isJoining = false;
        _scannedConversationId = null;
      });
    }
  }

  /// Stream des participants de la conversation
  Stream<List<Map<String, String>>> _watchParticipants() {
    if (_scannedConversationId == null) return const Stream.empty();

    return _firestore
        .collection('conversations')
        .doc(_scannedConversationId)
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

  /// Vérifie si le créateur a validé (l'état de la conversation change vers "exchanging")
  Stream<String?> _watchConversationState() {
    if (_scannedConversationId == null) {
      _log.d('JoinConversation', '_watchConversationState: conversationId is null');
      return const Stream.empty();
    }

    _log.d('JoinConversation', '_watchConversationState: watching conversation $_scannedConversationId');

    return _firestore
        .collection('conversations')
        .doc(_scannedConversationId)
        .snapshots()
        .map((doc) {
          if (!doc.exists) return null;

          final data = doc.data()!;
          final state = data['state'] as String? ?? 'joining';
          _log.d('JoinConversation', 'Conversation state: $state');

          // Si l'état est "exchanging" ou "ready", naviguer vers l'échange de clé
          if (state == 'exchanging') {
            return 'exchanging';
          }
          return null;
        });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_scannedConversationId == null ? 'Rejoindre' : 'En attente'),
      ),
      body: _scannedConversationId == null
          ? _buildScannerView()
          : _buildWaitingView(),
    );
  }

  Widget _buildScannerView() {
    return Column(
      children: [
        // Instructions
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.blue[50],
          child: Row(
            children: [
              Icon(Icons.info_outline, color: Colors.blue[700]),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Scannez le QR code affiché par le créateur de la conversation',
                  style: TextStyle(color: Colors.blue[700]),
                ),
              ),
            ],
          ),
        ),

        // Scanner
        Expanded(
          child: MobileScanner(
            onDetect: (capture) {
              final barcodes = capture.barcodes;
              if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                _onQrScanned(barcodes.first.rawValue!);
              }
            },
          ),
        ),

        if (_errorMessage != null)
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.red[100],
            child: Row(
              children: [
                Icon(Icons.error_outline, color: Colors.red[700]),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _errorMessage!,
                    style: TextStyle(color: Colors.red[700]),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _errorMessage = null),
                  child: const Text('OK'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildWaitingView() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // Indicateur de statut
          Card(
            color: Colors.green[50],
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green[700]),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Vous avez rejoint la conversation!',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.green[700],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'En attente que le créateur valide les participants...',
                          style: TextStyle(
                            color: Colors.green[600],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Liste des participants
          StreamBuilder<List<Map<String, String>>>(
            stream: _watchParticipants(),
            builder: (context, snapshot) {
              final participants = snapshot.data ?? [];
              
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
                        ],
                      ),
                      const Divider(),
                      if (participants.isEmpty)
                        const Text(
                          'Chargement...',
                          style: TextStyle(color: Colors.grey),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: participants.map((p) {
                            final isMe = p['id'] == _currentUserId;
                            return Chip(
                              avatar: CircleAvatar(
                                backgroundColor: isMe ? Colors.green : Colors.grey[300],
                                child: Text(
                                  p['name']![0].toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isMe ? Colors.white : Colors.black,
                                  ),
                                ),
                              ),
                              label: Text(isMe ? '${p['name']} (vous)' : p['name']!),
                              backgroundColor: isMe ? Colors.green[50] : null,
                            );
                          }).toList(),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          const Spacer(),

          // Indicateur de chargement
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            'Le créateur doit valider la liste des participants\npuis l\'échange de clé commencera',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),

          // Écouter le changement d'état de la conversation
          StreamBuilder<String?>(
            stream: _watchConversationState(),
            builder: (context, snapshot) {
              final state = snapshot.data;
              _log.d('JoinConversation', 'StreamBuilder: state=$state, isNavigating=$_isNavigating');
              if (state == 'exchanging' && _scannedConversationId != null && !_isNavigating) {
                _isNavigating = true;
                // Naviguer vers l'écran d'échange de clé
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _navigateToKeyExchange();
                });
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _navigateToKeyExchange() async {
    if (_scannedConversationId == null) return;

    try {
      final doc = await _firestore
          .collection('conversations')
          .doc(_scannedConversationId)
          .get();
      
      if (!doc.exists) return;

      final data = doc.data()!;
      final peerIds = List<String>.from(data['peerIds'] as List? ?? []);
      // final name = data['name'] as String?; // name removed

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => KeyExchangeScreen(
              peerIds: peerIds,
              existingConversationId: _scannedConversationId,
            ),
          ),
        );
      }
    } catch (e) {
      setState(() => _errorMessage = 'Erreur: $e');
    }
  }
}
