import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:onetime/services/message_service.dart';
import 'package:onetime/models/firestore/fs_conversation.dart';
import 'package:onetime/models/firestore/fs_kex.dart';
import 'package:onetime/screens/key_exchange_summary_screen.dart';
import 'package:onetime/services/key_exchange_sync_service.dart';
import 'package:onetime/services/key_pre_generation_service.dart';
import 'package:onetime/services/key_service.dart';
import 'package:onetime/services/key_transfer/kex_reader_controller.dart';
import 'package:onetime/services/key_transfer/kex_source_controller.dart';
import 'package:onetime/models/local/shared_key.dart';
import 'package:onetime/services/app_logger.dart';
import 'package:onetime/services/firestore_service.dart';
import 'package:onetime/services/auth_service.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:onetime/services/key_transfer/qr_payload.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/test_events.dart';

/// Key exchange screen via QR codes.
///
/// The protocol lives in [KexSourceController] / [KexReaderController]; this
/// screen renders their state, keeps the screen awake and bright, and saves
/// the resulting key.
class KeyExchangeScreen extends StatefulWidget {
  final List<String> peerIds;
  final String? existingConversationId;

  const KeyExchangeScreen({
    super.key,
    required this.peerIds,
    this.existingConversationId,
  });

  @override
  State<KeyExchangeScreen> createState() => _KeyExchangeScreenState();
}

class _KeyExchangeScreenState extends State<KeyExchangeScreen> {
  final AuthService _authService = AuthService();
  final KeyExchangeSyncService _syncService = KeyExchangeSyncService();
  final MessageService _messageService = MessageService.fromCurrentUserID();
  late final KeyService _keyService = KeyService();
  final _log = AppLogger();

  KexSourceController? _source;
  KexReaderController? _reader;
  KeyExchangeRole _role = KeyExchangeRole.source;
  int _currentStep = 0;
  String? _errorMessage;

  // Taille de clé à générer (en octets)
  int _keySizeBytes = 8192; // 8 KB par défaut

  // Gestion de la luminosité
  double? _originalBrightness;
  bool _isBrightnessMaxed = false;

  @override
  void initState() {
    super.initState();
    _enableWakelock();
  }

  @override
  void dispose() {
    _source?.dispose();
    _reader?.dispose();
    _restoreBrightness();
    _disableWakelock();
    super.dispose();
  }

  /// Active le wakelock pour empêcher l'écran de s'éteindre
  Future<void> _enableWakelock() async {
    try {
      await WakelockPlus.enable();
      _log.i('KeyExchange', 'Wakelock enabled - screen will stay on');
    } catch (e) {
      _log.e('KeyExchange', 'Error enabling wakelock: $e');
    }
  }

  /// Désactive le wakelock
  Future<void> _disableWakelock() async {
    try {
      await WakelockPlus.disable();
      _log.i('KeyExchange', 'Wakelock disabled - screen can dim normally');
    } catch (e) {
      _log.e('KeyExchange', 'Error disabling wakelock: $e');
    }
  }

  /// Met la luminosité au maximum pour afficher le QR code
  Future<void> _setMaxBrightness() async {
    if (_isBrightnessMaxed) return;
    try {
      _originalBrightness = await ScreenBrightness().current;
      await ScreenBrightness().setScreenBrightness(1.0);
      _isBrightnessMaxed = true;
      _log.i('KeyExchange', 'Brightness set to maximum');
    } catch (e) {
      _log.e('KeyExchange', 'Error setting brightness: $e');
    }
  }

  /// Restaure la luminosité originale
  Future<void> _restoreBrightness() async {
    if (!_isBrightnessMaxed) return;
    try {
      if (_originalBrightness != null) {
        await ScreenBrightness().setScreenBrightness(_originalBrightness!);
      } else {
        await ScreenBrightness().resetScreenBrightness();
      }
      _isBrightnessMaxed = false;
      _log.i('KeyExchange', 'Brightness restored');
    } catch (e) {
      _log.e('KeyExchange', 'Error restoring brightness: $e');
    }
  }

