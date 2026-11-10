import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:onetime/services/message_service.dart';
import 'package:onetime/models/firestore/fs_conversation.dart';
import 'package:onetime/models/firestore/fs_kex.dart';
import 'package:onetime/screens/conversation_detail_screen.dart';
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
import 'package:onetime/theme/app_theme.dart';
import 'package:onetime/widgets/onetime_logo.dart';
import 'package:onetime/widgets/qr_matrix_view.dart';
import 'package:qr/qr.dart';
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
  String? _qrPayload;
  QrCode? _qr;
  // Every frame is decoded: the source changes code several times per second
  final _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.unrestricted,
    formats: const [BarcodeFormat.qrCode],
  );
  KeyExchangeRole _role = KeyExchangeRole.source;
  int _currentStep = 0;
  String? _errorMessage;

  // Taille de clé à générer (en octets)
  int _keySizeBytes = 256 * 1024;
  bool _continuous = false;

  /// Largest key a continuous exchange produces (about an hour of QR codes).
  static const _continuousMaxBytes = 30 * 1024 * 1024;

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
    _scannerController.dispose();
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
      final preGenSession = _continuous ? null : KeyPreGenerationService().consumeSession(_keySizeBytes);
      await source.start(_keySizeBytes, preGeneratedSegments: preGenSession?.preGeneratedSegments, continuous: _continuous);
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
    _openConversation(conversation, result.newKey);
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
    _openConversation(conversation, result.newKey);
  }

  /// Goes straight to the conversation, which introduces the user (pseudo
  /// message) after the first key.
  void _openConversation(Conversation conversation, SharedKey newKey) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => ConversationDetailScreen(conversation: conversation)),
    );
    messenger.showSnackBar(SnackBar(content: Text('Clé partagée: ${_formatBytes(newKey.lengthInBytes)}')));
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo';
    return '${(bytes / 1024).round()} Ko';
  }

  /// One of the key size choices: a size and how long its QR codes take.
  Widget _buildKeyGenButton(String label, String detail, int bytes, {bool continuous = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: OutlinedButton(
        onPressed: () {
          setState(() {
            _keySizeBytes = bytes;
            _continuous = continuous;
          });
          _startAsSource();
        },
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outline),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 2),
            Text(detail, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  /// True once some key bytes went through: leaving then ends the exchange
  /// for everyone, keeping what all participants received.
  bool get _hasReceivedSomething => _source?.canTerminate ?? _reader?.canStop ?? false;

  void _stopExchange() {
    if (_source != null) {
      _source!.terminate();
    } else {
      _reader?.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back acts as Terminer once something was received (before, it cancels)
      canPop: _currentStep == 0 || !_hasReceivedSomething,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _stopExchange();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Échange de clé'),
        ),
        body: _currentStep == 0
            ? _buildRoleSelection()
            : _role == KeyExchangeRole.source
                ? _buildSourceView()
                : _buildReaderView(),
      ),
    );
  }

  Widget _buildRoleSelection() {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: OneTimeLogo(size: 72)),
          const SizedBox(height: 16),
          Text(
            'Partager une clé',
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Un appareil affiche la clé en QR codes, les autres la scannent.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 32),

          // Recevoir la clé d'un autre appareil
          FilledButton.icon(
            onPressed: _startAsReader,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scanner une clé'),
            style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
          ),
          const SizedBox(height: 32),

          // Afficher une nouvelle clé
          Text(
            'Afficher une clé',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildKeyGenButton('256 Ko', '~40 s', 256 * 1024),
              const SizedBox(width: 8),
              _buildKeyGenButton('1 Mo', '~2 min', 1 << 20),
              const SizedBox(width: 8),
              _buildKeyGenButton('Continu', "jusqu'à l'arrêt", _continuousMaxBytes, continuous: true),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Environ 7 Ko par seconde. En continu, la clé grandit jusqu\'à ce que '
            'quelqu\'un appuie sur Terminer (30 Mo au plus).',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),

          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: TextStyle(color: scheme.error),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  /// QR code of the payload on display, rebuilt only when the payload changes.
  QrCode _qrFor(String payload) {
    if (payload != _qrPayload) {
      _qrPayload = payload;
      _qr = QrPayload.build(payload);
    }
    return _qr!;
  }

  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo';
    return '${(bytes / 1024).round()} Ko';
  }

  Widget _buildSourceView() {
    final source = _source;
    if (source == null || source.currentPacket == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final scheme = Theme.of(context).colorScheme;
    final session = source.session!;
    final firestoreSession = source.syncState;
    // Segments held by the slowest reader (readers acknowledge whole blocks)
    final readers = firestoreSession?.otherParticipants ?? const <String>[];
    final receivedByAll = readers.isEmpty
        ? 0
        : readers.map((p) => firestoreSession!.getParticipantProgress(p)).reduce((a, b) => a < b ? a : b);
    final receivedBytes = receivedByAll * KeyService.segmentSizeBytes;

    return Column(
      children: [
        // Progress and stop button
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          color: scheme.surfaceContainerHigh,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      source.continuous
                          ? 'Reçu par tous: ${_formatSize(receivedBytes)}'
                          : 'Reçu par tous: ${_formatSize(receivedBytes)} / ${_formatSize(session.totalBytes)}',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: scheme.onSurface),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      // Continuous: progress towards the maximum would barely move
                      value: source.continuous ? null : receivedByAll / session.totalSegments,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: source.canTerminate ? source.terminate : null,
                child: const Text('Terminer'),
              ),
            ],
          ),
        ),

        // QR code, always black on white so that cameras read it
        Expanded(
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2B2B2B),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    source.currentLabel,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                Expanded(
                  child: Center(child: QrMatrixView(qr: _qrFor(source.currentPayload!))),
                ),
              ],
            ),
          ),
        ),

        if ((_errorMessage ?? source.error) != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: scheme.surfaceContainerHigh,
            child: Text(
              (_errorMessage ?? source.error)!,
              style: TextStyle(color: scheme.error, fontSize: 12),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  Widget _buildReaderView() {
    final reader = _reader!;
    final scheme = Theme.of(context).colorScheme;
    final segmentsRead = reader.segmentsRead;
    final totalSegments = reader.totalSegments;
    final isCompleted = reader.isCompleted;
    final continuous = totalSegments * KeyService.segmentSizeBytes >= _continuousMaxBytes;
    final currentUserFinished = !continuous && (reader.hasFinishedScanning || (totalSegments > 0 && segmentsRead >= totalSegments));
    final shouldShowScanner = !currentUserFinished && !isCompleted;

    final status = isCompleted
        ? 'Échange terminé'
        : currentUserFinished
            ? 'Clé reçue, en attente des autres'
            : segmentsRead == 0
                ? 'Visez les QR codes de l\'autre appareil'
                : continuous
                    ? 'Réception continue: ${_formatSize(reader.bytesRead)}'
                    : 'Réception: ${_formatSize(reader.bytesRead)} / ${_formatSize(totalSegments * KeyService.segmentSizeBytes)}';

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          color: scheme.surfaceContainerHigh,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(status, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: scheme.onSurface)),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: continuous || totalSegments == 0 ? null : segmentsRead / totalSegments,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Ends the exchange for everyone with what all participants received
              FilledButton(
                onPressed: reader.canStop && !isCompleted ? reader.stop : null,
                child: const Text('Terminer'),
              ),
            ],
          ),
        ),

        if (currentUserFinished && !isCompleted && reader.syncState != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _buildPeerProgressBars(reader.syncState!),
            ),
          ),

        Expanded(
          child: shouldShowScanner
              ? MobileScanner(
                  controller: _scannerController,
                  onDetect: (capture) {
                    for (final barcode in capture.barcodes) {
                      if (barcode.rawValue != null) reader.onPayload(barcode.rawValue!);
                    }
                  },
                )
              : Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle_outline, size: 64, color: scheme.statusOk),
                      const SizedBox(height: 16),
                      Text(status, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: scheme.surfaceContainerHigh,
            child: Text(
              (_errorMessage ?? reader.error)!,
              style: TextStyle(color: scheme.error),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildPeerProgressBars(FsKex session) {
    final scheme = Theme.of(context).colorScheme;
    final otherPeers = session.otherParticipants.where((p) => p != _currentUserId).toList()
      ..sort((a, b) => session.getParticipantProgress(b).compareTo(session.getParticipantProgress(a)));
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
                Icon(isFinished ? Icons.check_circle : Icons.person_outline, size: 16,
                    color: isFinished ? scheme.statusOk : scheme.statusIdle),
                const SizedBox(width: 8),
                Text(shortId, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                const Spacer(),
                Text('$progress/${session.totalSegments}', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: session.totalSegments > 0 ? progress / session.totalSegments : 0),
          ],
        ),
      );
    }).toList();
  }
}