  String get _currentUserId => _authService.currentUserId ?? '';

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _startAsSource() async {
    if (_currentUserId.isEmpty) return;
    setState(() => _errorMessage = null);
    final source = KexSourceController(
      sync: _syncService,
      keyService: _keyService,
      localId: _currentUserId,
      conversationId: widget.existingConversationId!,
      peerIds: widget.peerIds,
    )..addListener(_onControllerChanged);
    _source = source;
    setState(() {
      _role = KeyExchangeRole.source;
      _currentStep = 1;
    });
    try {
      final preGenSession = KeyPreGenerationService().consumeSession(_keySizeBytes);
      await source.start(_keySizeBytes, preGeneratedSegments: preGenSession?.preGeneratedSegments);
      _setMaxBrightness();
      final result = await source.result;
      await _finalizeAsSource(source, result);
    } catch (e) {
      _log.e('KeyExchange', 'Source exchange failed: $e');
      if (mounted) setState(() => _errorMessage = 'Erreur: $e');
    }
  }

  void _startAsReader() {
    final reader = KexReaderController(
      sync: _syncService,
      keyService: _keyService,
      localId: _currentUserId,
      conversationId: widget.existingConversationId!,
    )..addListener(_onControllerChanged);
    _reader = reader;
    setState(() {
      _role = KeyExchangeRole.reader;
      _currentStep = 1;
      _errorMessage = null;
    });
    reader.result.then((result) => _finalizeAsReader(result)).catchError((e) {
      if (mounted) setState(() => _errorMessage = 'Erreur: $e');
    });
  }

  /// Appends the new key bytes to the conversation's key, if it already has one.
  Future<SharedKey> _mergeWithExistingKey(String conversationId, SharedKey newKey) async {
    if (!await _keyService.hasKey(conversationId)) return newKey;
    final existingKey = await _keyService.getKey(conversationId);
    _log.d('KeyExchange', 'Extending existing key of ${existingKey.lengthInBytes} bytes with ${newKey.lengthInBytes} bytes');
    return existingKey.extend(newKey.keyData);
  }

  Future<void> _finalizeAsSource(KexSourceController source, KexResult result) async {
    final conversationService = FirestoreService(localUserId: _currentUserId);
    String conversationId;
    SharedKey finalKey;
    if (widget.existingConversationId != null) {
      conversationId = widget.existingConversationId!;
      finalKey = await _mergeWithExistingKey(conversationId, result.newKey);
      // Mettre à jour la conversation à Ready
      await conversationService.updateConversationKey(conversationId: conversationId);
    } else {
      finalKey = result.newKey;
      final conversation = await conversationService.createConversation(peerIds: source.session!.peerIds);
      conversationId = conversation.id;
    }
    try {
      await source.complete(conversationId);
    } catch (e) {
      // La session peut avoir été supprimée par le reader, ce n'est pas grave
      _log.d('KeyExchange', 'Could not update session (may have been deleted by reader): $e');
    }
    await _keyService.saveKey(conversationId, finalKey);
    _log.i('KeyExchange', 'Shared key saved successfully');
    TestEvents.emit('key_saved', {'role': 'source', 'conversationId': conversationId, 'bytes': finalKey.lengthInBytes, 'fingerprint': TestEvents.keyFingerprint(finalKey.keyData)});
    await _messageService.updateKeyDebugInfo(conversationId);
    try {
      await source.cleanup();
    } catch (e) {
      _log.d('KeyExchange', 'Could not delete session: $e');
    }
    final conversation = await conversationService.getConversation(conversationId);
    if (conversation == null) {
      if (mounted) setState(() => _errorMessage = 'Conversation non trouvée');
      return;
    }
    await _restoreBrightness();
    _openSummary(result.syncState, finalKey, conversation);
  }

  Future<void> _finalizeAsReader(KexResult result) async {
    final conversationService = FirestoreService(localUserId: _currentUserId);
    final conversation = await conversationService.getConversation(widget.existingConversationId!);
    if (conversation == null) {
      if (mounted) setState(() => _errorMessage = 'Conversation non trouvée. Réessayez.');
      return;
    }
    final finalKey = await _mergeWithExistingKey(conversation.id, result.newKey);
    await _keyService.saveKey(conversation.id, finalKey);
    _log.i('KeyExchange', 'Reader: Shared key saved successfully');
    TestEvents.emit('key_saved', {'role': 'reader', 'conversationId': conversation.id, 'bytes': finalKey.lengthInBytes, 'fingerprint': TestEvents.keyFingerprint(finalKey.keyData)});
    await _messageService.updateKeyDebugInfo(conversation.id);
    // NE PAS supprimer la session - c'est la source qui s'en charge
    _openSummary(result.syncState, finalKey, conversation);
  }

  void _openSummary(FsKex syncState, SharedKey finalKey, Conversation conversation) {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => KeyExchangeSummaryScreen(
          session: syncState,
          newKey: finalKey,
          conversation: conversation,
          currentUserId: _currentUserId,
        ),
      ),
    );
  }

  Widget _buildKeyGenButton(String label, int sizeInBits) {
    final isSelected = _keySizeBytes == sizeInBits;
    return ElevatedButton(
      onPressed: () {
        setState(() => _keySizeBytes = sizeInBits);
        _startAsSource();
      },
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        backgroundColor: isSelected ? Theme.of(context).primaryColor : null,
        foregroundColor: isSelected ? Colors.white : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.qr_code, size: 32),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Échange de clé'),
      ),
      body: _currentStep == 0
          ? _buildRoleSelection()
          : _role == KeyExchangeRole.source
              ? _buildSourceView()
              : _buildReaderView(),
    );
  }

  Widget _buildRoleSelection() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Instructions
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Icon(Icons.key, size: 48, color: Colors.amber),
                  const SizedBox(height: 16),
                  Text(
                    'Création de la clé partagée',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Un appareil génère la clé et l\'affiche en QR codes.\n'
                    'Les autres appareils scannent pour recevoir la clé.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Boutons de génération de clé (4 tailles)
          Text(
            'Générer une clé',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildKeyGenButton('8 KB', 8192 ),
              _buildKeyGenButton('32 KB', 32768 ),
              _buildKeyGenButton('128 KB', 131072 ),
              _buildKeyGenButton('512 KB', 524288 ),
            ],
          ),
          
          const SizedBox(height: 24),

          // Bouton de scan
          OutlinedButton.icon(
            onPressed: _startAsReader,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Ou scanner une clé'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.all(16),
            ),
          ),

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

  Widget _buildSourceView() {
    final source = _source;
    if (source == null || source.currentSegment == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final session = source.session!;
    final firestoreSession = source.syncState;
    final progress = (session.currentSegmentIndex / session.totalSegments);

    // L'index du segment actuellement affiché dans le QR code
    final displayedSegmentIdx = source.currentSegment!.segmentIndex;

    // Nombre de participants ayant scanné ce segment
    final scannedList = firestoreSession?.scannedBy[displayedSegmentIdx] ?? [];
    final allScanned = firestoreSession?.allParticipantsScannedSegment(displayedSegmentIdx) ?? false;

    return Column(
      children: [
        // Top bar: Progress, segment count, and stop button on one line
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: Theme.of(context).primaryColor.withAlpha(25),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                // Progress indicator and segment count
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // List of participants who scanned current segment
                      Text(
                        'Participants: ${scannedList.isEmpty ? "Personne" : scannedList.join(", ")}', // Show names/IDs
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: LinearProgressIndicator(
                              value: progress,
                              backgroundColor: Colors.grey[300],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${displayedSegmentIdx + 1}/${session.totalSegments}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Stop button
                // IconButton(
                //   onPressed: _terminateKeyExchange,
                //   icon: const Icon(Icons.stop_circle),
                //   iconSize: 40,
                //   color: session.currentSegmentIndex >= session.totalSegments
                //       ? Colors.green
                //       : Colors.orange,
                //   tooltip: 'Terminer',
                // ),
              ],
            ),
          ),
        ),

        // QR Code - takes all remaining space
        Expanded(
          child: Container(
            color: Colors.white,
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Container(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Badge du numéro de segment
                          Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: allScanned ? Colors.green : Colors.blue,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '${displayedSegmentIdx + 1}/${session.totalSegments}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                            ),
                          ),
                          // QR Code
                          Expanded(
                            child: QrImageView.withQr(
                              qr: QrPayload.build(source.currentPayload!),
                              backgroundColor: Colors.white,
                              eyeStyle: const QrEyeStyle(
                                eyeShape: QrEyeShape.square,
                                color: Colors.black,
                              ),
                              dataModuleStyle: const QrDataModuleStyle(
                                dataModuleShape: QrDataModuleShape.square,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),

        // Bottom info bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Theme.of(context).primaryColor.withAlpha(25),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if ((_errorMessage ?? source.error) != null) ...[
                  Text(
                    (_errorMessage ?? source.error)!,
                    style: const TextStyle(color: Colors.red, fontSize: 11),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                ],
                // Show interval in seconds with one decimal (e.g. 0.6s)
                Text(
                  '🔄 ${(source.rotationInterval.inMilliseconds / 1000).toStringAsFixed(1)}s/code',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReaderView() {
    final reader = _reader!;
    final firestoreSession = reader.syncState;
    final segmentsRead = reader.segmentsRead;
    final totalSegments = reader.totalSegments;
    final isCompleted = reader.isCompleted;
    // Check if current user has finished scanning all segments
    final currentUserFinished = reader.hasFinishedScanning || (totalSegments > 0 && segmentsRead >= totalSegments);
    final shouldShowScanner = !currentUserFinished && !isCompleted;

    return Column(
      children: [
        // Barre de progression pour l'utilisateur actuel
        LinearProgressIndicator(
          value: totalSegments > 0 ? segmentsRead / totalSegments : 0,
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            'Segments lus: $segmentsRead / $totalSegments',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),

        // Statut de la session
        if (firestoreSession != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isCompleted ? Colors.green[50] : (currentUserFinished ? Colors.amber[50] : Colors.blue[50]),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isCompleted ? Colors.green : (currentUserFinished ? Colors.amber : Colors.blue),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isCompleted ? Icons.check_circle : (currentUserFinished ? Icons.check_circle_outline : Icons.sync),
                  color: isCompleted ? Colors.green : (currentUserFinished ? Colors.amber : Colors.blue),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  isCompleted
                      ? 'Échange terminé! Redirection...'
                      : (currentUserFinished 
                          ? 'Vous avez terminé! En attente des autres...'
                          : 'Scanning en cours...'),
                  style: TextStyle(
                    color: isCompleted ? Colors.green[800] : (currentUserFinished ? Colors.amber[800] : Colors.blue[800]),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

        // Progress bars for all peers (when current user has finished)
        if (currentUserFinished && !isCompleted && firestoreSession != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Progression des participants:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 8),
                ..._buildPeerProgressBars(firestoreSession),
              ],
            ),
          ),

        Expanded(
          child: shouldShowScanner
              ? Stack(
                  children: [
                    MobileScanner(
                      onDetect: (capture) {
                        final barcodes = capture.barcodes;
                        if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                          reader.onPayload(barcodes.first.rawValue!);
                        }
                      },
                    ),
                    // Overlay d'aide au scan
                    Positioned(
                      top: 16,
                      left: 16,
                      right: 16,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(179),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '📷 Positionnez le QR code dans le cadre\n'
                          'Le QR change automatiquement',
                           textAlign: TextAlign.center,
                           style: const TextStyle(
                             color: Colors.white,
                             fontSize: 12,
                           ),
                        ),
                      ),
                    ),
                  ],
                )
              : Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isCompleted ? Icons.celebration : Icons.check_circle,
                        size: 64,
                        color: isCompleted ? Colors.amber : Colors.green,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        isCompleted
                            ? 'Échange terminé!'
                            : (currentUserFinished
                                ? 'Scan terminé!'
                                : 'Segment $segmentsRead reçu!'),
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isCompleted
                            ? 'Redirection vers la conversation...'
                            : (currentUserFinished
                                ? 'En attente des autres participants...'
                                : 'Attendez que la source affiche le prochain QR code'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                      if (isCompleted) ...[
                        const SizedBox(height: 16),
                        const CircularProgressIndicator(),
                      ],
                    ],
                  ),
                ),
        ),

        if ((_errorMessage ?? reader.error) != null)
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.red[100],
            child: Text(
              (_errorMessage ?? reader.error)!,
              style: TextStyle(color: Colors.red[900]),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildPeerProgressBars(FsKex session) {
    // Get all other participants (excluding current user)
    final otherPeers = session.otherParticipants.where((p) => p != _currentUserId).toList();
    
    // Sort by progress (most finished first)
    otherPeers.sort((a, b) {
      final progressA = session.getParticipantProgress(a);
      final progressB = session.getParticipantProgress(b);
      return progressB.compareTo(progressA);
    });

    return otherPeers.map((peerId) {
      final progress = session.getParticipantProgress(peerId);
      final isFinished = session.hasParticipantFinishedScanning(peerId);
      final shortId = peerId.length > 8 ? peerId.substring(0, 8) : peerId;

      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isFinished ? Icons.check_circle : Icons.person,
                  size: 16,
                  color: isFinished ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  shortId,
                  style: TextStyle(
                    fontSize: 12,
                    color: isFinished ? Colors.green[700] : Colors.grey[700],
                  ),
                ),
                const Spacer(),
                Text(
                  '$progress/${session.totalSegments}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: session.totalSegments > 0 ? progress / session.totalSegments : 0,
              backgroundColor: Colors.grey[300],
              color: isFinished ? Colors.green : Colors.blue,
            ),
          ],
        ),
      );
    }).toList();
  }
}
